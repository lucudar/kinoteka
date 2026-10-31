#!/usr/bin/env python3
"""The changes of Kinoteka in the TorrServer sources (server/ of the tag), with kinoteka-web.go and
kinoteka-kit.go copied next to the patched files by build-engine.sh:

- web.Start keeps its routes, so web.Relisten can open the ports again with them;
- StartServer of the iOS kit waits for the web server with watchServer: a server that fails is
  opened again instead of the engine being marked as stopped while its torrent client runs;
- a start that failed after connecting the torrent client closes it before the next start;
- new settings (the app saves them for another network and to connect a torrent client that lost
  its sockets) are applied in tens of milliseconds instead of 3.5 s: SetSettings paused for a second
  before and after reconnecting the client (dropAllTorrent waits for the torrents to close, and
  reconnect retries a busy port by itself), and the stop of the rutor search waited 1.5 s even
  though the search (off in the app) never ran.

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
    ("torr/apihelper.go",
     r"(\n\tdropAllTorrent\(\))\n\ttime\.Sleep\(time\.Second \* 1\)"
     r"(\n\tlog\.TLogln\(\"disconect\"\)\n\tbts\.Disconnect\(\)\n\tlog\.TLogln\(\"connect\"\)\n\treconnect\(\))"
     r"\n\ttime\.Sleep\(time\.Second \* 1\)(\n\tlog\.TLogln\(\"end set settings\"\))",
     "\\1 // Kinoteka: without the pauses of a second before and after the reconnect\\2\\3"),
    ("rutor/rutor.go",
     r"\n\tisStop bool\n",
     "\n\tisStop = true // Kinoteka: no loop of the search runs before Start turns it on\n"),
    ("rutor/rutor.go",
     r"(func Stop\(\) \{\n\tmu\.Lock\(\)\n)(\tisStop = true\n)",
     "\\1\trunning := !isStop // Kinoteka\n\\2"),
    ("rutor/rutor.go",
     r"(\n\tutils2\.FreeOSMemGC\(\))\n\ttime\.Sleep\(time\.Millisecond \* 1500\)\n\}",
     "\\1\n\tif running { // Kinoteka: only a running loop needs the time to see the stop\n"
     "\t\ttime.Sleep(time.Millisecond * 1500)\n\t}\n}"),
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
