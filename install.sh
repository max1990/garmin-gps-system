#!/bin/bash

# Enhanced GPS System Installer with Automatic Garmin Detection
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

# Function to download with retries
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

# Enhanced pre-installation Garmin detection
detect_garmin_devices() {
    log_step "Pre-installation Garmin device detection..."
    
    local found_garmin=false
    
    # Check for any ttyUSB devices
    if ls /dev/ttyUSB* >/dev/null 2>&1; then
        log_info "Found USB serial devices:"
        
        for device in /dev/ttyUSB*; do
            if [ -c "$device" ]; then
                device_num=$(basename "$device" | sed 's/ttyUSB//')
                usb_path="/sys/class/tty/ttyUSB${device_num}/device"
                
                log_info "  Checking $device..."
                
                # Try to find USB vendor/product info
                if [ -d "$usb_path" ]; then
                    # Look for vendor/product IDs
                    current_path="$usb_path"
                    for i in {1..5}; do
                        vendor_file="$current_path/idVendor"
                        product_file="$current_path/idProduct"
                        
                        if [ -f "$vendor_file" ] && [ -f "$product_file" ]; then
                            vendor_id=$(cat "$vendor_file" 2>/dev/null)
                            product_id=$(cat "$product_file" 2>/dev/null)
                            
                            log_info "    Vendor: $vendor_id, Product: $product_id"
                            
                            if [ "$vendor_id" = "091e" ] && [ "$product_id" = "0003" ]; then
                                log_info "    ✅ GARMIN MONTANA 710 DETECTED!"
                                found_garmin=true
                            fi
                            break
                        fi
                        current_path=$(dirname "$current_path")
                    done
                fi
            fi
        done
    else
        log_warn "No USB serial devices found at /dev/ttyUSB*"
    fi
    
    if [ "$found_garmin" = true ]; then
        log_info "✅ Garmin Montana 710 detected - installation will proceed"
        return 0
    else
        log_warn "⚠️ No Garmin Montana 710 detected"
        log_warn "   System will still install but GPS may not work until device is connected"
        log_warn "   Expected: Vendor ID 091e, Product ID 0003"
        return 1
    fi
}

# Banner
echo -e "${BLUE}"
echo "=============================================================="
echo "  🛰️ Enhanced GPS System Installer for Raspberry Pi 🧭"
echo "      with Automatic Garmin Montana 710 Detection"
echo "=============================================================="
echo -e "${NC}"
echo "This installer will set up your GPS system with automatic"
echo "Garmin device detection and robust startup sequencing."
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

# Pre-installation device detection
detect_garmin_devices || true

# Get the GitHub repository URL
GITHUB_USER="max1990"
REPO_NAME="garmin-gps-system"
BASE_URL="https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/main"

# System clock fix
log_step "1/10 Fixing system clock..."
log_info "Current date: $(date)"

CURRENT_YEAR=$(date +%Y)
if [ "$CURRENT_YEAR" -gt 2025 ] || [ "$CURRENT_YEAR" -lt 2023 ]; then
    log_warn "System date appears wrong (year: $CURRENT_YEAR), attempting fix"
    date -s "2024-07-30 12:00:00" || log_warn "Could not manually set date"
fi

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true
    log_info "Enabled NTP time sync"
fi

# Package updates
log_step "2/10 Updating system packages..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq wget gpsd gpsd-clients python3-smbus python3-systemd i2c-tools usbutils

log_info "Essential packages installed"

# Hardware detection and setup
log_step "3/10 Hardware setup and detection..."

# Enable I2C
if ! grep -q "^dtparam=i2c_arm=on" /boot/config.txt; then
    echo "dtparam=i2c_arm=on" >> /boot/config.txt
    log_info "Enabled I2C in /boot/config.txt"
fi

# USB device enumeration
log_info "USB device enumeration:"
if command -v lsusb >/dev/null; then
    lsusb | grep -E "(Garmin|091e)" || log_info "No Garmin devices found in lsusb output"
fi

