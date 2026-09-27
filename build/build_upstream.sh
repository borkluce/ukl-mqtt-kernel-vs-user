#!/usr/bin/env bash
# Configurations 1 and 2: upstream Linux, same compiler as the UKL build. Run inside the build container.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=${UPSTREAM_VERSION:-6.3}
SRC=$ROOT/src/linux-$VER CFG=$ROOT/configs
[ -f "$CFG/ukl.config" ] || { echo "Run build_ukl.sh first (needs configs/ukl.config)"; exit 1; }

build() {   # $1 = name; its .config must already be in build/out-$1
  local out=$ROOT/build/out-$1
  make -C "$SRC" O="$out" olddefconfig
  make -C "$SRC" O="$out" -j"$(nproc)" bzImage 2>&1 | tee "$out/build.log"
  mkdir -p "$ROOT/artifacts/$1"
  cp "$out/arch/x86/boot/bzImage" "$ROOT/artifacts/$1/bzImage"
  cp "$out/.config" "$CFG/$1.config"
  sha256sum "$ROOT/artifacts/$1/bzImage" | tee "$ROOT/artifacts/$1/SHA256"
}

# 1. Upstream with its own default configuration for a KVM guest.
out=$ROOT/build/out-upstream-default; mkdir -p "$out"
make -C "$SRC" O="$out" x86_64_defconfig
make -C "$SRC" O="$out" kvm_guest.config
# Minimum needed to boot the common initrd; state this in the plan.
"$SRC/scripts/config" --file "$out/.config" \
  -e DEVTMPFS -e BLK_DEV_INITRD -e RD_LZMA -e VIRTIO_NET -e SERIAL_8250_CONSOLE
build upstream-default

# 2. Upstream with the UKL project configuration, UKL-only symbols removed.
out=$ROOT/build/out-upstream-uklcfg; mkdir -p "$out"
grep -v -E '^(# )?CONFIG_(UNIKERNEL_LINUX|UKL_)' "$CFG/ukl.config" > "$out/.config"
build upstream-uklcfg

# Exactly what changes between configurations.
"$SRC/scripts/diffconfig" "$CFG/upstream-default.config" "$CFG/upstream-uklcfg.config" > "$CFG/diff-1-vs-2.txt"
"$SRC/scripts/diffconfig" "$CFG/upstream-uklcfg.config" "$CFG/ukl.config" > "$CFG/diff-2-vs-3.txt"
wc -l "$CFG"/diff-*.txt
