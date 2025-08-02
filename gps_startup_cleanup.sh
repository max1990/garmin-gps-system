#!/bin/bash

# Enhanced GPS System Startup Cleanup Script with Garmin USB Detection
# This ensures clean startup by removing GPSD conflicts AND finds the Garmin device
# Author: Maximilian J Leutermann
# Date: 30 July 2025

LOG_FILE="/var/log/gps_startup_cleanup.log"

# GLOBAL VARIABLE - this is key!
detected_device=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to find Garmin device by testing USB0-USB10 - ITERATIVE APPROACH ONLY CHECKS USB0-USB10
find_garmin_device() {
    log "=== Garmin Device Detection ==="
    
    # Try USB devices 0-10
    for i in {0..10}; do
        device="/dev/ttyUSB$i"
        
        if [ -c "$device" ]; then
            log "Testing device: $device"
            
            # Kill any existing GPSD
            pkill -f gpsd >/dev/null 2>&1
            rm -f /var/run/gpsd.sock /tmp/gpsd.sock /var/run/gpsd.pid /tmp/gpsd.pid
            sleep 2
            
            # Set permissions and start GPSD
            chmod 666 "$device"
            gpsd -n -N -F /tmp/gpsd.sock "$device" >/dev/null 2>&1 &
            local gpsd_pid=$!
            sleep 3
            
            # Test if it works
            if timeout 5 bash -c "echo '?WATCH={\"enable\":true,\"nmea\":true}' | nc localhost 2947 2>/dev/null | grep -q 'GPGGA\|GPRMC\|Garmin'" 2>/dev/null; then
                log "✅ Found working Garmin at $device"
                detected_device="$device"
                # Leave GPSD running - don't kill it!
                return 0
            else
                log "❌ No GPS data from $device"
                kill $gpsd_pid 2>/dev/null
                pkill -f gpsd >/dev/null 2>&1
            fi
        else
            log "Device $device does not exist"
        fi
    done
    
    log "❌ No working Garmin device found on USB0-USB10"
    return 1
}

# Enhanced GPSD cleanup with verification
cleanup_gpsd() {
    log "=== Enhanced GPSD Cleanup ==="
    
    # Step 1: Stop systemd services
    log "Stopping systemd GPSD services..."
    systemctl stop gpsd 2>/dev/null || true
    systemctl stop gpsd.socket 2>/dev/null || true
    systemctl disable gpsd 2>/dev/null || true
    systemctl disable gpsd.socket 2>/dev/null || true
    systemctl mask gpsd.socket gpsd 2>/dev/null || true
    
    # Step 2: Kill all GPSD processes (multiple attempts)
    log "Killing GPSD processes..."
    for attempt in {1..3}; do
        if pgrep gpsd >/dev/null; then
            log "Attempt $attempt: Killing remaining GPSD processes"
            pkill -TERM -f gpsd 2>/dev/null || true
            sleep 2
            pkill -KILL -f gpsd 2>/dev/null || true
            sleep 1
        else
            log "No GPSD processes found"
            break
        fi
    done
    
    # Step 3: Remove all GPSD sockets and lock files
    log "Cleaning up GPSD files..."
    for path in "/var/run/gpsd.sock" "/tmp/gpsd.sock" "/var/run/gpsd.pid" "/tmp/gpsd.pid"; do
        if [ -e "$path" ]; then
            rm -f "$path"
            log "Removed: $path"
        fi
    done
    
    # Step 4: Verify cleanup success
    if pgrep gpsd >/dev/null; then
        log "❌ WARNING: GPSD processes still running after cleanup!"
        ps aux | grep gpsd | grep -v grep >> "$LOG_FILE"
        
        # Force kill as last resort
        log "Force killing remaining GPSD processes..."
        pkill -9 -f gpsd 2>/dev/null || true
        sleep 2
    fi
    
    # Final verification
    if pgrep gpsd >/dev/null; then
        log "❌ CRITICAL: Could not clean up GPSD processes!"
        return 1
    else
        log "✅ GPSD cleanup successful"
        return 0
    fi
}

# Wait for USB subsystem to stabilize
wait_for_usb_stable() {
    log "=== USB Subsystem Stabilization ==="
    
    # Wait for udev to settle
    if command -v udevadm >/dev/null; then
        log "Waiting for udev to settle..."
        udevadm settle --timeout=10
    fi
    
    # Wait for USB devices to stabilize
    log "Waiting for USB devices to stabilize..."
    sleep 3
    
    return 0
}

# Main execution
main() {
    log "=== Enhanced GPS System Startup Cleanup ==="
    
    # Step 1: Wait for USB to stabilize
    wait_for_usb_stable
    
    # Step 2: Find Garmin device (this handles all cleanup AND starts working GPSD)
    if ! find_garmin_device; then
        log "❌ CRITICAL: No Garmin device found - GPS will not work"
        exit 1
    fi
    
    # Step 3: Export device path for the main service (SINGLE SOURCE OF TRUTH)
    log "✅ Startup cleanup complete"
    log "✅ Garmin device ready: $detected_device"
    log "✅ GPSD conflicts resolved"
    
    # Write to environment file (ONLY PLACE)
    if [ -n "$detected_device" ]; then
        echo "GARMIN_DEVICE_PATH=$detected_device" > /etc/default/gps-stream
        chmod 644 /etc/default/gps-stream
        log "✅ Environment file written: GARMIN_DEVICE_PATH=$detected_device"
    else
        log "❌ CRITICAL: detected_device is empty!"
        exit 1
    fi
    
    log "=== GPS System Ready for Startup ==="
    exit 0
}

# Run main function
main "$@"
