#!/usr/bin/env bash
# One pilot run with the broker-counter subscriber, then a short summary.
# usage: launcher/try_run.sh <kernel> <user|ukl> <rate> <run_id>
# Needs the bridge (launcher/setup_bridge.sh) and the broker on CPU 4 already running.
set -uo pipefail
cd "$(dirname "$0")/.."
KERNEL=$1 MODE=$2 RATE=$3 RUN=$4
OUT=results/pilot-try/$RUN; mkdir -p "$OUT"
taskset -c 8 artifacts/subscriber/mqtt-subscriber 192.168.150.1 "$RUN" "$OUT" --sys-only > "$OUT/subscriber.log" &
SUB=$!
sleep 2
sudo VCPU_CPU=2 EMU_CPU=6 LOOP=recover RATE="$RATE" launcher/launch.sh "$KERNEL" artifacts/common-initrd.cpio.xz "$MODE" "$RUN" "$OUT/serial.log"
sleep 3; kill -INT $SUB; wait $SUB
echo "=== $RUN"
grep -h PACING "$OUT/serial.log" | tr -d '\r' | cut -d' ' -f4-12
grep -h -E 'UKL-MQTT-BENCH: (WINDOW|DRAIN)' "$OUT/serial.log" | tr -d '\r' \
  | grep -o -E ' (accepted|unsent_after_drain)=[0-9]+' | tr -d '\n'; echo
awk -F= '/broker_received_start/{s=$2} /broker_received_end/{e=$2} END{print "broker_received=" e-s}' "$OUT/summary.txt"
grep -h CPU_SUMMARY "$OUT/serial.log.cpu"
