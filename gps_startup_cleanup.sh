#!/bin/bash

# Enhanced GPS System Startup Cleanup Script with Garmin USB Detection
# This ensures clean startup by removing GPSD conflicts AND finds the Garmin device

# Author: Maximilian J Leutermann
# Date: 30 July 2025




LOG_FILE="/var/log/gps_startup_cleanup.log"
# Device file removed, using environment variable instead
# DEVICE_FILE="/tmp/garmin_device_path"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to find Garmin device by USB vendor/product ID
find_garmin_device() {
    log "=== Garmin Device Detection ==="
    detected_device=""
    
    # Check each ttyUSB device for Garmin vendor/product ID
    for device in /dev/ttyUSB*; do
        if [ -c "$device" ]; then
            log "Checking device: $device"
            
            # Use sysfs method (more reliable than udevadm)
            device_num=$(basename "$device" | sed 's/ttyUSB//')
            usb_path="/sys/class/tty/ttyUSB${device_num}/device"
            
            if [ -d "$usb_path" ]; then
                # Walk up the device tree to find USB info
                current_path="$usb_path"
                vendor_id=""
                product_id=""
                
                for i in {1..5}; do
                    if [ -f "$current_path/idVendor" ] && [ -f "$current_path/idProduct" ]; then
                        vendor_id=$(cat "$current_path/idVendor" 2>/dev/null)
                        product_id=$(cat "$current_path/idProduct" 2>/dev/null)
                        break
                    fi
                    current_path=$(dirname "$current_path")
                    if [ "$current_path" = "/" ]; then
                        break
                    fi
                done
                
                log "Device $device: Vendor=$vendor_id, Product=$product_id"
                
                # Check if this is a Garmin Montana 710 (vendor 091e, product 0003)
                if [ "$vendor_id" = "091e" ] && [ "$product_id" = "0003" ]; then
                    log "✅ Found Garmin Montana 710 at $device"
                    
                    # Set proper permissions
                    chmod 666 "$device" || log "Warning: Could not set permissions on $device"
                    
                    log "Garmin device configured: $device"
                    detected_device="$device"  # Set the GLOBAL variable
                    return 0
                else
                    log "Device $device is not a Garmin Montana 710"
                fi
            else
                log "No USB info found for $device"
            fi
        fi
    done
    
    log "❌ No Garmin device found with vendor ID 091e and product ID 0003"
    
    # No fallback - system MUST have Garmin device
    log "No fallback - system MUST have Garmin device"
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
    
    # Step 2: Find Garmin device
    if ! find_garmin_device; then
        log "❌ CRITICAL: No Garmin device found - GPS will not work"
        log "Please check:"
        log "  1. Garmin Montana 710 is connected via USB"
        log "  2. Device has vendor ID 091e and product ID 0003"
        log "  3. USB cable is working properly"
        exit 1
    fi
    
    # Step 3: Clean up GPSD
    if ! cleanup_gpsd; then
        log "❌ CRITICAL: GPSD cleanup failed"
        exit 1
    fi
    
    # Step 4: Export device path for the main service (SINGLE SOURCE OF TRUTH)
    log "✅ Startup cleanup complete"
    log "✅ Garmin device ready: $detected_device"
    log "✅ GPSD conflicts resolved"
    
    # Write to environment file (ONLY PLACE)
    echo "GARMIN_DEVICE_PATH=$detected_device" > /etc/default/gps-stream
    chmod 644 /etc/default/gps-stream
    
    log "=== GPS System Ready for Startup ==="
    exit 0
}

# Run main function
main "$@"
