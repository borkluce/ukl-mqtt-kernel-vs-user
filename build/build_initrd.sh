#!/usr/bin/env bash
# One initrd for all four configurations. Run on the HOST (needs docker --privileged for mknod).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/build/initrd-work
rm -rf "$WORK"; cp -r "$ROOT/src/ukl/initrd" "$WORK"

cp "$ROOT/initrd/init.common" "$WORK/init"
# ukl-base does not install perf and nothing here needs it (thesis PR #39).
sed -i -e '/^cp \.\/perf/d' -e 's/ perf ethtool/ ethtool/' "$WORK/buildinitrd.sh"

mkdir -p "$WORK/data/usr/bin"
install -m755 "$ROOT/artifacts/publisher-user/mqtt-publisher" "$WORK/data/usr/bin/"
tar czf "$WORK/data.tar.gz" -C "$WORK/data" .

docker build -q -t ukl-base:f36 "$WORK/ukl-base" >/dev/null
docker run --rm --privileged -v "$WORK:/src" -w /src ukl-base:f36 \
  bash -c './set-passwd.sh && ./buildinitrd.sh ukl-initrd && rm -rf ukl-initrd'

mkdir -p "$ROOT/artifacts"
install -m644 "$WORK/ukl-initrd.cpio.xz" "$ROOT/artifacts/common-initrd.cpio.xz"
sha256sum "$ROOT/artifacts/common-initrd.cpio.xz" | tee "$ROOT/artifacts/common-initrd.SHA256"
