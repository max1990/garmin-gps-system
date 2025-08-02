#!/bin/bash

LOG_FILE="/var/log/gps_watcher.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if Garmin device is physically connected
garmin_connected() {
    for i in {0..10}; do
        device="/dev/ttyUSB$i"
        if [ -c "$device" ]; then
            device_num=$(basename "$device" | sed 's/ttyUSB//')
            usb_path="/sys/class/tty/ttyUSB${device_num}/device"
            
            if [ -d "$usb_path" ]; then
                current_path="$usb_path"
                for j in {1..5}; do
                    if [ -f "$current_path/idVendor" ] && [ -f "$current_path/idProduct" ]; then
                        vendor_id=$(cat "$current_path/idVendor" 2>/dev/null)
                        product_id=$(cat "$current_path/idProduct" 2>/dev/null)
                        
                        if [ "$vendor_id" = "091e" ] && [ "$product_id" = "0003" ]; then
                            return 0  # Garmin found
                        fi
                        break
                    fi
                    current_path=$(dirname "$current_path")
                    if [ "$current_path" = "/" ]; then
                        break
                    fi
                done
            fi
        fi
    done
    return 1  # No Garmin found
}

# Check if GPS data is flowing
gps_data_flowing() {
    timeout 10 nc -u -l 60000 | head -1 | grep -q '\$GP' 2>/dev/null
}

# Your working reset sequence
reset_gps_system() {
    log "🔄 RESETTING GPS SYSTEM"
    
    sudo systemctl stop gpsd >/dev/null 2>&1
    sudo systemctl stop gpsd.socket >/dev/null 2>&1
    sudo systemctl disable gpsd >/dev/null 2>&1
    sudo systemctl disable gpsd.socket >/dev/null 2>&1
    sudo pkill -f gpsd >/dev/null 2>&1
    sleep 2
    sudo systemctl restart gps-stream.service
    
    log "✅ GPS system reset complete"
}

log "🔍 GPS Watcher started - monitoring for Garmin connection + no data"

while true; do
    if garmin_connected; then
        if ! gps_data_flowing; then
            log "⚠️ Garmin connected but NO GPS data - triggering reset"
            reset_gps_system
            sleep 30  # Wait before checking again
        else
            log "✅ Garmin connected and GPS data flowing"
        fi
    else
        log "ℹ️ No Garmin connected - waiting"
    fi
    
    sleep 15  # Check every 15 seconds
done
