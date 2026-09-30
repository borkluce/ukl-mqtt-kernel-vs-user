#!/usr/bin/env bash
# Static user-space publisher from the same sources as the embedded one. Run inside the build container.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MQTTC=$ROOT/src/MQTT-C OUT=$ROOT/artifacts/publisher-user
# Same optimisation as the embedded build (-g -O2, verified in the thesis object file).
# No -DBENCHMARK_EXIT: both publishers run the identical code path and idle when done;
# the launcher stops QEMU when it sees the done marker.
CFLAGS_USER=${CFLAGS_USER:-"-g -O2"}
mkdir -p "$OUT"
gcc $CFLAGS_USER -static -I"$MQTTC/include" \
  -o "$OUT/mqtt-publisher" \
  "$ROOT/publisher/publisher.c" "$MQTTC/src/mqtt.c" "$MQTTC/src/mqtt_pal.c" -lpthread
{ echo "CFLAGS_USER=$CFLAGS_USER"; gcc --version | sed -n 1p; ldd --version | sed -n 1p; } > "$OUT/build-info.txt"
sha256sum "$OUT/mqtt-publisher" | tee "$OUT/SHA256"
