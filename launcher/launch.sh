#!/usr/bin/env bash
# Common QEMU launcher: identical for all four configurations. Run as root on the host.
# usage: launch.sh <kernel> <initrd> <user|ukl> <run_id> <serial_log>
#
# Environment:
#   LOOP      thesis | recover (publisher loop, default thesis)
#   RATE      max | N (messages per second; 0 = idle run; default max)
#   VCPU_CPU  host CPU for the guest vCPU thread ("CPU 0/KVM")
#   EMU_CPU   host CPU for every other QEMU thread (main loop and virtio-net backend)
#   MONITOR_CPUS  host CPUs whose busy time is recorded for the window (default: VCPU_CPU EMU_CPU),
#             from the scheduler's run-time counters in /proc/schedstat (not the tick-sampled
#             /proc/stat, which aliases with a guest that wakes on every host tick)
#   PERF      1 (default) to count vCPU-thread cycles and instructions with perf, 0 to skip
#   EXTRA_PIDS    other host processes to account in the same window, as name=pid pairs
#             (the runner passes "broker=<pid> subscriber=<pid>")
#
# Host-side CPU accounting: per-thread CPU time of the QEMU process is read from /proc at the
# start and at the end of the publisher's measurement window and written to <serial_log>.cpu.
# The window is located from the publisher's serial output ("running for" -> "PACING"), polled
# every 50 ms. The netdev has no vhost=on, so the virtio-net backend runs in QEMU's own threads
# and is included; the snapshot also counts any vhost kernel threads as a check.
# perf counts cycles and instructions of the vCPU thread in the same window, split into guest
# mode (:G) and host mode (:H, KVM exits handled in the host kernel). Instructions do not depend
# on the clock frequency, so they separate frequency changes from changes in the work done.
# KVM's own per-VM counters (debugfs, root only) are read at both ends of the window as well:
# VM exits, HLT exits and halt-polling time, which is where host-side cost varies.
# The host tap interface counters give packets and bytes sent and received by the guest in the
# window (host rx = guest tx), so per-message packet counts can be compared across configurations.
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
MONITOR_CPUS=${MONITOR_CPUS:-"$VCPU_CPU $EMU_CPU"}
PERF=${PERF:-1}
CPU_LOG=$LOG.cpu
PERF_LOG=$LOG.perf
SCHEDSTAT_FILE=${SCHEDSTAT_FILE:-/proc/schedstat}
KVM_DEBUGFS=${KVM_DEBUGFS:-/sys/kernel/debug/kvm}
KVM_STATS="exits halt_exits halt_wakeup halt_attempted_poll halt_successful_poll halt_poll_invalid halt_poll_success_ns halt_poll_fail_ns halt_wait_ns irq_injections"
DONE_MARKER="UKL-MQTT-BENCH: done"
START_MARKER="UKL-MQTT-BENCH: broker connected"
END_MARKER="UKL-MQTT-BENCH: PACING"

