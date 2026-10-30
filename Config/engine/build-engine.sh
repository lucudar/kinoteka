#!/bin/bash
# Builds Frameworks/TorrServerKit.xcframework, the embedded torrent engine, from the sources of
# TorrServer $TORRSERVER_TAG the way its build-ios.sh does, with two changes for faster starts:
#
# 1. The torrent library of the desktop TorrServer of the same tag (tsynik/torrent v1.2.34). The iOS
#    kit of the tag pins v1.2.31, where a DHT search that comes back empty (started before the DHT
#    table filled up after the start of the engine, or while the network switched) is repeated only
#    in 5 minutes, so the torrent gets its peers from the trackers alone; v1.2.34 repeats it in 15 s.
# 2. Faster connecting to peers (patch-torrent.py): 80 connection attempts at once per torrent
#    instead of 25, up to 40 new ones a second instead of 10, dial timeouts of 2–10 s instead of 3–20 s.
#
# Needs macOS with Xcode, Go (the version of the go.mod of the tag) and python3.
set -euo pipefail

TAG="${TORRSERVER_TAG:?TORRSERVER_TAG is not set}"
TORRENT_VERSION="${TORRENT_VERSION:-v1.2.34}"
IOS_VERSION_MIN="${IOS_VERSION_MIN:-18.0}"
ROOT="$(pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/kinoteka-engine"
OUT="$ROOT/Frameworks/TorrServerKit.xcframework"

go version
rm -rf "$WORK"
mkdir -p "$WORK" "$ROOT/Frameworks"

echo "=== TorrServer $TAG sources"
curl -fsSL --retry 3 -o "$WORK/src.tar.gz" "https://github.com/YouROK/TorrServer/archive/refs/tags/$TAG.tar.gz"
tar -xzf "$WORK/src.tar.gz" -C "$WORK"
SRC="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'TorrServer-*' | head -1)"
KIT="$SRC/server/mobile/torrserverkit"
test -f "$KIT/go.mod"

echo "=== tsynik/torrent $TORRENT_VERSION with the changes of Kinoteka"
mkdir -p "$WORK/mod"
(cd "$WORK/mod" && go mod init kinoteka-engine >/dev/null 2>&1 &&
  go mod download -json "github.com/tsynik/torrent@$TORRENT_VERSION" > "$WORK/torrent.json")
LIBRARY_DIR="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["Dir"])' "$WORK/torrent.json")"
cp -R "$LIBRARY_DIR" "$WORK/torrent"
chmod -R u+w "$WORK/torrent"
python3 "$HERE/patch-torrent.py" "$WORK/torrent"

echo "=== The kit uses this library"
python3 - "$KIT/go.mod" "$WORK/torrent" <<'PY'
import re, sys
path, library = sys.argv[1], sys.argv[2]
text = open(path).read()
new, count = re.subn(r"(github\.com/anacrolix/torrent v[0-9.]+ =>) github\.com/tsynik/torrent v[0-9.]+",
                     lambda m: m.group(1) + " " + library, text)
if count != 1:
    sys.exit(f"{path}: the replace of github.com/anacrolix/torrent is not found")
open(path, "w").write(new)
PY
grep -n "anacrolix/torrent v" "$KIT/go.mod"

echo "=== gomobile"
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
export PATH="$(go env GOPATH)/bin:$PATH"
gomobile init

echo "=== gomobile bind"
cd "$KIT"
go mod tidy
rm -rf "$OUT"
gomobile bind \
  -target=ios \
  -iosversion="$IOS_VERSION_MIN" \
  -tags=nosqlite \
  -ldflags="-s -w -checklinkname=0 -X server/version.Version=$TAG-kinoteka" \
  -trimpath \
  -o "$OUT" \
  .
ls -R "$OUT" | head -20
echo "=== Built: TorrServer $TAG, tsynik/torrent $TORRENT_VERSION with the changes of Kinoteka"
