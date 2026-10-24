#!/usr/bin/env bash
# Run a measurement session. Every (configuration, rate) pair runs once per block; blocks are
# repeated; the order inside each block is shuffled with a recorded seed, so time-dependent drift
# spreads evenly over configurations and the order can be reproduced.
#
# usage: sudo launcher/run_session.sh <session> [reps] [rates] [configs]
#   e.g. sudo launcher/run_session.sh pilot1 3 "0 1000 10000 100000 300000" "c1 c2 c3 c4"
#
# Before: sudo launcher/host_tune.sh apply; sudo launcher/setup_bridge.sh; no mosquitto running
# (the runner starts a fresh broker for every run, so its $SYS counters count only that run).
# Output: results/<session>/session.txt, order.txt, one directory per run, runs.csv.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
SESSION=${1:?usage: $0 <session> [reps] [rates] [configs]}
REPS=${2:-3}
RATES=${3:-"0 1000 10000 100000 300000"}
CONFIGS=${4:-"c1 c2 c3 c4"}
SEED=${SEED:-$(date +%s)}
VCPU_CPU=${VCPU_CPU:-2} SIB_CPU=${SIB_CPU:-3} EMU_CPU=${EMU_CPU:-6}
BROKER_CPU=${BROKER_CPU:-4} SUB_CPU=${SUB_CPU:-8}
CTRL_CPUS=${CTRL_CPUS:-0,1}   # the runner, launcher polling loop and perf stay here, off the experiment cores
BROKER_IP=${BROKER_IP:-192.168.150.1} BROKER_CONF=${BROKER_CONF:-launcher/mosquitto.conf}
LOOP=${LOOP:-recover} COOLDOWN=${COOLDOWN:-5}
EXPECT_HALT_POLL_NS=${EXPECT_HALT_POLL_NS:-0}
INITRD=artifacts/common-initrd.cpio.xz
OUT=results/$SESSION
GIT="git -c safe.directory=$PWD"

kernel_of() { case $1 in c1) echo artifacts/upstream-default/bzImage ;; c2) echo artifacts/upstream-uklcfg/bzImage ;;
                         c3|c4) echo artifacts/ukl/vmlinuz ;; *) echo "unknown config $1" >&2; return 1 ;; esac; }
mode_of() { [ "$1" = c4 ] && echo ukl || echo user; }

# ---- preflight: refuse to start on a setup that differs from the documented one ----
[ -e "$OUT" ] && { echo "$OUT already exists; choose a new session name" >&2; exit 1; }
for c in $CONFIGS; do kernel_of "$c" >/dev/null; done
ip link show br-mqtt >/dev/null 2>&1 || { echo "bridge br-mqtt missing: run launcher/setup_bridge.sh" >&2; exit 1; }
hp=$(cat /sys/module/kvm/parameters/halt_poll_ns)
[ "$hp" = "$EXPECT_HALT_POLL_NS" ] || { echo "halt_poll_ns=$hp, expected $EXPECT_HALT_POLL_NS: run launcher/host_tune.sh apply" >&2; exit 1; }
sha256sum -c --quiet configs/artifact-sha256.txt || { echo "artifacts differ from configs/artifact-sha256.txt" >&2; exit 1; }
pgrep -x mosquitto >/dev/null && { echo "a mosquitto is already running; stop it (the runner starts its own)" >&2; exit 1; }
mkdir -p "$OUT"
taskset -pc "$CTRL_CPUS" $$ >/dev/null   # inherited by every child; QEMU, broker and subscriber re-pin themselves

{
  echo "session=$SESSION seed=$SEED reps=$REPS rates=\"$RATES\" configs=\"$CONFIGS\" loop=$LOOP"
  echo "cpus vcpu=$VCPU_CPU sibling=$SIB_CPU emu=$EMU_CPU broker=$BROKER_CPU subscriber=$SUB_CPU control=$CTRL_CPUS cooldown_s=$COOLDOWN"
  echo "date=$(date -Is) host_kernel=$(uname -r)"
  echo "git_head=$($GIT rev-parse HEAD) git_modified_tracked_files=$($GIT status --porcelain --untracked-files=no | wc -l)"
  echo "qemu=$(qemu-system-x86_64 --version | head -1)"
  echo "mosquitto=$(mosquitto -h 2>&1 | head -1)"
  launcher/host_tune.sh status || true
  cat configs/artifact-sha256.txt
} > "$OUT/session.txt"

python3 - "$SEED" "$REPS" "$CONFIGS" "$RATES" > "$OUT/order.txt" <<'PY'
import random, sys
seed, reps = int(sys.argv[1]), int(sys.argv[2])
cfgs, rates = sys.argv[3].split(), sys.argv[4].split()
rng = random.Random(seed)
n = 0
for block in range(1, reps + 1):
    cells = [(c, r) for c in cfgs for r in rates]
    rng.shuffle(cells)
    for c, r in cells:
        n += 1
        print(n, block, c, r)
PY

TOTAL=$(wc -l < "$OUT/order.txt")
echo "session $SESSION: $TOTAL runs, seed $SEED"
while read -r N BLOCK CFG RATE <&3; do   # fd 3: nothing in the loop can eat the list
  RUN=$(printf '%s-%03d-b%d-%s-r%s' "$SESSION" "$N" "$BLOCK" "$CFG" "$RATE")
  D=$OUT/$RUN
  mkdir -p "$D"
  KERNEL=$(kernel_of "$CFG") MODE=$(mode_of "$CFG")
  echo "n=$N block=$BLOCK config=$CFG mode=$MODE rate=$RATE kernel=$KERNEL start=$(date -Is)" > "$D/runner.txt"

  # fresh broker on its own core
  taskset -c "$BROKER_CPU" mosquitto -c "$BROKER_CONF" > "$D/broker.log" 2>&1 &
  BROKER=$!
  for ((i = 0; i < 50; i++)); do
    mosquitto_sub -h "$BROKER_IP" -t '$SYS/broker/version' -C 1 -W 1 >/dev/null 2>&1 && break
    sleep 0.1
  done

  taskset -c "$SUB_CPU" artifacts/subscriber/mqtt-subscriber "$BROKER_IP" "$RUN" "$D" --sys-only > "$D/subscriber.log" 2>&1 &
  SUB=$!
  sleep 2

  RC=0
  VCPU_CPU=$VCPU_CPU EMU_CPU=$EMU_CPU MONITOR_CPUS="$VCPU_CPU $SIB_CPU $BROKER_CPU $EMU_CPU" \
  EXTRA_PIDS="broker=$BROKER subscriber=$SUB" LOOP=$LOOP RATE=$RATE \
    launcher/launch.sh "$KERNEL" "$INITRD" "$MODE" "$RUN" "$D/serial.log" < /dev/null || RC=$?

  sleep 2   # the broker publishes $SYS once a second: let the counts after the final drain arrive
  kill -INT "$SUB" 2>/dev/null || true; wait "$SUB" 2>/dev/null || true
  kill "$BROKER" 2>/dev/null || true; wait "$BROKER" 2>/dev/null || true
  echo "launcher_rc=$RC end=$(date -Is)" >> "$D/runner.txt"
  printf '[%d/%d] %s rc=%d %s\n' "$N" "$TOTAL" "$RUN" "$RC" \
    "$(grep -h -o 'achieved_per_s=[0-9.]*' "$D/serial.log" 2>/dev/null | head -1)"
  sleep "$COOLDOWN"
done 3< "$OUT/order.txt"

python3 analysis/collect.py "$OUT" > "$OUT/runs.csv"
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER": "$OUT"
echo "done: $OUT/runs.csv"
