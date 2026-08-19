//go:build linux

package postpivot

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"

	"github.com/creack/pty"
	"golang.org/x/crypto/ssh"
)

// TailnetListener is anything that can hand out net.Listeners on a
// user-space tailnet interface (e.g. *tsnet.Server).
type TailnetListener interface {
	Listen(network, addr string) (net.Listener, error)
}

// StartSSHServer serves an SSH server on kernel :port and, when
// tailnet is non-nil, additionally on the tailnet interface. Pubkey
// (cfg.AuthorizedKeys, one per line) and password (cfg.Password) auth
// are both accepted when configured; server refuses to start with
// neither. Sessions run /bin/sh as root.
func StartSSHServer(ctx context.Context, cfg *SSHConfig, tailnet TailnetListener) error {
	if cfg == nil {
		return errors.New("sshd: nil SSH config")
	}
	port := cfg.Port
	if port == 0 {
		port = 22
	}
	addr := fmt.Sprintf(":%d", port)

	var listeners []net.Listener
	if kln, err := net.Listen("tcp", addr); err == nil {
		listeners = append(listeners, kln)
	} else {
		slog.Warn("sshd: kernel listen failed", "err", err)
	}
	if tailnet != nil {
		if tln, err := tailnet.Listen("tcp", addr); err == nil {
			listeners = append(listeners, tln)
		} else {
			slog.Warn("sshd: tailnet listen failed", "err", err)
		}
	}
	if len(listeners) == 0 {
		return fmt.Errorf("sshd: no listeners could bind :%d", port)
	}
	return serveSSH(ctx, listeners, cfg)
}

// serveSSH is the injectable core so tests can pass random-port
// listeners. Closes every listener on exit.
func serveSSH(ctx context.Context, listeners []net.Listener, cfg *SSHConfig) error {
	sc, err := buildServerConfig(cfg)
	if err != nil {
		for _, ln := range listeners {
			ln.Close()
		}
		return err
	}

	go func() {
		<-ctx.Done()
		for _, ln := range listeners {
			ln.Close()
		}
	}()

	var wg sync.WaitGroup
	errCh := make(chan error, len(listeners))
	for _, ln := range listeners {
		slog.Info("sshd: listening", "addr", ln.Addr())
		wg.Add(1)
		go func(ln net.Listener) {
			defer wg.Done()
			errCh <- acceptLoop(ctx, ln, sc)
		}(ln)
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			return err
		}
	}
	return nil
}

func acceptLoop(ctx context.Context, ln net.Listener, sc *ssh.ServerConfig) error {
	var wg sync.WaitGroup
	defer wg.Wait()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("sshd: accept on %s: %w", ln.Addr(), err)
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			handleConn(conn, sc)
		}()
	}
}

func buildServerConfig(cfg *SSHConfig) (*ssh.ServerConfig, error) {
	sc := &ssh.ServerConfig{}

	keys, err := parseAuthorizedKeys(cfg.AuthorizedKeys)
	if err != nil {
		return nil, fmt.Errorf("sshd: parse authorized_keys: %w", err)
	}
	if len(keys) > 0 {
		sc.PublicKeyCallback = func(_ ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
			gotBytes := k.Marshal()
			for _, want := range keys {
				if bytes.Equal(gotBytes, want.Marshal()) {
					return nil, nil
				}
			}
			return nil, errors.New("unauthorized key")
		}
	}
	if cfg.Password != "" {
		pw := []byte(cfg.Password)
		sc.PasswordCallback = func(_ ssh.ConnMetadata, got []byte) (*ssh.Permissions, error) {
			if subtle.ConstantTimeCompare(pw, got) == 1 {
				return nil, nil
			}
			return nil, errors.New("bad password")
		}
	}
	if sc.PublicKeyCallback == nil && sc.PasswordCallback == nil {
		return nil, errors.New("sshd: no auth method configured (need authorized_keys or password)")
	}

	signer, err := generateHostKey()
	if err != nil {
		return nil, fmt.Errorf("sshd: host key: %w", err)
	}
	sc.AddHostKey(signer)
	slog.Info("sshd: host key", "fingerprint", ssh.FingerprintSHA256(signer.PublicKey()))
	return sc, nil
}

func parseAuthorizedKeys(s string) ([]ssh.PublicKey, error) {
	var out []ssh.PublicKey
	for i, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", i+1, err)
		}
		out = append(out, k)
	}
	return out, nil
}

func generateHostKey() (ssh.Signer, error) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return ssh.NewSignerFromKey(priv)
}

func handleConn(conn net.Conn, sc *ssh.ServerConfig) {
	defer conn.Close()
	sconn, chans, reqs, err := ssh.NewServerConn(conn, sc)
	if err != nil {
		slog.Warn("sshd: handshake", "err", err, "remote", conn.RemoteAddr())
		return
	}
	defer sconn.Close()
	slog.Info("sshd: accepted", "user", sconn.User(), "remote", conn.RemoteAddr())

	go ssh.DiscardRequests(reqs)

	for newCh := range chans {
		if newCh.ChannelType() != "session" {
			_ = newCh.Reject(ssh.UnknownChannelType, "session only")
			continue
		}
		ch, chReqs, err := newCh.Accept()
		if err != nil {
			slog.Warn("sshd: channel accept", "err", err)
			continue
		}
		go handleSession(ch, chReqs)
	}
}