# Create cuas user if it doesn't exist
if ! id -u cuas >/dev/null 2>&1; then
    log_info "Creating cuas user..."
    useradd -m -s /bin/bash -G dialout,i2c,gpio cuas
    log_info "Created cuas user with required groups"
else
    log_info "User cuas already exists"
    # Ensure cuas has required groups
    usermod -a -G dialout,i2c,gpio cuas 2>/dev/null || true
fi

# Directory structure
log_step "4/10 Creating directory structure..."
mkdir -p /home/cuas /var/log
chmod 755 /home/cuas /var/log

# Download enhanced system files
log_step "5/10 Downloading enhanced system files..."

# Core system files - using the enhanced versions
download_with_retry "$BASE_URL/garminReader.py" "/home/cuas/garminReader.py" "Enhanced garminReader.py" || exit 1
download_with_retry "$BASE_URL/gps_startup_cleanup.sh" "/home/cuas/gps_startup_cleanup.sh" "Enhanced startup cleanup script" || exit 1
download_with_retry "$BASE_URL/system_watchdog.py" "/home/cuas/system_watchdog.py" "system_watchdog.py" || exit 1
download_with_retry "$BASE_URL/calibrate_compass.py" "/home/cuas/calibrate_compass.py" "calibrate_compass.py" || exit 1

# Service files
download_with_retry "$BASE_URL/gps-stream.service" "/etc/systemd/system/gps-stream.service" "Enhanced GPS service" || exit 1
download_with_retry "$BASE_URL/gps-system-watchdog.service" "/etc/systemd/system/gps-system-watchdog.service" "Watchdog service" || exit 1

# Optional files
download_with_retry "$BASE_URL/start_gps_broadcaster.sh" "/home/cuas/start_gps_broadcaster.sh" "Legacy compatibility script" || true

# Permissions and ownership
log_step "6/10 Setting up permissions..."

