#!/bin/bash

# Enhanced GPS Service Runner with Self-Healing
# Author: Maximilian Leutermann
# Date: 29 July 2025

set -euo pipefail

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- CONFIG ---
# Read from environment instead of file
DEVICE="${GARMIN_DEVICE_PATH:-/dev/ttyUSB0}"
if [ "$DEVICE" = "/dev/ttyUSB0" ]; then
    log "WARNING: Using fallback device /dev/ttyUSB0 - detection may have failed"
else
    log "Using detected Garmin device: $DEVICE"
fi

GPSD_SOCKET="/var/run/gpsd.sock"
SCRIPT_PATH="/home/cuas/garminReader.py"
LOG_FILE="/var/log/gps_service.log"
MAX_RETRIES=5
RETRY_COUNT=0

# Cleanup function
cleanup() {
    log "Cleaning up processes..."
    pkill gpsd || true
    pkill -f garminReader.py || true
}

# Signal handlers
trap cleanup EXIT
trap 'log "Received SIGTERM, shutting down..."; exit 0' TERM
trap 'log "Received SIGINT, shutting down..."; exit 0' INT

log "Starting GPS service with enhanced monitoring..."

# Pre-flight checks
check_prerequisites() {
    log "Running pre-flight checks..."
    
    # Check if running as root/sudo
    if [ "$EUID" -ne 0 ]; then
        log "ERROR: Must run as root for hardware access"
        exit 1
    fi
    
    # Check I2C availability
    if ! command -v i2cdetect &> /dev/null; then
        log "WARNING: i2c-tools not installed, compass may not work"
    fi
    
    # Check Python dependencies
    if ! python3 -c "import smbus" 2>/dev/null; then
        log "WARNING: smbus not available, compass may not work"
    fi
    
    # Check script exists
    if [ ! -f "$SCRIPT_PATH" ]; then
        log "ERROR: garminReader.py not found at $SCRIPT_PATH"
        exit 1
    fi
    
    log "Pre-flight checks completed"
}

# Wait for USB device with timeout
wait_for_device() {
    local timeout=300  # 5 minutes
    local elapsed=0
    
    log "Waiting for USB device $DEVICE..."
    
    while [ ! -e "$DEVICE" ] && [ $elapsed -lt $timeout ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        
        if [ $((elapsed % 30)) -eq 0 ]; then
            log "Still waiting for $DEVICE... (${elapsed}s elapsed)"
        fi
    done
    
    if [ ! -e "$DEVICE" ]; then
        log "ERROR: Device $DEVICE not found after ${timeout}s"
        return 1
    fi
    
    log "Device $DEVICE detected"
    
    # Additional device validation
    if [ ! -c "$DEVICE" ]; then
        log "ERROR: $DEVICE exists but is not a character device"
        return 1
    fi
    
    # Check device permissions
    if [ ! -r "$DEVICE" ] || [ ! -w "$DEVICE" ]; then
        log "WARNING: Device permissions may be incorrect"
        chmod 666 "$DEVICE" || log "Failed to fix device permissions"
    fi
    
    return 0
}

# Start GPSD with error handling
start_gpsd() {
    log "Starting gpsd..."
    
    # Kill any existing gpsd processes
    cleanup
    sleep 2
    
    # Remove stale socket
    [ -e "$GPSD_SOCKET" ] && rm -f "$GPSD_SOCKET"
    
    # Start gpsd
    if gpsd "$DEVICE" -F "$GPSD_SOCKET" -n; then
        log "gpsd started successfully"
        sleep 3  # Give gpsd time to initialize
        
        # Verify gpsd is running
        if pgrep gpsd > /dev/null; then
            log "gpsd process confirmed running"
            return 0
        else
            log "ERROR: gpsd process not found after start"
            return 1
        fi
    else
        log "ERROR: Failed to start gpsd"
        return 1
    fi
}

# Main service loop with retry logic
main_service_loop() {
    while true; do
        log "Attempting to start service (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
        
        # Check prerequisites
        if ! check_prerequisites; then
            log "Pre-flight checks failed"
            ((RETRY_COUNT++))
        # Wait for device
        elif ! wait_for_device; then
            log "Device wait failed"
            ((RETRY_COUNT++))
        # Start gpsd
        elif ! start_gpsd; then
            log "GPSD start failed"
            ((RETRY_COUNT++))
        else
            # Success - reset retry counter and start main application
            RETRY_COUNT=0
            log "All services started successfully, launching main application..."
            
            # Execute main Python script
            if python3 "$SCRIPT_PATH"; then
                log "Main application exited normally"
                break
            else
                local exit_code=$?
                log "Main application exited with code $exit_code"
                ((RETRY_COUNT++))
            fi
        fi
        
        # Check retry limit
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            log "CRITICAL: Max retries ($MAX_RETRIES) exceeded"
            log "Service will exit and let systemd handle restart"
            exit 1
        fi
        
        # Wait before retry
        local wait_time=$((RETRY_COUNT * 10))
        log "Waiting ${wait_time}s before retry..."
        sleep $wait_time
    done
}

# Start main service
main_service_loop
