#!/bin/bash
# =============================================================================
# Mac Pro Rack Fan Control System - Uninstall Script
# =============================================================================
# Run as root: sudo ./uninstall.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="/opt/fan-control"
CONFIG_DIR="/etc/fan-control"
LOG_DIR="/var/log/fan-control"
SERVICE_NAME="fan-controller"

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Mac Pro Rack Fan Control - Uninstaller${NC}"
echo -e "${GREEN}============================================${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

echo ""
echo -e "${YELLOW}This will remove the fan control system.${NC}"
echo "The following will be deleted:"
echo "  - $INSTALL_DIR"
echo "  - /etc/systemd/system/$SERVICE_NAME.service"
echo ""
read -p "Keep configuration ($CONFIG_DIR)? [Y/n] " -n 1 -r KEEP_CONFIG
echo
read -p "Keep logs ($LOG_DIR)? [Y/n] " -n 1 -r KEEP_LOGS
echo
echo ""
read -p "Proceed with uninstall? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo -e "${GREEN}Stopping service...${NC}"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true

echo -e "${GREEN}Removing files...${NC}"

# Remove service file
rm -f /etc/systemd/system/$SERVICE_NAME.service
echo "  Removed: /etc/systemd/system/$SERVICE_NAME.service"

# Remove install directory
rm -rf "$INSTALL_DIR"
echo "  Removed: $INSTALL_DIR"

# Optionally remove config
if [[ ! $KEEP_CONFIG =~ ^[Yy]$ ]] && [[ -n $KEEP_CONFIG ]]; then
    rm -rf "$CONFIG_DIR"
    echo "  Removed: $CONFIG_DIR"
else
    echo "  Kept: $CONFIG_DIR"
fi

# Optionally remove logs
if [[ ! $KEEP_LOGS =~ ^[Yy]$ ]] && [[ -n $KEEP_LOGS ]]; then
    rm -rf "$LOG_DIR"
    echo "  Removed: $LOG_DIR"
else
    echo "  Kept: $LOG_DIR"
fi

# Reload systemd
systemctl daemon-reload

echo ""
echo -e "${GREEN}Uninstall complete.${NC}"
echo ""
echo -e "${YELLOW}Note: Fans have been left at their last speed.${NC}"
echo "Reboot or manually set fans to restore automatic control."
