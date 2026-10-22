#!/usr/bin/env bash
# Hold host CPU frequency steady during measurements. Runtime settings only: a reboot restores
# the defaults, so run "apply" once after each boot, before the bridge and the broker.
#
# usage: sudo launcher/host_tune.sh apply | status | halt-poll <ns>
#   apply   - governor "performance" on every CPU (intel_pstate also sets EPP to performance)
#           - turbo off (turbo frequency depends on temperature and on load on other cores)
#           - min = max = base frequency on every CPU that reports one, so the clock is fixed
#           - system services (system.slice, init.scope) limited to SERVICE_CPUS, so the cores
#             used by the experiment only run the experiment and the user session
#           - KVM halt polling off (halt_poll_ns=HALT_POLL_NS, default 0): with polling on, the vCPU
#             thread busy-waits in the host after each guest HLT for an adaptive time, which made
#             host-side vCPU cost vary 2x between identical runs in the pilot
#           - on BUSY_CPUS (guest vCPU, broker, QEMU emulator) every idle state except POLL and C1
#             disabled: waking from deep idle 1000 times a second left these cores below the fixed
#             clock for part of each burst. Their hyperthread siblings keep all idle states.
#   status  - print the current settings (the runner records this before each session)
#   halt-poll <ns> - set KVM halt polling (kvm.halt_poll_ns). When the guest halts, KVM busy-waits
#             in the host for up to this long, adaptively, before putting the vCPU thread to sleep.
#             0 disables it; the kernel default is 200000. Applies to VMs started afterwards.
set -euo pipefail
ACTION=${1:-status}
SERVICE_CPUS=${SERVICE_CPUS:-0,1,8-11}   # keep off 2-7 (guest, its sibling, broker, QEMU emulator)
BUSY_CPUS=${BUSY_CPUS:-"2 4 6"}
HALT_POLL_NS=${HALT_POLL_NS:-0}
SYS=/sys/devices/system/cpu

status() {
  echo "HOST_TUNE governor=$(cat $SYS/cpu2/cpufreq/scaling_governor)" \
       "epp=$(cat $SYS/cpu2/cpufreq/energy_performance_preference 2>/dev/null || echo na)" \
       "no_turbo=$(cat $SYS/intel_pstate/no_turbo 2>/dev/null || echo na)" \
       "power_profile=$(powerprofilesctl get 2>/dev/null || echo na)" \
       "halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null || echo na)" \
       "ac_online=$(cat /sys/class/power_supply/*/online 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  for c in $SYS/cpu[0-9]*; do
    [ -r "$c/cpufreq/scaling_cur_freq" ] || continue
    echo "HOST_TUNE_CPU cpu=${c##*cpu} base_khz=$(cat $c/cpufreq/base_frequency 2>/dev/null || echo na)" \
         "min_khz=$(cat $c/cpufreq/scaling_min_freq) max_khz=$(cat $c/cpufreq/scaling_max_freq)" \
         "cur_khz=$(cat $c/cpufreq/scaling_cur_freq)"
  done
  local c st names
  for c in $BUSY_CPUS; do
    names=
    for st in $SYS/cpu$c/cpuidle/state*; do
      [ -d "$st" ] || continue
      [ "$(cat $st/disable)" = 0 ] && names="$names$(cat $st/name),"
    done
    echo "HOST_TUNE_IDLE cpu=$c enabled_states=${names%,}"
  done
  echo "HOST_TUNE_CPUSET system.slice=$(systemctl show -p AllowedCPUs --value system.slice 2>/dev/null)" \
       "init.scope=$(systemctl show -p AllowedCPUs --value init.scope 2>/dev/null)"
}

apply() {
  [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
  command -v powerprofilesctl >/dev/null && powerprofilesctl set performance || true
  for g in $SYS/cpu[0-9]*/cpufreq/scaling_governor; do echo performance > "$g"; done
  [ -w $SYS/intel_pstate/no_turbo ] && echo 1 > $SYS/intel_pstate/no_turbo
  for c in $SYS/cpu[0-9]*; do
    [ -r "$c/cpufreq/base_frequency" ] || continue
    base=$(cat "$c/cpufreq/base_frequency")
    echo "$base" > "$c/cpufreq/scaling_max_freq"   # max first, then min, so min <= max holds
    echo "$base" > "$c/cpufreq/scaling_min_freq"
  done
  echo "$HALT_POLL_NS" > /sys/module/kvm/parameters/halt_poll_ns
  local c st
  for c in $BUSY_CPUS; do
    for st in $SYS/cpu$c/cpuidle/state*; do
      [ -d "$st" ] || continue
      case "$(cat $st/name)" in POLL|C1|C1_ACPI) echo 0 > $st/disable ;; *) echo 1 > $st/disable ;; esac
    done
  done
  systemctl set-property --runtime system.slice AllowedCPUs="$SERVICE_CPUS"
  systemctl set-property --runtime init.scope AllowedCPUs="$SERVICE_CPUS"
}

case $ACTION in
  apply)  apply; status ;;
  halt-poll)
    [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
    [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "usage: $0 halt-poll <ns>" >&2; exit 2; }
    echo "$2" > /sys/module/kvm/parameters/halt_poll_ns
    echo "HOST_TUNE halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns)" ;;
  status) status ;;
  *) echo "usage: $0 apply|status|halt-poll <ns>" >&2; exit 2 ;;
esac
