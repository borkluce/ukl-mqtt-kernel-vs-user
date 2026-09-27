#!/usr/bin/env bash
# Common QEMU launcher: identical for all four configurations. Run as root on the host.
# usage: launch.sh <kernel> <initrd> <user|ukl> <run_id> <serial_log>
set -euo pipefail
KERNEL=$1 INITRD=$2 MODE=$3 RUN_ID=$4 LOG=$5
case $MODE in user|ukl) ;; *) echo "mode must be user or ukl" >&2; exit 2 ;; esac

GUEST_IP=${GUEST_IP:-192.168.150.128}
GUEST_MAC=${GUEST_MAC:-52:54:00:12:34:56}
BRIDGE=${BRIDGE:-br-mqtt}           # from setup_bridge.sh; broker on 192.168.150.1
TAPDEV=${TAPDEV:-tap0}
SMP=${SMP:-1} MEM=${MEM:-4G}
# Host cores for QEMU. On a hybrid CPU pick P-cores (check `lscpu -e`: higher MAXMHZ),
# one thread per physical core, and keep broker/subscriber on other cores.
QEMU_CPUS=${QEMU_CPUS:?set QEMU_CPUS to the P-core(s) reserved for the guest, e.g. 2}
TIMEOUT=${TIMEOUT:-120}             # hard stop; a timed-out run is kept and labelled
DONE_MARKER="UKL-MQTT-BENCH: done"

ip tuntap add dev "$TAPDEV" mode tap
cleanup() { [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null; ip tuntap del dev "$TAPDEV" mode tap 2>/dev/null || true; }
trap cleanup EXIT
ip link set "$TAPDEV" master "$BRIDGE"
ip link set "$TAPDEV" up
: > "$LOG"

taskset -c "$QEMU_CPUS" qemu-system-x86_64 \
  -cpu host,-smap,-smep -accel kvm -m "$MEM" -smp "$SMP" \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -nodefaults -nographic -no-reboot -serial "file:$LOG" \
  -append "console=ttyS0 panic=1 net.ifnames=0 biosdevname=0 clearcpuid=smap,smep mitigations=off mds=off -- $GUEST_IP $GUEST_MAC $MODE $RUN_ID" \
  -netdev tap,ifname="$TAPDEV",id=eth0,script=no,downscript=no \
  -device virtio-net-pci,netdev=eth0,mac="$GUEST_MAC" &
QPID=$!

# Both publishers idle after printing the done marker, so stop QEMU on the marker.
STATUS=timeout
for ((t = 0; t < TIMEOUT * 10; t++)); do
  if grep -q "$DONE_MARKER" "$LOG"; then STATUS=done; sleep 1; break; fi
  kill -0 "$QPID" 2>/dev/null || { STATUS=qemu-exited; break; }
  sleep 0.1
done
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
echo "LAUNCHER_STATUS=$STATUS run_id=$RUN_ID mode=$MODE" >> "$LOG"
[ "$STATUS" = done ]
