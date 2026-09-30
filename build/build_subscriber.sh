#!/usr/bin/env bash
# Subscriber logger. Runs on the HOST next to the broker, so it is built on the host.
# Needs: sudo apt install libmosquitto-dev
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/artifacts/subscriber
mkdir -p "$OUT"
gcc -O2 -g -Wall -o "$OUT/mqtt-subscriber" "$ROOT/subscriber/subscriber.c" -lmosquitto
{ gcc --version | sed -n 1p; dpkg-query -W -f='libmosquitto1 ${Version}\n' libmosquitto1; } > "$OUT/build-info.txt"
sha256sum "$OUT/mqtt-subscriber" | tee "$OUT/SHA256"
