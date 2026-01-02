#!/bin/bash
# =============================================================================
# Mac Pro Rack Fan Control System - Installation Script
# =============================================================================
# Run as root: sudo ./install.sh
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

INSTALL_DIR="/opt/fan-control"
CONFIG_DIR="/etc/fan-control"
LOG_DIR="/var/log/fan-control"
SERVICE_NAME="fan-controller"

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Mac Pro Rack Fan Control System Installer${NC}"
echo -e "${GREEN}============================================${NC}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   echo "Usage: sudo $0"
   exit 1
fi

# Check for Mac Pro SMC interface
SMC_PATH="/sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/device:1f/APP0001:00"
if [[ ! -d "$SMC_PATH" ]]; then
    echo -e "${YELLOW}Warning: SMC path not found at $SMC_PATH${NC}"
    echo -e "${YELLOW}Fan control will run in simulation mode.${NC}"
    echo ""
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check Python 3
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 is required but not installed.${NC}"
    echo "Install with: apt install python3"
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo -e "Found Python $PYTHON_VERSION"

# Check for lm-sensors (optional but recommended)
if ! command -v sensors &> /dev/null; then
    echo -e "${YELLOW}Warning: lm-sensors not found. CPU temperature reading may fail.${NC}"
    echo "Install with: apt install lm-sensors"
fi

echo ""
echo -e "${GREEN}Creating directories...${NC}"

# Create installation directory
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"

echo -e "${GREEN}Installing files...${NC}"

# Copy main script
cp fan-controller.py "$INSTALL_DIR/"
chmod 755 "$INSTALL_DIR/fan-controller.py"
echo "  Installed: $INSTALL_DIR/fan-controller.py"

# Copy config if not exists
if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
    cp fan-control.yaml "$CONFIG_DIR/config.yaml"
    echo "  Installed: $CONFIG_DIR/config.yaml"
else
    echo "  Skipped: $CONFIG_DIR/config.yaml (already exists)"
    cp fan-control.yaml "$CONFIG_DIR/config.yaml.new"
    echo "  Installed: $CONFIG_DIR/config.yaml.new (new version for reference)"
fi

# Install systemd service
cp fan-controller.service /etc/systemd/system/
chmod 644 /etc/systemd/system/fan-controller.service
echo "  Installed: /etc/systemd/system/fan-controller.service"

# Set permissions
chown root:root "$INSTALL_DIR/fan-controller.py"
chown root:root "$CONFIG_DIR/config.yaml"
chown root:root /etc/systemd/system/fan-controller.service

# Create log directory with proper permissions
touch "$LOG_DIR/fan-control.log"
chown root:root "$LOG_DIR"
chmod 755 "$LOG_DIR"

echo ""
echo -e "${GREEN}Configuring systemd...${NC}"

# Reload systemd
systemctl daemon-reload

# Enable service
systemctl enable "$SERVICE_NAME"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Files installed:"
echo "  Main script:  $INSTALL_DIR/fan-controller.py"
echo "  Config file:  $CONFIG_DIR/config.yaml"
echo "  Service file: /etc/systemd/system/$SERVICE_NAME.service"
echo "  Log file:     $LOG_DIR/fan-control.log"
echo ""
echo "Commands:"
echo "  Start service:    sudo systemctl start $SERVICE_NAME"
echo "  Stop service:     sudo systemctl stop $SERVICE_NAME"
echo "  View status:      sudo systemctl status $SERVICE_NAME"
echo "  View logs:        sudo journalctl -u $SERVICE_NAME -f"
echo "  Test mode:        sudo python3 $INSTALL_DIR/fan-controller.py --test"
echo ""
echo -e "${YELLOW}Important:${NC}"
echo "  1. Edit $CONFIG_DIR/config.yaml to set your Windows VM IP"
echo "  2. Configure firewall: sudo ufw allow 9999/udp"
echo "  3. Start the service: sudo systemctl start $SERVICE_NAME"
echo ""
echo "On Windows VM:"
echo "  1. Copy gpu-temp-sender.ps1 to the VM"
echo "  2. Edit TargetIP to point to this Linux host"
echo "  3. Run: powershell -ExecutionPolicy Bypass -File gpu-temp-sender.ps1"
echo "  4. Or install as task: powershell -File gpu-temp-sender.ps1 -Install"
echo ""
