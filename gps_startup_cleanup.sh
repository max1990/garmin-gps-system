#!/bin/bash

# GPS System Startup Cleanup Script
# This ensures clean startup by removing GPSD conflicts
# Author: Maximilian Leutermann
# Date: 30 July 2025

LOG_FILE="/var/log/gps_startup_cleanup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== GPS System Startup Cleanup ==="

# Stop and disable system GPSD services
log "Stopping system GPSD services..."

systemctl stop gpsd 2>/dev/null || true
systemctl stop gpsd.socket 2>/dev/null || true
systemctl disable gpsd 2>/dev/null || true
systemctl disable gpsd.socket 2>/dev/null || true

log "System GPSD services stopped/disabled"

# Kill any remaining GPSD processes
log "Killing remaining GPSD processes..."
pkill -f gpsd 2>/dev/null || true

# Wait for processes to die
sleep 2

# Remove stale socket
SOCKET_PATH="/var/run/gpsd.sock"
if [ -e "$SOCKET_PATH" ]; then
    rm -f "$SOCKET_PATH"
    log "Removed stale GPSD socket"
fi

# Verify no GPSD processes are running
if pgrep gpsd >/dev/null; then
    log "WARNING: GPSD processes still running after cleanup"
    ps aux | grep gpsd >> "$LOG_FILE"
else
    log "SUCCESS: All GPSD processes cleaned up"
fi

log "=== GPS System Startup Cleanup Complete ==="

exit 0
