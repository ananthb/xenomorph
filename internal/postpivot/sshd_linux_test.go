//go:build linux

package postpivot

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// serveSSHTest starts serveSSH on a random loopback port and returns
// the client-facing address. t.Cleanup cancels + waits for shutdown.
func serveSSHTest(t *testing.T, cfg *SSHConfig) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- serveSSH(ctx, []net.Listener{ln}, cfg) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Log("serveSSH did not exit in 2s")
		}
	})
	return ln.Addr().String()
}

// genClientKey returns an ed25519 client key + its authorized_keys
// serialization.
func genClientKey(t *testing.T) (ssh.Signer, string) {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	authorized := string(ssh.MarshalAuthorizedKey(signer.PublicKey()))
	return signer, authorized
}

func dialClient(t *testing.T, addr string, auth []ssh.AuthMethod) *ssh.Client {
	t.Helper()
	c, err := ssh.Dial("tcp", addr, &ssh.ClientConfig{
		User:            "root",
		Auth:            auth,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         3 * time.Second,
	})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func TestSSHPublicKeyExec(t *testing.T) {
	signer, authorized := genClientKey(t)
	addr := serveSSHTest(t, &SSHConfig{
		Port:           0,
		AuthorizedKeys: authorized,
	})

	c := dialClient(t, addr, []ssh.AuthMethod{ssh.PublicKeys(signer)})
	sess, err := c.NewSession()
	if err != nil {
		t.Fatalf("session: %v", err)
	}
	defer sess.Close()

	out, err := sess.CombinedOutput("echo hello")
	if err != nil {
		t.Fatalf("run: %v (out=%q)", err, out)
	}
	if got := strings.TrimSpace(string(out)); got != "hello" {
		t.Errorf("output = %q, want %q", got, "hello")
	}
}

func TestSSHExitStatusPropagates(t *testing.T) {
	signer, authorized := genClientKey(t)
	addr := serveSSHTest(t, &SSHConfig{AuthorizedKeys: authorized})

	c := dialClient(t, addr, []ssh.AuthMethod{ssh.PublicKeys(signer)})
	sess, err := c.NewSession()
	if err != nil {
		t.Fatalf("session: %v", err)
	}
	defer sess.Close()

	err = sess.Run("exit 42")
	var ee *ssh.ExitError
	if !errors.As(err, &ee) || ee.ExitStatus() != 42 {
		t.Errorf("exit status = %v, want ExitError(42)", err)
	}
}

func TestSSHPasswordAuth(t *testing.T) {
	addr := serveSSHTest(t, &SSHConfig{Password: "s3cret"})
	c := dialClient(t, addr, []ssh.AuthMethod{ssh.Password("s3cret")})
	sess, err := c.NewSession()
	if err != nil {
		t.Fatalf("session: %v", err)
	}
	defer sess.Close()
	if err := sess.Run("true"); err != nil {
		t.Errorf("run: %v", err)
	}
}

func TestSSHRejectsUnknownKey(t *testing.T) {
	_, authorized := genClientKey(t)  // authorized on server
	otherSigner, _ := genClientKey(t) // client uses a DIFFERENT key
	addr := serveSSHTest(t, &SSHConfig{AuthorizedKeys: authorized})

	_, err := ssh.Dial("tcp", addr, &ssh.ClientConfig{
		User:            "root",
		Auth:            []ssh.AuthMethod{ssh.PublicKeys(otherSigner)},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         2 * time.Second,
	})
	if err == nil {
		t.Fatal("expected auth failure for unknown key")
	}
}

func TestSSHNoAuthConfiguredRefuses(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	err = serveSSH(ctx, []net.Listener{ln}, &SSHConfig{}) // no keys, no password
	if err == nil || !strings.Contains(err.Error(), "no auth method") {
		t.Errorf("serveSSH err = %v, want 'no auth method'", err)
	}
}

func TestParseAuthorizedKeys(t *testing.T) {
	_, authorized := genClientKey(t)
	_, other := genClientKey(t)
	input := "# comment\n\n" + authorized + "\n" + other + "\n"

	keys, err := parseAuthorizedKeys(input)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(keys) != 2 {
		t.Errorf("got %d keys, want 2", len(keys))
	}
}

type fakeTailnet struct{}

func (fakeTailnet) Listen(network, addr string) (net.Listener, error) {
	return net.Listen(network, "127.0.0.1:0")
}

func TestStartSSHServerAddsTailnetListener(t *testing.T) {
	_, authorized := genClientKey(t)
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- StartSSHServer(ctx, &SSHConfig{AuthorizedKeys: authorized}, fakeTailnet{}) }()
	// Give both listeners a moment to bind, then shut down.
	time.Sleep(100 * time.Millisecond)
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("StartSSHServer: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Error("StartSSHServer did not exit")
	}
}

func TestParseAuthorizedKeysBadLineReturnsError(t *testing.T) {
	_, err := parseAuthorizedKeys("this-is-not-a-key")
	if err == nil {
		t.Fatal("expected error for bogus key")
	}
	if !bytes.Contains([]byte(err.Error()), []byte("line 1")) {
		t.Errorf("err = %v, want to mention line number", err)
	}
}

// `ssh host cmd` must return when the command returns, even though the
// client's stdin is still open.
//
// This is the shape every other test in this file misses. x/crypto/ssh's
// Session sends channel EOF immediately when Stdin is nil, so sess.Run("true")
// passes even against a server that deadlocks — and a real client only sends
// EOF when its own stdin does, which for a command run from a terminal or a
// live pipe is never. The server used to set cmd.Stdin = ch, which makes
// os/exec's Wait() block until that copy finishes, i.e. until the client
// closes the channel, i.e. until after the thing it is blocking. Found by the
// VM test in nix/tests/lifecycle.nix, which logs in over a real ssh(1).
func TestSSHExecReturnsWithStdinStillOpen(t *testing.T) {
	addr := serveSSHTest(t, &SSHConfig{Password: "s3cret"})
	c := dialClient(t, addr, []ssh.AuthMethod{ssh.Password("s3cret")})
	sess, err := c.NewSession()
	if err != nil {
		t.Fatalf("session: %v", err)
	}
	defer sess.Close()

	// A stdin that never reaches EOF, the way a terminal behaves. Nothing is
	// ever written to it; the point is only that it stays open.
	pr, pw := io.Pipe()
	defer pw.Close()
	sess.Stdin = pr

	var out bytes.Buffer
	sess.Stdout = &out

	done := make(chan error, 1)
	go func() { done <- sess.Run("echo logged-in") }()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
		if got := strings.TrimSpace(out.String()); got != "logged-in" {
			t.Errorf("stdout = %q, want %q", got, "logged-in")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("session never returned; the server is waiting on a stdin the client will not close")
	}
}