# Log files
touch /var/log/garmin_reader.log /var/log/system_watchdog.log /var/log/gps_startup_cleanup.log
chmod 666 /var/log/garmin_reader.log /var/log/system_watchdog.log /var/log/gps_startup_cleanup.log
chown root:root /var/log/*.log

# Executable permissions
chmod +x /home/cuas/*.py /home/cuas/*.sh 2>/dev/null || true
chown root:root /home/cuas/* 2>/dev/null || true

# User groups
usermod -a -G dialout,i2c,gpio cuas 2>/dev/null || log_warn "Could not add 'cuas' user to groups"
usermod -a -G dialout,i2c,gpio root 2>/dev/null || log_warn "Could not add 'root' user to groups"

# Compass calibration
echo "0.0" > /home/cuas/compass_calibration.txt
echo "0.0" >> /home/cuas/compass_calibration.txt

# Service configuration
log_step "7/10 Configuring services..."

# Aggressively disable conflicting GPSD services
systemctl stop gpsd.socket gpsd gps-simple.service 2>/dev/null || true
systemctl disable gpsd.socket gpsd gps-simple.service 2>/dev/null || true
systemctl mask gpsd.socket gpsd 2>/dev/null || true

log_info "Conflicting GPSD services disabled and masked"

# Enable new services
systemctl daemon-reload
systemctl enable gps-stream.service || log_warn "Could not enable gps-stream.service"
systemctl enable gps-system-watchdog.service || log_warn "Could not enable gps-system-watchdog.service"

# System optimizations
log_step "8/10 Applying system optimizations..."

# Boot optimizations
if ! grep -q "# Enhanced GPS System Optimizations" /boot/config.txt; then
    log_info "Adding GPS system optimizations to /boot/config.txt..."
    cat >> /boot/config.txt << 'EOF'

# Enhanced GPS System Optimizations
dtparam=i2c_arm=on
dtparam=spi=on
dtparam=watchdog=on
gpu_mem=16
disable_splash=1
boot_delay=0

# USB power management
max_usb_current=1
EOF
else
    log_info "GPS optimizations already present in /boot/config.txt"
fi

# USB device permissions for Garmin
cat > /etc/udev/rules.d/99-garmin-gps.rules << 'EOF'
# Garmin Montana 710 GPS Device
SUBSYSTEM=="tty", ATTRS{idVendor}=="091e", ATTRS{idProduct}=="0003", MODE="0666", GROUP="dialout", SYMLINK+="garmin_gps"
# Generic Garmin devices
SUBSYSTEM=="tty", ATTRS{idVendor}=="091e", MODE="0666", GROUP="dialout"
EOF

log_info "Added udev rules for Garmin devices"

# Reload udev rules
udevadm control --reload-rules
udevadm trigger

# Final verification
log_step "9/10 System verification..."

CRITICAL_FILES=(
    "/home/cuas/garminReader.py"
    "/home/cuas/gps_startup_cleanup.sh"
    "/home/cuas/system_watchdog.py"
    "/etc/systemd/system/gps-stream.service"
    "/etc/systemd/system/gps-system-watchdog.service"
)

ALL_GOOD=true
for file in "${CRITICAL_FILES[@]}"; do
    if [ -f "$file" ] && [ -s "$file" ]; then
        log_info "✅ $file"
    else
        log_error "❌ Missing or empty: $file"
        ALL_GOOD=false
    fi
done

# Test Python dependencies
log_info "Testing Python dependencies..."
python3 -c "
import socket, time, threading, logging, subprocess, os, signal, sys, select, glob
print('✅ Core Python modules available')

try:
    import smbus
    print('✅ smbus module available')
except ImportError:
    print('⚠️ smbus module not available (compass may not work)')

try:
    import systemd.daemon
    print('✅ systemd module available')
except ImportError:
    print('⚠️ systemd module not available (notifications disabled)')
"

# Final hardware check
log_step "10/10 Final hardware verification..."
detect_garmin_devices || true

# Success message
echo ""
if [ "$ALL_GOOD" = true ]; then
    echo -e "${GREEN}=============================================================="
    echo "✅ Enhanced Installation Complete!"
    echo "==============================================================${NC}"
else
    echo -e "${YELLOW}=============================================================="
    echo "⚠️ Installation Complete with Warnings"
    echo "==============================================================${NC}"
fi

echo ""
echo "🚀 Enhanced Features Installed:"
echo "   • Automatic Garmin Montana 710 detection (vendor 091e, product 0003)"
echo "   • Dynamic USB device discovery (/dev/ttyUSB0, /dev/ttyUSB1, etc.)"
echo "   • Robust GPSD startup sequence with conflict resolution"
echo "   • Enhanced recovery from USB disconnections"
echo "   • Mission-critical compass broadcasts (1Hz)"
echo "   • System health monitoring with watchdog"
echo ""
echo "📡 Network Configuration:"
echo "   • Broadcast IP: 192.168.137.255"
echo "   • Broadcast Port: 60000"
echo ""
echo "🔧 Hardware Setup:"
echo "   1. Connect GY-271 compass to I2C pins:"
echo "      VCC → 3.3V (Pin 1), GND → Ground (Pin 6)"
echo "      SCL → GPIO 3 (Pin 5), SDA → GPIO 2 (Pin 3)"
echo "   2. Connect Garmin Montana 710 via USB (any port)"
echo "   3. REBOOT THE SYSTEM: sudo reboot"
echo ""
echo "🔍 Monitoring Commands:"
echo "   • Service status: sudo systemctl status gps-stream.service"
echo "   • Live logs: sudo journalctl -u gps-stream.service -f"
echo "   • Listen to data: nc -u -l 60000"
echo "   • Device detection: cat /tmp/garmin_device_path"
echo ""
echo -e "${YELLOW}⚠️ IMPORTANT: REBOOT REQUIRED FOR FULL FUNCTIONALITY${NC}"
echo "   System will automatically detect and configure Garmin device on startup"
echo ""

log_info "Enhanced installation completed!"
log_warn "REBOOT REQUIRED: sudo reboot"
