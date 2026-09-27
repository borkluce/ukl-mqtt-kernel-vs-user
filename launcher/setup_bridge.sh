#!/usr/bin/env bash
# Dedicated experiment bridge on the host: 192.168.150.1/24, the broker address compiled into
# the thesis publisher. Kept separate from libvirt's virbr0 so other VMs cannot add traffic.
# Run once per boot as root. Mosquitto must listen on 192.168.150.1:1883.
set -euo pipefail
BRIDGE=${BRIDGE:-br-mqtt}
ip link show "$BRIDGE" >/dev/null 2>&1 || ip link add "$BRIDGE" type bridge
ip address replace 192.168.150.1/24 dev "$BRIDGE"
ip link set "$BRIDGE" up
ip -br address show "$BRIDGE"
