#!/usr/bin/env bash
# Configurations 3 and 4 share this kernel image. Run inside the build container.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UKL=$ROOT/src/ukl MQTTC=$ROOT/src/MQTT-C OUT=$ROOT/artifacts/ukl
mkdir -p "$OUT"
cd "$UKL"

cp "$MQTTC/src/mqtt.c" "$MQTTC/src/mqtt_pal.c" hello/
cp "$MQTTC/include/mqtt.h" "$MQTTC/include/mqtt_pal.h" hello/
cp "$ROOT/publisher/publisher.c" hello/hello-world.c
cp "$ROOT/publisher/Makefile.am.ukl" hello/Makefile.am

autoreconf -i
# Base UKL: every performance-oriented option explicitly off, as in the thesis build.
./configure CFLAGS="-g -O2" --with-program=hello \
  --disable-bypass --disable-same-stack --disable-use-ret \
  --disable-use-ist-pf --disable-shortcuts
make V=1 -j"$(nproc)" vmlinuz 2>&1 | tee "$OUT/build.log"   # initrd is built separately

cp vmlinuz "$OUT/vmlinuz"
cp linux/.config "$ROOT/configs/ukl.config"
sha256sum "$OUT/vmlinuz" | tee "$OUT/SHA256"
echo "Embedded publisher compile line (use its -O level for the user-space build):"
grep -E 'gcc .*hello-world\.c' "$OUT/build.log" | head -1 || true
