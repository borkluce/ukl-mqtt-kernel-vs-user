#!/usr/bin/env bash
# Fetch every source at a pinned revision. Run inside the build container.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UKL_COMMIT=f66efb6c                                   # thesis commit, Linux 6.3.0
MQTTC_COMMIT=${MQTTC_COMMIT:-7a986a68ebea63921d4aab20a9d1b26a8b5f8c9d}   # thesis commit
UPSTREAM_VERSION=${UPSTREAM_VERSION:-6.3}
mkdir -p "$ROOT/src" && cd "$ROOT/src"

[ -d ukl ] || git clone https://github.com/unikernelLinux/ukl
git -C ukl checkout "$UKL_COMMIT"
git -C ukl submodule update --init

[ -d MQTT-C ] || git clone https://github.com/LiamBindle/MQTT-C
git -C MQTT-C checkout "$MQTTC_COMMIT"

TARBALL="linux-$UPSTREAM_VERSION.tar.xz"
[ -f "$TARBALL" ] || wget -q "https://cdn.kernel.org/pub/linux/kernel/v6.x/$TARBALL"
[ -d "linux-$UPSTREAM_VERSION" ] || tar xJf "$TARBALL"

{
  echo "ukl        $(git -C ukl rev-parse HEAD)"
  echo "ukl/linux  $(git -C ukl/linux rev-parse HEAD)"
  echo "mqtt-c     $(git -C MQTT-C rev-parse HEAD)"
  echo "upstream   $TARBALL sha256 $(sha256sum "$TARBALL" | cut -d' ' -f1)"
} | tee "$ROOT/configs/source-revisions.txt"

# Which upstream release is the UKL kernel based on? Expect a small count on top of v6.3.
if git -C ukl/linux fetch -q https://github.com/torvalds/linux "refs/tags/v$UPSTREAM_VERSION"; then
  echo "UKL commits on top of v$UPSTREAM_VERSION: $(git -C ukl/linux rev-list --count FETCH_HEAD..HEAD)" \
    | tee -a "$ROOT/configs/source-revisions.txt"
else
  echo "Could not fetch the upstream tag; check the base version manually."
fi
