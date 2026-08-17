package postpivot

import (
	"bufio"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
)

// FallbackNameservers are used when the host has no usable resolv.conf.
// Two providers rather than two addresses from one, so a single provider
// outage doesn't leave the pivoted system unable to resolve anything.
var FallbackNameservers = []string{"1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"}

// EnsureResolvConf gives the new rootfs a working /etc/resolv.conf before
// the pivot.
//
// Two things make this necessary. Minimal OCI images (alpine, busybox,
// distroless) ship no /etc/resolv.conf at all — DNS in a container comes
// from the runtime, and there is no runtime here. And the host's own file
// usually cannot be copied verbatim: on systemd-resolved distros it reads
// "nameserver 127.0.0.53", a stub served by a daemon that gets terminated
// during pivot preparation. Copying it produces a rootfs that looks
// configured and resolves nothing.
//
// So: keep a usable file if the image has one, otherwise inherit the host's
// real nameservers, otherwise fall back to public resolvers. Tailscale needs
// working DNS to reach the coordination server, so getting this wrong
// strands the box exactly when remote access is the only access left.
func EnsureResolvConf(rootfsRoot string) error {
	dst := filepath.Join(rootfsRoot, "etc", "resolv.conf")

	if servers := readNameservers(dst); len(servers) > 0 && !allLoopback(servers) {
		slog.Debug("rootfs already has a usable resolv.conf", "servers", servers)
		return nil
	}

	source := "host"
	servers := readNameservers("/etc/resolv.conf")
	if usable := filterRoutable(servers); len(usable) > 0 {
		servers = usable
	} else {
		// Either the host had nothing, or everything it listed was a local
		// stub that dies with the old root.
		slog.Warn("host resolv.conf unusable post-pivot; using fallback resolvers",
			"host_servers", servers, "fallback", FallbackNameservers)
		servers = FallbackNameservers
		source = "fallback"
	}

	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return fmt.Errorf("mkdir for resolv.conf: %w", err)
	}
	var b strings.Builder
	b.WriteString("# written by xmorph: the pre-pivot resolver does not survive pivot_root\n")
	for _, s := range servers {
		fmt.Fprintf(&b, "nameserver %s\n", s)
	}
	// A pre-existing symlink (e.g. ../run/systemd/resolve/stub-resolv.conf)
	// would otherwise be followed and write into a directory that will not
	// exist after the pivot.
	_ = os.Remove(dst)
	if err := os.WriteFile(dst, []byte(b.String()), 0o644); err != nil {
		return fmt.Errorf("write resolv.conf: %w", err)
	}
	slog.Info("wrote resolv.conf into new rootfs", "source", source, "servers", servers)
	return nil
}

// readNameservers parses the nameserver lines out of a resolv.conf.
// A missing or unreadable file yields nil rather than an error: every
// caller treats "no servers" and "could not read" the same way.
func readNameservers(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "nameserver" {
			if ip := net.ParseIP(fields[1]); ip != nil {
				out = append(out, ip.String())
			}
		}
	}
	return out
}

// filterRoutable drops loopback addresses. They are the signature of a local
// caching resolver — systemd-resolved on 127.0.0.53, dnsmasq on 127.0.0.1 —
// which is torn down with the old root and cannot answer afterwards.
func filterRoutable(servers []string) []string {
	var out []string
	for _, s := range servers {
		if ip := net.ParseIP(s); ip != nil && !ip.IsLoopback() {
			out = append(out, s)
		}
	}
	return out
}

func allLoopback(servers []string) bool {
	return len(filterRoutable(servers)) == 0
}
