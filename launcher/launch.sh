#!/usr/bin/env bash
# Common QEMU launcher: identical for all four configurations. Run as root on the host.
# usage: launch.sh <kernel> <initrd> <user|ukl> <run_id> <serial_log>
#
# Environment:
#   LOOP      thesis | recover (publisher loop, default thesis)
#   RATE      max | N (messages per second; 0 = idle run; default max)
#   VCPU_CPU  host CPU for the guest vCPU thread ("CPU 0/KVM")
#   EMU_CPU   host CPU for every other QEMU thread (main loop and virtio-net backend)
#
# Host-side CPU accounting: per-thread CPU time of the QEMU process is read from /proc at the
# start and at the end of the publisher's measurement window and written to <serial_log>.cpu.
# The window is located from the publisher's serial output ("running for" -> "PACING"), polled
# every 50 ms. The netdev has no vhost=on, so the virtio-net backend runs in QEMU's own threads
# and is included; the snapshot also counts any vhost kernel threads as a check.
set -euo pipefail
KERNEL=$1 INITRD=$2 MODE=$3 RUN_ID=$4 LOG=$5
LOOP=${LOOP:-thesis} RATE=${RATE:-max}
case $MODE in user|ukl) ;; *) echo "mode must be user or ukl" >&2; exit 2 ;; esac
case $LOOP in thesis|recover) ;; *) echo "LOOP must be thesis or recover" >&2; exit 2 ;; esac
[[ $RATE == max || $RATE =~ ^[0-9]+$ ]] || { echo "RATE must be max or a number" >&2; exit 2; }

GUEST_IP=${GUEST_IP:-192.168.150.128}
GUEST_MAC=${GUEST_MAC:-52:54:00:12:34:56}
BRIDGE=${BRIDGE:-br-mqtt}           # from setup_bridge.sh; broker on 192.168.150.1
TAPDEV=${TAPDEV:-tap0}
SMP=${SMP:-1} MEM=${MEM:-4G}
# On a hybrid CPU use P-cores (`lscpu -e`: higher MAXMHZ), one thread per physical core, and keep
# the broker on yet another physical core.
VCPU_CPU=${VCPU_CPU:?set VCPU_CPU, e.g. 2}
EMU_CPU=${EMU_CPU:?set EMU_CPU, e.g. 6}
TIMEOUT=${TIMEOUT:-120}             # hard stop; a timed-out run is kept and labelled
CPU_LOG=$LOG.cpu
DONE_MARKER="UKL-MQTT-BENCH: done"
START_MARKER="UKL-MQTT-BENCH: broker connected"
END_MARKER="UKL-MQTT-BENCH: PACING"

ip link del "$TAPDEV" 2>/dev/null || true
ip tuntap add dev "$TAPDEV" mode tap
cleanup() { [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null || true; ip tuntap del dev "$TAPDEV" mode tap 2>/dev/null || true; }
trap cleanup EXIT
ip link set "$TAPDEV" master "$BRIDGE"
ip link set "$TAPDEV" up
: > "$LOG"
: > "$CPU_LOG"

taskset -c "$EMU_CPU" qemu-system-x86_64 \
  -name guest,debug-threads=on \
  -cpu host,-smap,-smep -accel kvm -m "$MEM" -smp "$SMP" \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -nodefaults -nographic -no-reboot -serial "file:$LOG" \
  -append "console=ttyS0 panic=1 net.ifnames=0 biosdevname=0 clearcpuid=smap,smep mitigations=off mds=off -- $GUEST_IP $GUEST_MAC $MODE $RUN_ID $LOOP $RATE" \
  -netdev tap,ifname="$TAPDEV",id=eth0,script=no,downscript=no \
  -device virtio-net-pci,netdev=eth0,mac="$GUEST_MAC" &
QPID=$!

# Move the vCPU thread to its own core; everything else stays on EMU_CPU.
VCPU_TID=
for ((t = 0; t < 100; t++)); do
  for task in /proc/$QPID/task/*; do
    [ "$(cat "$task/comm" 2>/dev/null)" = "CPU 0/KVM" ] && VCPU_TID=${task##*/}
  done
  [ -n "$VCPU_TID" ] && break
  sleep 0.05
done
[ -n "$VCPU_TID" ] || { echo "vCPU thread not found" >&2; exit 1; }
taskset -p -c "$VCPU_CPU" "$VCPU_TID" >/dev/null

snapshot() {   # $1 = start | end
  local label=$1 now task tid comm oncpu stat rest
  now=$(date +%s.%N)
  for task in /proc/$QPID/task/*; do
    tid=${task##*/}
    comm=$(cat "$task/comm" 2>/dev/null) || continue
    read -r oncpu _ < "$task/schedstat" || continue
    stat=$(cat "$task/stat" 2>/dev/null) || continue
    rest=${stat##*) }
    set -- $rest   # $12 utime, $13 stime (clock ticks), $37 last CPU
    echo "CPU_SNAPSHOT label=$label t=$now tid=$tid oncpu_ns=$oncpu utime_ticks=${12} stime_ticks=${13} last_cpu=${37} comm=$comm"
  done >> "$CPU_LOG"
  echo "VHOST_THREADS label=$label count=$(pgrep -c "^vhost-$QPID" || true)" >> "$CPU_LOG"
}

# Both publishers idle after printing the done marker, so stop QEMU on the marker.
STATUS=timeout HAVE_START=0 HAVE_END=0
for ((t = 0; t < TIMEOUT * 20; t++)); do
  if [ $HAVE_START = 0 ] && grep -q "$START_MARKER" "$LOG"; then snapshot start; HAVE_START=1; fi
  if [ $HAVE_END = 0 ] && grep -q "$END_MARKER" "$LOG"; then snapshot end; HAVE_END=1; fi
  if grep -q "$DONE_MARKER" "$LOG"; then STATUS=done; sleep 1; break; fi
  kill -0 "$QPID" 2>/dev/null || { STATUS=qemu-exited; break; }
  sleep 0.05
done
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

# Per-run summary: CPU time used by the vCPU thread and by the whole QEMU process in the window.
if [ $HAVE_START = 1 ] && [ $HAVE_END = 1 ]; then
  awk -v vt="$VCPU_TID" '
    /^CPU_SNAPSHOT/ {
      for (i = 2; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
      if (f["label"] == "start") { s[f["tid"]] = f["oncpu_ns"]; ts = f["t"] }
      else                       { e[f["tid"]] = f["oncpu_ns"]; te = f["t"] }
    }
    /^VHOST_THREADS/ { split($3, kv, "="); if (kv[2] > vh) vh = kv[2] }
    END {
      for (t in e) { d = e[t] - (t in s ? s[t] : 0); tot += d; if (t == vt) vc = d }
      printf "CPU_SUMMARY wall_s=%.3f vcpu_s=%.3f qemu_total_s=%.3f qemu_other_s=%.3f vhost_threads=%d\n",
             te - ts, vc / 1e9, tot / 1e9, (tot - vc) / 1e9, vh
    }' "$CPU_LOG" >> "$CPU_LOG"
fi
echo "LAUNCHER_STATUS=$STATUS run_id=$RUN_ID mode=$MODE loop=$LOOP rate=$RATE vcpu_cpu=$VCPU_CPU emu_cpu=$EMU_CPU" >> "$LOG"
[ "$STATUS" = done ]
