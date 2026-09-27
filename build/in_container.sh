#!/usr/bin/env bash
# Run a command inside the pinned build image, with the repo mounted at the same path.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
docker build -q -t ukl-mqtt-build:22.04 "$ROOT/build" >/dev/null
exec docker run --rm -it --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e MQTTC_COMMIT -e UPSTREAM_VERSION -e CFLAGS_USER \
  -v "$ROOT:$ROOT" -w "$ROOT" ukl-mqtt-build:22.04 "$@"
