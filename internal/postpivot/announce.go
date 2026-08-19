package postpivot

import (
	"fmt"
	"io"
)

// AnnounceSSHPassword prints a generated root password where a human will
// see it. `xmorph pivot` calls it before the pivot and Run calls it again
// after, deliberately: the terminal reading the first copy is usually the SSH
// session the pivot is about to tear down, and the console reading the second
// may be a serial line nobody was watching until things went wrong.
//
// Deliberately a banner rather than a slog line. This is the one piece of
// output in the whole run that somebody has to read off a screen and retype —
// quite possibly from a phone photo of a serial console — so it gets blank
// lines around it and none of the key=value noise every other line carries.
//
// Only ever called for a password xmorph generated. One the operator chose is
// theirs, may well be reused somewhere that matters, and must not be echoed
// onto a console and into the persistent log.
func AnnounceSSHPassword(w io.Writer, password string, port int) {
	if port == 0 {
		port = 22
	}
	fmt.Fprintf(w, `
  ============================================================
  SSH is enabled and no credentials were given, so xmorph
  generated a root password for it:

      %s

  Log in with:  ssh -p %d root@<this machine>
  Write it down. Nothing keeps a copy you can read later.
  ============================================================

`, password, port)
}
