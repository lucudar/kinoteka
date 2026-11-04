#!/usr/bin/env python3
"""Changes of Kinoteka to the torrent library of TorrServer (github.com/tsynik/torrent, a fork of
anacrolix/torrent 1.2): the engine connects to peers several times faster.

Before a torrent's metadata is known, only some of its peers can send it: Zona's clients, most of
the peers of the releases of its index, never do (their extension handshake has no ut_metadata).
With 25 connection attempts at once, 10 new ones a second and 3–20 s timeouts, the engine went
through a few hundred known peers so slowly that a start often took longer than the player waited.

The loop accepting peer connections pauses after an error: a socket that iOS took while the app was
suspended fails at once on every call (the uTP one after its reader stopped), and without a pause
the loop took a whole processor core until the torrent client was closed.

Usage: patch-torrent.py <directory of the library>. Fails when a line to change is not found, so a
new version of the library is never built without the changes unnoticed.
"""
import re
import sys

CHANGES = [
    # file, setting, value of the library, value of Kinoteka
    ("config.go", "NominalDialTimeout", "20 * time.Second", "10 * time.Second"),
    ("config.go", "MinDialTimeout", "3 * time.Second", "2 * time.Second"),
    ("config.go", "HalfOpenConnsPerTorrent", "25", "80"),
    ("client.go", "dialRateLimiter", "rate.NewLimiter(10, 10)", "rate.NewLimiter(40, 40)"),
]

CODE_CHANGES = [
    # file, what, code of the library, code of Kinoteka
    ("client.go", "acceptConnections pauses for a second after an error",
     """		if err != nil {
			log.Fmsg("error accepting connection: %s", err).LogLevel(log.Debug, cl.logger)
			continue
		}
""",
     """		if err != nil {
			log.Fmsg("error accepting connection: %s", err).LogLevel(log.Debug, cl.logger)
			// Kinoteka: a socket that iOS took fails at once on every call.
			time.Sleep(time.Second)
			continue
		}
"""),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = sys.argv[1].rstrip("/")
    for name, setting, old, value in CHANGES:
        path = f"{root}/{name}"
        with open(path, encoding="utf-8") as f:
            text = f.read()
        pattern = rf"(\b{setting}:\s+){re.escape(old)},"
        new, count = re.subn(pattern, lambda m: m.group(1) + value + ",", text)
        if count != 1:
            print(f"patch-torrent: {name}: {setting}: {old} found {count} times, expected once", file=sys.stderr)
            return 1
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        print(f"patch-torrent: {name}: {setting} {old} -> {value}")
    for name, what, old, value in CODE_CHANGES:
        path = f"{root}/{name}"
        with open(path, encoding="utf-8") as f:
            text = f.read()
        count = text.count(old)
        if count != 1:
            print(f"patch-torrent: {name}: code found {count} times, expected once:\n{old}", file=sys.stderr)
            return 1
        with open(path, "w", encoding="utf-8") as f:
            f.write(text.replace(old, value))
        print(f"patch-torrent: {name}: {what}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
