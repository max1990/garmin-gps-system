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

# Function to download with retries - MUST BE DEFINED FIRST
download_with_retry() {
    local url="$1"
    local output="$2"
    local description="$3"
    local retries=3
    
    for i in $(seq 1 $retries); do
        if wget -q --timeout=30 -O "$output" "$url"; then
            log_info "✅ $description"
            return 0
        else
            if [ $i -lt $retries ]; then
                log_warn "Download failed, retrying ($i/$retries)..."
                sleep 2
            fi
        fi
    done
    
    log_error "❌ Failed to download $description after $retries attempts"
    return 1
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

# Fix system clock FIRST - this is critical
log_step "0/9 Fixing system clock (CRITICAL)..."
log_info "Current date: $(date)"

# Force set date to a reasonable time if it's clearly wrong
CURRENT_YEAR=$(date +%Y)
if [ "$CURRENT_YEAR" -gt 2025 ] || [ "$CURRENT_YEAR" -lt 2023 ]; then
    log_warn "System date is clearly wrong (year: $CURRENT_YEAR), forcing reset"
    # Set to a reasonable date in 2024
    date -s "2024-07-30 12:00:00" || log_warn "Could not manually set date"
fi

# Try multiple time sync methods
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true
    log_info "Enabled NTP time sync"
    sleep 3  # Give NTP a moment
fi

if command -v ntpdate >/dev/null 2>&1; then
    # Try multiple NTP servers
    for server in "pool.ntp.org" "time.nist.gov" "time.google.com" "0.pool.ntp.org"; do
        if ntpdate -s "$server" 2>/dev/null; then
            log_info "Time synced with $server"
            break
        fi
    done
fi

log_info "Fixed date: $(date)"

log_step "1/9 Updating system packages..."
# Be more aggressive about fixing repository issues
apt-get clean
apt-get -o Acquire::Check-Valid-Until=false -o Acquire::AllowInsecureRepositories=true update || {
    log_warn "Standard update failed, trying alternative approach..."
    
    # Update just the essential repositories
    echo "deb http://raspbian.raspberrypi.com/raspbian/ bookworm main contrib non-free rpi" > /tmp/sources.list.backup
    echo "deb http://archive.raspberrypi.com/debian/ bookworm main" >> /tmp/sources.list.backup
    
    apt-get -o Acquire::Check-Valid-Until=false -o Dir::Etc::sourcelist=/tmp/sources.list.backup update || log_warn "Alternative update also failed, continuing..."
}

# Try upgrade but don't fail if it doesn't work
apt-get upgrade -y || log_warn "Some packages could not be upgraded, continuing..."

log_step "2/9 Installing required packages..."
# Install packages one by one to avoid dependency issues
ESSENTIAL_PACKAGES="python3-pip python3-dev i2c-tools gpsd gpsd-clients git curl wget"
OPTIONAL_PACKAGES="python3-venv python3-full ntpdate"

# Install essential packages first
for package in $ESSENTIAL_PACKAGES; do
    if apt-get install -y "$package" 2>/dev/null; then
        log_info "✅ Installed $package"
    else
        log_warn "❌ Failed to install $package (may cause issues)"
    fi
done

# Install optional packages (don't fail if they don't work)
for package in $OPTIONAL_PACKAGES; do
    if apt-get install -y "$package" 2>/dev/null; then
        log_info "✅ Installed $package"
    else
        log_warn "⚠️ Skipped $package (optional)"
    fi
done

log_step "3/9 Installing Python dependencies..."
# Try system packages first
log_info "Attempting to install Python packages via apt..."
apt-get install -y python3-systemd python3-smbus python3-serial 2>/dev/null || log_warn "Some system Python packages not available"

# For packages not available via apt, use pip
log_info "Installing remaining Python packages via pip..."
# Use multiple fallback methods for pip installation
if command -v pip3 >/dev/null 2>&1; then
    pip3 install --break-system-packages systemd-python smbus2 2>/dev/null || \
    pip3 install systemd-python smbus2 2>/dev/null || \
    pip3 install --user systemd-python smbus2 2>/dev/null || \
    log_warn "Could not install some Python packages via pip"
else
    log_warn "pip3 not available, Python packages may be missing"
fi

log_step "4/9 Enabling I2C interface..."
raspi-config nonint do_i2c 0 || log_warn "Could not enable I2C via raspi-config"

# Manual I2C enable as backup
if ! grep -q "^dtparam=i2c_arm=on" /boot/config.txt; then
    echo "dtparam=i2c_arm=on" >> /boot/config.txt
    log_info "Manually enabled I2C in /boot/config.txt"
fi

log_step "5/9 Creating directory structure..."
mkdir -p /home/cuas
mkdir -p /var/log
chmod 755 /home/cuas /var/log

log_step "6/9 Downloading and installing system files..."

# Download all files with error handling
download_with_retry "$BASE_URL/garminReader.py" "/home/cuas/garminReader.py" "garminReader.py" || exit 1
download_with_retry "$BASE_URL/system_watchdog.py" "/home/cuas/system_watchdog.py" "system_watchdog.py" || exit 1
download_with_retry "$BASE_URL/gps_startup_cleanup.sh" "/home/cuas/gps_startup_cleanup.sh" "gps_startup_cleanup.sh" || exit 1  # ADDED THIS LINE
download_with_retry "$BASE_URL/run_gps_service.sh" "/home/cuas/run_gps_service.sh" "run_gps_service.sh" || exit 1
download_with_retry "$BASE_URL/start_gps_broadcaster.sh" "/home/cuas/start_gps_broadcaster.sh" "start_gps_broadcaster.sh" || exit 1
download_with_retry "$BASE_URL/calibrate_compass.py" "/home/cuas/calibrate_compass.py" "calibrate_compass.py" || exit 1

# Download systemd service files
download_with_retry "$BASE_URL/gps-stream.service" "/etc/systemd/system/gps-stream.service" "gps-stream.service" || exit 1
download_with_retry "$BASE_URL/gps-system-watchdog.service" "/etc/systemd/system/gps-system-watchdog.service" "gps-system-watchdog.service" || exit 1

# Optional hardware watchdog service
if download_with_retry "$BASE_URL/hardware-watchdog.service" "/etc/systemd/system/hardware-watchdog.service" "hardware-watchdog.service"; then
    log_info "Hardware watchdog service downloaded"
else
    log_warn "Hardware watchdog service not available, skipping"
fi

log_step "7/9 Setting up permissions and services..."

# Set file permissions
chmod +x /home/cuas/*.py /home/cuas/*.sh 2>/dev/null || log_warn "Could not set all file permissions"
chown root:root /home/cuas/* 2>/dev/null || log_warn "Could not set all file ownership"

# Add users to required groups (don't fail if user doesn't exist)
usermod -a -G dialout,i2c,gpio pi 2>/dev/null || log_warn "Could not add 'pi' user to groups (may not exist)"
usermod -a -G dialout,i2c,gpio root 2>/dev/null || log_warn "Could not add 'root' user to groups"

# Create default compass calibration
echo "0.0" > /home/cuas/compass_calibration.txt
echo "0.0" >> /home/cuas/compass_calibration.txt

# Disable conflicting services
systemctl stop gpsd.socket gpsd 2>/dev/null || true
systemctl disable gpsd.socket gpsd 2>/dev/null || true

# Enable new services
systemctl daemon-reload
systemctl enable gps-stream.service || log_warn "Could not enable gps-stream.service"
systemctl enable gps-system-watchdog.service || log_warn "Could not enable gps-system-watchdog.service"

# Enable hardware watchdog if available
if [ -f /etc/systemd/system/hardware-watchdog.service ]; then
    systemctl enable hardware-watchdog.service && log_info "Hardware watchdog enabled"
fi

log_step "8/9 Configuring system optimizations..."

# Download and apply config.txt optimizations
log_info "Applying boot optimizations..."
if download_with_retry "$BASE_URL/config.txt" "/tmp/gps_config.txt" "config.txt optimizations"; then
    # Backup original
    cp /boot/config.txt /boot/config.txt.backup.$(date +%Y%m%d_%H%M%S)
    
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

ALL_GOOD=true
for file in "${CRITICAL_FILES[@]}"; do
    if [ -f "$file" ] && [ -s "$file" ]; then  # File exists and is not empty
        log_info "✅ $file"
    else
        log_error "❌ Missing or empty: $file"
        ALL_GOOD=false
    fi
done

if [ "$ALL_GOOD" = false ]; then
    log_error "Installation verification failed - some critical files are missing"
    log_info "Trying to re-download missing files..."
    
    # Try to re-download missing files
    if [ ! -f "/home/cuas/system_watchdog.py" ] || [ ! -s "/home/cuas/system_watchdog.py" ]; then
        log_info "Re-downloading system_watchdog.py..."
        download_with_retry "$BASE_URL/system_watchdog.py" "/home/cuas/system_watchdog.py" "system_watchdog.py (retry)"
    fi
    
    if [ ! -f "/etc/systemd/system/gps-system-watchdog.service" ] || [ ! -s "/etc/systemd/system/gps-system-watchdog.service" ]; then
        log_info "Re-downloading gps-system-watchdog.service..."
        download_with_retry "$BASE_URL/gps-system-watchdog.service" "/etc/systemd/system/gps-system-watchdog.service" "gps-system-watchdog.service (retry)"
        systemctl daemon-reload
        systemctl enable gps-system-watchdog.service || log_warn "Could not enable gps-system-watchdog.service after retry"
    fi
fi

# Test Python imports
log_info "Testing Python dependencies..."
python3 -c "
try:
    import socket, time, threading, logging, subprocess, os, signal, sys, select
    print('✅ Core Python modules available')
except ImportError as e:
    print(f'❌ Missing core Python module: {e}')
    exit(1)

try:
    import smbus
    print('✅ smbus module available')
except ImportError:
    print('⚠️ smbus module not available (compass may not work)')

try:
    import systemd.daemon
    print('✅ systemd module available')
except ImportError:
    print('⚠️ systemd module not available (watchdog notifications disabled)')
"

# Final file check
log_info "Final verification..."
ALL_GOOD=true
for file in "${CRITICAL_FILES[@]}"; do
    if [ -f "$file" ] && [ -s "$file" ]; then
        log_info "✅ $file"
    else
        log_error "❌ Still missing: $file"
        ALL_GOOD=false
    fi
done

# Success message
echo ""
if [ "$ALL_GOOD" = true ]; then
    echo -e "${GREEN}=============================================================="
    echo "✅ Installation Complete!"
    echo "==============================================================${NC}"
else
    echo -e "${YELLOW}=============================================================="
    echo "⚠️ Installation Mostly Complete (with some warnings)"
    echo "==============================================================${NC}" 
fi
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
echo "🔍 Testing Commands (after reboot):"
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
echo "💡 System is designed to work without hardware connected"
echo "   Connect GPS and compass when ready - system will detect them"
echo ""
echo "🆘 Support: Check the GitHub repository for documentation"
echo ""
log_info "Installation completed!"
log_warn "REBOOT REQUIRED: sudo reboot"
