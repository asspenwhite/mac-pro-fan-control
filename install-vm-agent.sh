#!/bin/bash
# Install the GPU temp sender on a Linux guest VM (the one with GPU passthrough).
# Idempotent. Usage: bash install-vm-agent.sh [--user <name>]
set -e
USER_NAME="${2:-$USER}"
HOME_DIR=$(eval echo "~$USER_NAME")
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$HOME_DIR/bin"
# Atomic replace so a running copy keeps its old fd safely
cp "$SRC_DIR/gpu-temp-sender.sh" "$HOME_DIR/bin/gpu-temp-sender.sh.new"
chmod +x "$HOME_DIR/bin/gpu-temp-sender.sh.new"
mv "$HOME_DIR/bin/gpu-temp-sender.sh.new" "$HOME_DIR/bin/gpu-temp-sender.sh"

sudo tee /etc/systemd/system/gpu-temp-sender.service >/dev/null <<EOF
[Unit]
Description=Send GPU temps to Proxmox fan controller
After=multi-user.target
ConditionPathExists=/proc/driver/nvidia/version

[Service]
ExecStart=$HOME_DIR/bin/gpu-temp-sender.sh
User=$USER_NAME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-temp-sender.service
sudo systemctl restart gpu-temp-sender.service
echo "Installed. Verify on the Proxmox host: journalctl -u fan-controller -n 10 (GPU temps should be live, no stale warnings)."