// SSH request payloads per RFC 4254; ssh.Unmarshal decodes them.
type (
	ptyReqMsg struct {
		Term          string
		Cols, Rows    uint32
		Width, Height uint32
		Modes         string
	}
	winChMsg struct {
		Cols, Rows    uint32
		Width, Height uint32
	}
	execMsg struct{ Command string }
	envMsg  struct{ Name, Value string }
	exitMsg struct{ Status uint32 }
)

func handleSession(ch ssh.Channel, reqs <-chan *ssh.Request) {
	defer ch.Close()

	var (
		term    string
		env     []string
		wantPty bool
		ws      pty.Winsize
	)

	for req := range reqs {
		switch req.Type {
		case "pty-req":
			var m ptyReqMsg
			if err := ssh.Unmarshal(req.Payload, &m); err != nil {
				_ = req.Reply(false, nil)
				continue
			}
			term = m.Term
			ws = pty.Winsize{Rows: uint16(m.Rows), Cols: uint16(m.Cols), X: uint16(m.Width), Y: uint16(m.Height)}
			wantPty = true
			_ = req.Reply(true, nil)
		case "env":
			var m envMsg
			if err := ssh.Unmarshal(req.Payload, &m); err == nil {
				env = append(env, m.Name+"="+m.Value)
			}
			_ = req.Reply(true, nil)
		case "shell":
			_ = req.Reply(true, nil)
			runSession(ch, reqs, exec.Command("/bin/sh", "-l"), term, env, wantPty, ws)
			return
		case "exec":
			var m execMsg
			if err := ssh.Unmarshal(req.Payload, &m); err != nil {
				_ = req.Reply(false, nil)
				continue
			}
			_ = req.Reply(true, nil)
			runSession(ch, reqs, exec.Command("/bin/sh", "-c", m.Command), term, env, wantPty, ws)
			return
		default:
			_ = req.Reply(false, nil)
		}
	}
}

func runSession(ch ssh.Channel, reqs <-chan *ssh.Request, cmd *exec.Cmd, term string, env []string, wantPty bool, ws pty.Winsize) {
	if term != "" {
		env = append(env, "TERM="+term)
	}
	cmd.Env = append(os.Environ(), env...)

	if wantPty {
		f, err := pty.Start(cmd)
		if err != nil {
			fmt.Fprintf(ch, "exec: %v\r\n", err)
			sendExitStatus(ch, 127)
			return
		}
		defer f.Close()
		_ = pty.Setsize(f, &ws)

		go io.Copy(f, ch)
		go handleWinCh(reqs, f)
		_, _ = io.Copy(ch, f)
	} else {
		// Deliberately not cmd.Stdin = ch. os/exec copies a non-*os.File
		// stdin on its own goroutine and makes Wait() block until that copy
		// returns — and it returns only when the client closes the channel.
		// The client closes it when its own stdin hits EOF, which for
		// `ssh host cmd` from a terminal or a live pipe is never. So the
		// command would exit, produce its output, and the session would hang
		// anyway, until someone thought to add `< /dev/null`. On a rescue box
		// that is a very bad time to be debugging a hung SSH session.
		//
		// StdinPipe has the behaviour we want: Wait closes the pipe once the
		// process exits, which unblocks the copy below.
		stdin, err := cmd.StdinPipe()
		if err != nil {
			fmt.Fprintf(ch.Stderr(), "exec: %v\n", err)
			sendExitStatus(ch, 127)
			return
		}
		cmd.Stdout = ch
		cmd.Stderr = ch.Stderr()
		if err := cmd.Start(); err != nil {
			stdin.Close()
			fmt.Fprintf(ch.Stderr(), "exec: %v\n", err)
			sendExitStatus(ch, 127)
			return
		}
		go func() {
			_, _ = io.Copy(stdin, ch)
			_ = stdin.Close()
		}()
		go handleWinCh(reqs, nil)
	}

	status := uint32(0)
	if err := cmd.Wait(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			status = uint32(ee.ExitCode())
		} else {
			status = 1
		}
	}
	sendExitStatus(ch, status)
}

func handleWinCh(reqs <-chan *ssh.Request, ptyF *os.File) {
	for req := range reqs {
		if req.Type == "window-change" && ptyF != nil {
			var m winChMsg
			if err := ssh.Unmarshal(req.Payload, &m); err == nil {
				_ = pty.Setsize(ptyF, &pty.Winsize{Rows: uint16(m.Rows), Cols: uint16(m.Cols), X: uint16(m.Width), Y: uint16(m.Height)})
			}
		}
		_ = req.Reply(false, nil)
	}
}

func sendExitStatus(ch ssh.Channel, status uint32) {
	_, _ = ch.SendRequest("exit-status", false, ssh.Marshal(&exitMsg{Status: status}))
}
