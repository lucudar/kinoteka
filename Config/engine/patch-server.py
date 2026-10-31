#!/usr/bin/env python3
"""The changes of Kinoteka in the TorrServer sources (server/ of the tag), with kinoteka-web.go and
kinoteka-kit.go copied next to the patched files by build-engine.sh:

- web.Start keeps its routes, so web.Relisten can open the ports again with them;
- StartServer of the iOS kit waits for the web server with watchServer: a server that fails is
  opened again instead of the engine being marked as stopped while its torrent client runs;
- a start that failed after connecting the torrent client closes it before the next start.

Each change must apply exactly once, so a new TorrServer version that moved the code fails the build.
"""
import re
import sys

SERVER = sys.argv[1]

CHANGES = [
    ("web/server.go",
     r"(\n\tif err := startServers\(route\); err != nil \{)",
     "\n\tkinotekaKeep(route) // Kinoteka: for Relisten\\1"),
    ("mobile/torrserverkit/torrserverkit.go",
     r"go func\(\) \{\s*defer atomic\.StoreInt32\(&running, 0\)\s*server\.WaitServer\(\)\s*\}\(\)",
     "go watchServer() // Kinoteka: a failed web server is opened again"),
    ("mobile/torrserverkit/torrserverkit.go",
     r"(\n\tif err := server\.Start\(\); err != nil \{)",
     "\n\tcloseFailedStart() // Kinoteka: the client of a failed start\\1"),
]

for name, pattern, replacement in CHANGES:
    path = f"{SERVER}/{name}"
    with open(path) as file:
        text = file.read()
    new, count = re.subn(pattern, replacement, text)
    if count != 1:
        sys.exit(f"{path}: {pattern} found {count} times instead of once")
    with open(path, "w") as file:
        file.write(new)
    print(f"patched {name}")
