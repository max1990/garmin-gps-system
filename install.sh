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
PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "Unknown")
log_info "Detected: $PI_MODEL"

# Get the GitHub repository URL
GITHUB_USER="max1990"
REPO_NAME="garmin-gps-system"
BASE_URL="https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/main"

# Fix system clock first
log_step "0/9 Fixing system clock..."
log_info "Current date: $(date)"
if command -v ntpdate >/dev/null 2>&1; then
    ntpdate -s time.nist.gov 2>/dev/null || log_warn "Could not sync time with ntpdate"
elif command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true
    log_info "Enabled NTP time sync"
else
    log_warn "No time sync available, continuing anyway"
fi
log_info "Updated date: $(date)"

log_step "1/9 Updating system packages..."
# Temporarily allow bad signatures for system updates
apt-get -o Acquire::Check-Valid-Until=false update || log_warn "Some repositories could not be updated"
apt-get upgrade -y || log_warn "Some packages could not be upgraded"

log_step "2/9 Installing required packages..."
apt-get install -y python3-pip python3-dev python3-venv python3-full i2c-tools gpsd gpsd-clients git curl wget ntpdate

log_step "3/9 Installing Python dependencies..."
# Install system packages first (preferred method)
apt-get install -y python3-systemd python3-smbus || log_warn "Some Python packages not available via apt"

# For packages not available via apt, use pip with --break-system-packages
log_info "Installing remaining Python packages..."
pip3 install --break-system-packages systemd-python smbus2 2>/dev/null || log_warn "Some pip packages may not have installed"

log_step "4/9 Enabling I2C interface..."
raspi-config nonint do_i2c 0

log_step "5/9 Creating directory structure..."
mkdir -p /home/cuas
mkdir -p /var/log

log_step "6/9 Downloading and installing system files..."

# Download main Python script
log_info "Installing garminReader.py..."
wget -q -O /home/cuas/garminReader.py "$BASE_URL/garminReader.py" || {
    log_error "Failed to download garminReader.py"
    log_info "Check if file exists at: $BASE_URL/garminReader.py"
    exit 1
}

# Download system watchdog
log_info "Installing system_watchdog.py..."
wget -q -O /home/cuas/system_watchdog.py "$BASE_URL/system_watchdog.py" || {
    log_error "Failed to download system_watchdog.py"
    exit 1
}

# Download startup script
log_info "Installing run_gps_service.sh..."
wget -q -O /home/cuas/run_gps_service.sh "$BASE_URL/run_gps_service.sh" || {
    log_error "Failed to download run_gps_service.sh"
    exit 1
}

# Download legacy script
log_info "Installing start_gps_broadcaster.sh..."
wget -q -O /home/cuas/start_gps_broadcaster.sh "$BASE_URL/start_gps_broadcaster.sh" || {
    log_error "Failed to download start_gps_broadcaster.sh"
    exit 1
}

# Download calibration utility
log_info "Installing calibrate_compass.py..."
wget -q -O /home/cuas/calibrate_compass.py "$BASE_URL/calibrate_compass.py" || {
    log_error "Failed to download calibrate_compass.py"
    exit 1
}

# Download systemd service files
log_info "Installing systemd services..."
wget -q -O /etc/systemd/system/gps-stream.service "$BASE_URL/gps-stream.service" || {
    log_error "Failed to download gps-stream.service"
    exit 1
}

wget -q -O /etc/systemd/system/gps-system-watchdog.service "$BASE_URL/gps-system-watchdog.service" || {
    log_error "Failed to download gps-system-watchdog.service"
    exit 1
}

# Download optional hardware watchdog service
log_info "Installing hardware watchdog service..."
wget -q -O /etc/systemd/system/hardware-watchdog.service "$BASE_URL/hardware-watchdog.service" || {
    log_warn "Hardware watchdog service not available, skipping"
}

log_step "7/9 Setting up permissions and services..."

# Set file permissions
chmod +x /home/cuas/*.py
chmod +x /home/cuas/*.sh
chown root:root /home/cuas/*

# Add users to required groups
usermod -a -G dialout,i2c,gpio pi 2>/dev/null || log_warn "User 'pi' not found"
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

# Enable hardware watchdog if available
if [ -f /etc/systemd/system/hardware-watchdog.service ]; then
    systemctl enable hardware-watchdog.service
    log_info "Hardware watchdog enabled"
fi

log_step "8/9 Configuring system optimizations..."

# Download and apply config.txt optimizations
log_info "Applying boot optimizations..."
if wget -q -O /tmp/gps_config.txt "$BASE_URL/config.txt"; then
    # Backup original
    cp /boot/config.txt /boot/config.txt.backup
    
    # Append GPS optimizations if not already present
    if ! grep -q "# GPS System Optimizations" /boot/config.txt; then
        log_info "Adding GPS system optimizations to /boot/config.txt..."
        echo "" >> /boot/config.txt
        cat /tmp/gps_config.txt >> /boot/config.txt
    else
        log_info "GPS optimizations already present in /boot/config.txt"
    fi
    rm -f /tmp/gps_config.txt
else
    log_warn "Could not download config.txt, applying basic optimizations..."
    if ! grep -q "# GPS System Optimizations" /boot/config.txt; then
        echo "" >> /boot/config.txt
        echo "# GPS System Optimizations" >> /boot/config.txt
        echo "dtparam=i2c_arm=on" >> /boot/config.txt
        echo "dtparam=spi=on" >> /boot/config.txt
        echo "dtparam=watchdog=on" >> /boot/config.txt
        echo "gpu_mem=16" >> /boot/config.txt
        echo "disable_splash=1" >> /boot/config.txt
        echo "boot_delay=0" >> /boot/config.txt
    fi
fi

log_step "9/9 Final verification..."

# Verify critical files exist
log_info "Verifying installation..."
CRITICAL_FILES=(
    "/home/cuas/garminReader.py"
    "/home/cuas/system_watchdog.py"
    "/etc/systemd/system/gps-stream.service"
    "/etc/systemd/system/gps-system-watchdog.service"
)

for file in "${CRITICAL_FILES[@]}"; do
    if [ -f "$file" ]; then
        log_info "✅ $file"
    else
        log_error "❌ Missing: $file"
        exit 1
    fi
done

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
echo "   • Hardware watchdog (if available)"
echo ""
echo "📡 Network Configuration:"
echo "   • Broadcast IP: 192.168.137.255"
echo "   • Broadcast Port: 60000"
echo ""
echo "🚀 Next Steps:"
echo "   1. Connect your GY-271 compass to I2C pins:"
echo "      VCC → 3.3V (Pin 1)"
echo "      GND → Ground (Pin 6)" 
echo "      SCL → GPIO 3 (Pin 5)"
echo "      SDA → GPIO 2 (Pin 3)"
echo "   2. Connect your Garmin Montana 710 via USB"
echo "   3. REBOOT THE SYSTEM: sudo reboot"
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
echo -e "${YELLOW}⚠️  IMPORTANT: REBOOT REQUIRED FOR FULL FUNCTIONALITY${NC}"
echo -e "${YELLOW}   System will reboot automatically on critical failures${NC}"
echo -e "${YELLOW}   This ensures mission-critical operation without intervention${NC}"
echo ""
echo "🆘 Support: Check the GitHub repository for documentation"
echo ""
log_info "Installation completed successfully!"
log_warn "REBOOT REQUIRED: sudo reboot"