ip link del "$TAPDEV" 2>/dev/null || true
ip tuntap add dev "$TAPDEV" mode tap
cleanup() { [ -n "${PERF_PID:-}" ] && kill -INT "$PERF_PID" 2>/dev/null || true
            [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null || true; ip tuntap del dev "$TAPDEV" mode tap 2>/dev/null || true; }
trap cleanup EXIT
ip link set "$TAPDEV" master "$BRIDGE"
ip link set "$TAPDEV" up
: > "$LOG"
: > "$CPU_LOG"
rm -f "$PERF_LOG"
{ echo "HOST schedstat_$(head -1 "$SCHEDSTAT_FILE" | tr ' ' '=') halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null || echo na)" \
       "governor=$(cat /sys/devices/system/cpu/cpu$VCPU_CPU/cpufreq/scaling_governor 2>/dev/null || echo na)" \
       "cur_khz=$(cat /sys/devices/system/cpu/cpu$VCPU_CPU/cpufreq/scaling_cur_freq 2>/dev/null || echo na)" \
       "no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo na)"; } >> "$CPU_LOG"

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
  for c in $MONITOR_CPUS; do   # cpuN yld 0 sched_count sched_goidle ttwu ttwu_local rq_cpu_time_ns run_delay_ns pcount
    grep "^cpu$c " "$SCHEDSTAT_FILE" | sed "s/^/SCHEDSTAT label=$label t=$now /"
  done >> "$CPU_LOG"
  local nd=/sys/class/net/$TAPDEV/statistics
  [ -r "$nd/rx_packets" ] && echo "NETSTAT label=$label guest_tx_packets=$(cat $nd/rx_packets) guest_tx_bytes=$(cat $nd/rx_bytes)" \
       "guest_rx_packets=$(cat $nd/tx_packets) guest_rx_bytes=$(cat $nd/tx_bytes)" >> "$CPU_LOG"
  local spec pname ppid sum thr on
  for spec in ${EXTRA_PIDS:-}; do
    pname=${spec%%=*} ppid=${spec#*=} sum=0
    for thr in /proc/$ppid/task/*; do
      { read -r on _ < "$thr/schedstat"; } 2>/dev/null && sum=$((sum + on))
    done
    echo "PROC_SNAPSHOT label=$label t=$now name=$pname pid=$ppid oncpu_ns=$sum"
  done >> "$CPU_LOG"
  local vmdir
  for vmdir in "$KVM_DEBUGFS"/"$QPID"-*; do
    [ -d "$vmdir" ] || continue
    local st line="KVMSTAT label=$label"
    for st in $KVM_STATS; do line="$line $st=$(cat "$vmdir/$st" 2>/dev/null || echo na)"; done
    echo "$line" >> "$CPU_LOG"
  done
}

# Both publishers idle after printing the done marker, so stop QEMU on the marker.
STATUS=timeout HAVE_START=0 HAVE_END=0
for ((t = 0; t < TIMEOUT * 20; t++)); do
  if [ $HAVE_START = 0 ] && grep -q "$START_MARKER" "$LOG"; then
    snapshot start; HAVE_START=1
    if [ "$PERF" = 1 ] && command -v perf >/dev/null; then
      perf stat -x, -e cycles:G,instructions:G,cycles:H,instructions:H -t "$VCPU_TID" -o "$PERF_LOG" &
      PERF_PID=$!
    fi
  fi
  if [ $HAVE_END = 0 ] && grep -q "$END_MARKER" "$LOG"; then
    if [ -n "${PERF_PID:-}" ]; then   # SIGINT makes perf stat write its counts; never wait more than 2 s
      kill -INT "$PERF_PID" 2>/dev/null || true
      for ((w = 0; w < 40; w++)); do kill -0 "$PERF_PID" 2>/dev/null || break; sleep 0.05; done
      kill -TERM "$PERF_PID" 2>/dev/null || true; wait "$PERF_PID" 2>/dev/null || true; PERF_PID=
    fi
    snapshot end; HAVE_END=1
  fi
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
  # Busy share of each monitored host CPU in the window: run time of all tasks on that CPU
  # (rq_cpu_time, ns) over wall time. Includes the vCPU thread's guest-mode time.
  awk '/^SCHEDSTAT/ {
         split($3, tv, "="); c = $4; ns = $11
         if ($2 == "label=start") { r0[c] = ns; w0 = tv[2] } else { r1[c] = ns; w1 = tv[2]; seen[c] = 1 }
       }
       END { line = "CPU_BUSY"; wall = w1 - w0
             for (c in seen) line = line sprintf(" %s=%.1f%%", c, wall > 0 ? 100 * (r1[c] - r0[c]) / 1e9 / wall : 0)
             print line }' "$CPU_LOG" >> "$CPU_LOG"
  # CPU time of the extra host processes (broker, subscriber) in the window.
  if [ -n "${EXTRA_PIDS:-}" ]; then
    awk '/^PROC_SNAPSHOT/ {
           for (i = 2; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
           if (f["label"] == "start") a[f["name"]] = f["oncpu_ns"]; else { b[f["name"]] = f["oncpu_ns"]; k[++n] = f["name"] }
         }
         END { line = "PROC_SUMMARY"; for (i = 1; i <= n; i++) line = sprintf("%s %s_s=%.3f", line, k[i], (b[k[i]] - a[k[i]]) / 1e9); print line }' "$CPU_LOG" >> "$CPU_LOG"
  fi
  # Guest network traffic over the window, from the host tap counters.
  awk '/^NETSTAT/ {
         for (i = 3; i <= NF; i++) { split($i, kv, "="); if ($2 == "label=start") a[kv[1]] = kv[2]; else { b[kv[1]] = kv[2]; k[++n] = kv[1] } }
       }
       END { if (!n) { print "NET_SUMMARY unavailable"; exit }
             line = "NET_SUMMARY"; for (i = 1; i <= n; i++) line = line " " k[i] "=" (b[k[i]] - a[k[i]]); print line }' "$CPU_LOG" >> "$CPU_LOG"
  # KVM per-VM counters over the window.
  awk '/^KVMSTAT/ {
         for (i = 3; i <= NF; i++) { split($i, kv, "="); if ($2 == "label=start") a[kv[1]] = kv[2]; else { b[kv[1]] = kv[2]; k[++n] = kv[1] } }
       }
       END { if (!n) { print "KVM_SUMMARY unavailable"; exit }
             line = "KVM_SUMMARY"
             for (i = 1; i <= n; i++) { s = k[i]; line = line " " s "=" ((a[s] == "na" || b[s] == "na") ? "na" : b[s] - a[s]) }
             print line }' "$CPU_LOG" >> "$CPU_LOG"
  # Cycles and instructions of the vCPU thread (perf -x, CSV; hybrid CPUs report cpu_core/ and cpu_atom/).
  if [ -s "$PERF_LOG" ]; then
    awk -F, '
      NF >= 4 && $1 ~ /^[0-9]+$/ {
        ev = $3; sub(/^cpu_[a-z]+\//, "", ev); sub(/\/$/, "", ev); gsub(/\//, ":", ev)   # -> cycles:G
        n[ev] += $1; if (ev == "cycles:G") rt += $4                                       # counter run time, ns
      }
      END {
        cyc = n["cycles:G"] + n["cycles:H"]; ghz = 0; if (rt > 0) ghz = cyc / rt
        printf "PERF_SUMMARY guest_cycles=%.0f guest_instr=%.0f host_cycles=%.0f host_instr=%.0f counted_s=%.3f vcpu_ghz=%.3f\n",
               n["cycles:G"], n["instructions:G"], n["cycles:H"], n["instructions:H"], rt / 1e9, ghz
      }' "$PERF_LOG" >> "$CPU_LOG"
  else
    echo "PERF_SUMMARY unavailable" >> "$CPU_LOG"
  fi
fi
echo "LAUNCHER_STATUS=$STATUS run_id=$RUN_ID mode=$MODE loop=$LOOP rate=$RATE vcpu_cpu=$VCPU_CPU emu_cpu=$EMU_CPU" >> "$LOG"
[ "$STATUS" = done ]
