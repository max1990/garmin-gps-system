#!/bin/bash

# GPS System Easy Installer for Raspberry Pi
# Author: Maximilian Leutermann
# Usage: curl -fsSL https://raw.githubusercontent.com/max1990/garmin-gps-system/main/install.sh | sudo bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Banner
echo -e "${BLUE}"
echo "=============================================================="
echo "    🛰️  GPS System Installer for Raspberry Pi 🧭"
echo "=============================================================="
echo -e "${NC}"
echo "This installer will set up your mission-critical GPS and"
echo "compass broadcasting system with automatic recovery."
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run with sudo:"
    echo "curl -fsSL https://raw.githubusercontent.com/max1990/garmin-gps-system/main/install.sh | sudo bash"
    exit 1
fi

# Detect Pi model
PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "Unknown")
log_info "Detected: $PI_MODEL"

# Get the GitHub repository URL
GITHUB_USER="max1990"
REPO_NAME="garmin-gps-system"
BASE_URL="https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/main"

log_step "1/8 Updating system packages..."
apt update && apt upgrade -y

log_step "2/8 Installing required packages..."
apt install -y python3-pip python3-dev i2c-tools gpsd gpsd-clients git curl wget

log_step "3/8 Installing Python dependencies..."
pip3 install systemd-python smbus2

log_step "4/8 Enabling I2C interface..."
raspi-config nonint do_i2c 0

log_step "5/8 Creating directory structure..."
mkdir -p /home/cuas
mkdir -p /var/log

log_step "6/8 Downloading and installing system files..."

# Download main Python script
log_info "Installing garminReader.py..."
wget -q -O /home/cuas/garminReader.py "$BASE_URL/garminReader.py"

# Download system watchdog
log_info "Installing system_watchdog.py..."
wget -q -O /home/cuas/system_watchdog.py "$BASE_URL/system_watchdog.py"

# Download startup script
log_info "Installing run_gps_service.sh..."
wget -q -O /home/cuas/run_gps_service.sh "$BASE_URL/run_gps_service.sh"

# Download legacy script
log_info "Installing start_gps_broadcaster.sh..."
wget -q -O /home/cuas/start_gps_broadcaster.sh "$BASE_URL/start_gps_broadcaster.sh"

# Download calibration utility
log_info "Installing calibrate_compass.py..."
wget -q -O /home/cuas/calibrate_compass.py "$BASE_URL/calibrate_compass.py"

# Download systemd service files
log_info "Installing systemd services..."
wget -q -O /etc/systemd/system/gps-stream.service "$BASE_URL/gps-stream.service"
wget -q -O /etc/systemd/system/gps-system-watchdog.service "$BASE_URL/gps-system-watchdog.service"

log_step "7/8 Setting up permissions and services..."

# Set file permissions
chmod +x /home/cuas/*.py
chmod +x /home/cuas/*.sh
chown root:root /home/cuas/*

# Add users to required groups
usermod -a -G dialout,i2c,gpio pi || log_warn "User 'pi' not found"
usermod -a -G dialout,i2c,gpio root

# Create default compass calibration
echo "0.0" > /home/cuas/compass_calibration.txt
echo "0.0" >> /home/cuas/compass_calibration.txt

# Disable conflicting services
systemctl stop gpsd.socket gpsd 2>/dev/null || true
systemctl disable gpsd.socket gpsd 2>/dev/null || true

# Enable new services
systemctl daemon-reload
systemctl enable gps-stream.service
systemctl enable gps-system-watchdog.service

log_step "8/8 Final configuration..."

# Add boot optimization
if ! grep -q "# GPS System Optimizations" /boot/config.txt; then
    log_info "Adding boot optimizations..."
    echo "" >> /boot/config.txt
    echo "# GPS System Optimizations" >> /boot/config.txt
    echo "gpu_mem=16" >> /boot/config.txt
    echo "disable_splash=1" >> /boot/config.txt
    echo "boot_delay=0" >> /boot/config.txt
fi

# Success message
echo ""
echo -e "${GREEN}=============================================================="
echo "✅ Installation Complete!"
echo "==============================================================${NC}"
echo ""
echo "🔧 What was installed:"
echo "   • GPS broadcasting system with compass integration"
echo "   • Automatic USB disconnect recovery"
echo "   • System watchdog with auto-restart capability"
echo "   • Mission-critical compass broadcasts (1Hz)"
echo "   • Heartbeat monitoring (10s intervals)"
echo ""
echo "📡 Network Configuration:"
echo "   • Broadcast IP: 192.168.137.255"
echo "   • Broadcast Port: 60000"
echo ""
echo "🚀 Next Steps:"
echo "   1. Connect your GY-271 compass to I2C pins"
echo "   2. Connect your Garmin Montana 710 via USB"
echo "   3. Reboot the system: sudo reboot"
echo "   4. Services will start automatically on boot"
echo ""
echo "🔍 Testing Commands:"
echo "   • Check status: sudo systemctl status gps-stream.service"
echo "   • View logs: sudo journalctl -u gps-stream.service -f"
echo "   • Listen to broadcasts: nc -u -l 60000"
echo "   • Calibrate compass: sudo python3 /home/cuas/calibrate_compass.py"
echo ""
echo "📋 Log Files:"
echo "   • Main system: /var/log/garmin_reader.log"
echo "   • Watchdog: /var/log/system_watchdog.log"
echo "   • Service: sudo journalctl -u gps-stream.service"
echo ""
echo -e "${YELLOW}⚠️  System will reboot automatically on critical failures${NC}"
echo -e "${YELLOW}   This ensures mission-critical operation without intervention${NC}"
echo ""
echo "🆘 Support: Check the GitHub repository for documentation"
echo ""
log_info "Reboot recommended to complete installation"
