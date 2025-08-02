# Start Garmin GPS Script to fix the startup issues
# Author: Maximilian Leutermann
# Date: 1 August 2025


#!/bin/bash
echo "=== Starting Garmin GPS System ==="
echo "Searching USB0-USB10 for working Garmin..."
echo ""

for i in {0..10}; do
    device="/dev/ttyUSB$i"
    
    if [ -c "$device" ]; then
        echo "Testing $device..."
        
        # Kill any existing GPSD
        sudo pkill -f gpsd >/dev/null 2>&1
        sudo rm -f /var/run/gpsd.sock /tmp/gpsd.sock >/dev/null 2>&1
        sleep 1
        
        # Set permissions and start GPSD
        sudo chmod 666 "$device" 2>/dev/null
        sudo gpsd -n -N -F /tmp/gpsd.sock "$device" >/dev/null 2>&1 &
        GPSD_PID=$!
        sleep 3
        
        # Test for GPS data
        if timeout 5 bash -c "echo '?WATCH={\"enable\":true,\"nmea\":true}' | nc localhost 2947 2>/dev/null | grep -q 'GPGGA\|GPRMC\|Garmin'" 2>/dev/null; then
            echo "✅ SUCCESS: Working Garmin found at $device"
            echo "✅ GPSD started and running with PID $GPSD_PID"
            echo "$device"
            echo ""
            echo "GPS system is now active. Test with:"
            echo "  gpspipe -r"
            echo "  nc -u -l 60000"
            exit 0
        else
            echo "❌ No GPS data from $device"
            sudo kill $GPSD_PID 2>/dev/null
            sudo pkill -f gpsd >/dev/null 2>&1
        fi
    else
        echo "❌ $device does not exist"
    fi
done

echo ""
echo "❌ FAILED: No working Garmin device found on USB0-USB10"
exit 1
