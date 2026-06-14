#!/bin/bash
# GPU temp + fan-speed sender for the Mac Pro fan-control system (Linux guest).
# Runs inside the VM that owns the passthrough GPUs; the Proxmox host can't
# see GPU temps once the cards are passed through, so this reports them.
#
# Sends a flat JSON payload via UDP to the host fan-controller:
#   {"gpu0_temp":65,"gpu0_fan":40,"gpu1_temp":67,"gpu1_fan":42}
#
# Config via environment (systemd unit or shell):
#   FAN_HOST     controller address (default 192.0.2.20 — your fan controller host)
#   FAN_PORT     UDP port            (default 9999)
#   INTERVAL     seconds between sends (default 2)
#
# Windows-guest equivalent: gpu-temp-sender.ps1 (legacy).
FAN_HOST="${FAN_HOST:-192.0.2.20}"
FAN_PORT="${FAN_PORT:-9999}"
INTERVAL="${INTERVAL:-2}"

while true; do
  DATA=$(nvidia-smi --query-gpu=temperature.gpu,fan.speed --format=csv,noheader,nounits 2>/dev/null)
  if [ -n "$DATA" ]; then
    t0=$(echo "$DATA" | sed -n '1p' | cut -d',' -f1 | tr -d ' ')
    f0=$(echo "$DATA" | sed -n '1p' | cut -d',' -f2 | tr -d ' ')
    t1=$(echo "$DATA" | sed -n '2p' | cut -d',' -f1 | tr -d ' ')
    f1=$(echo "$DATA" | sed -n '2p' | cut -d',' -f2 | tr -d ' ')
    printf '{"gpu0_temp":%s,"gpu0_fan":%s,"gpu1_temp":%s,"gpu1_fan":%s}' \
      "${t0:-0}" "${f0:-0}" "${t1:-0}" "${f1:-0}" | \
      nc -u -w1 "$FAN_HOST" "$FAN_PORT" 2>/dev/null
  fi
  sleep "$INTERVAL"
done
