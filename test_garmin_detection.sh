#!/bin/bash

# Test Script for Garmin Montana 710 Detection
# This script tests the automatic device detection functionality
# Author: Maximilian Leutermann

echo "=========================================="
echo "Garmin Montana 710 Detection Test"
echo "=========================================="
echo ""

# Test 1: USB Device Enumeration
echo "Test 1: USB Device Enumeration"
echo "------------------------------"
if command -v lsusb >/dev/null; then
    echo "All USB devices:"
    lsusb
    echo ""
    echo "Garmin devices (looking for vendor 091e):"
    lsusb | grep -i garmin || lsusb | grep "091e" || echo "No Garmin devices found"
else
    echo "lsusb not available"
fi
echo ""

# Test 2: Serial Devices
echo "Test 2: Serial Devices Detection"
echo "--------------------------------"
if ls /dev/ttyUSB* >/dev/null 2>&1; then
    echo "Found USB serial devices:"
    ls -la /dev/ttyUSB*
    echo ""
    
    # Test each device for Garmin characteristics
    for device in /dev/ttyUSB*; do
        if [ -c "$device" ]; then
            echo "Analyzing $device:"
            device_num=$(basename "$device" | sed 's/ttyUSB//')
            usb_path="/sys/class/tty/ttyUSB${device_num}/device"
            
            if [ -d "$usb_path" ]; then
                echo "  USB info path exists: $usb_path"
                
                # Search for vendor/product IDs
                current_path="$usb_path"
                found_ids=false
                
                for level in {1..5}; do
                    vendor_file="$current_path/idVendor"
                    product_file="$current_path/idProduct"
                    
                    if [ -f "$vendor_file" ] && [ -f "$product_file" ]; then
                        vendor_id=$(cat "$vendor_file" 2>/dev/null)
                        product_id=$(cat "$product_file" 2>/dev/null)
                        
                        echo "  Vendor ID: $vendor_id"
                        echo "  Product ID: $product_id"
                        
                        if [ "$vendor_id" = "091e" ] && [ "$product_id" = "0003" ]; then
                            echo "  ✅ GARMIN MONTANA 710 DETECTED!"
                        elif [ "$vendor_id" = "091e" ]; then
                            echo "  ⚠️ Garmin device (different model)"
                        else
                            echo "  ❌ Not a Garmin device"
                        fi
                        
                        found_ids=true
                        break
                    fi
                    
                    current_path=$(dirname "$current_path")
                    if [ "$current_path" = "/" ]; then
                        break
                    fi
                done
                
                if [ "$found_ids" = false ]; then
                    echo "  ❌ Could not find vendor/product IDs"
                fi
            else
                echo "  ❌ No USB info available"
            fi
            echo ""
        fi
    done
else
    echo "❌ No USB serial devices found at /dev/ttyUSB*"
fi
echo ""

# Test 3: Enhanced Detection Script
echo "Test 3: Enhanced Detection Method"
echo "--------------------------------"
DEVICE_FILE="/tmp/test_garmin_device"
rm -f "$DEVICE_FILE"

# Run the same detection logic as the enhanced script
for device in /dev/ttyUSB*; do
    if [ -c "$device" ]; then
        echo "Testing device: $device"
        
        device_num=$(basename "$device" | sed 's/ttyUSB//')
        usb_path="/sys/class/tty/ttyUSB${device_num}/device"
        
        if [ -d "$usb_path" ]; then
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
            done
            
            echo "  Vendor: $vendor_id, Product: $product_id"
            
            if [ "$vendor_id" = "091e" ] && [ "$product_id" = "0003" ]; then
                echo "  ✅ GARMIN MONTANA 710 DETECTED!"
                echo "$device" > "$DEVICE_FILE"
                break
            fi
        fi
    fi
done

if [ -f "$DEVICE_FILE" ]; then
    detected_device=$(cat "$DEVICE_FILE")
    echo ""
    echo "✅ SUCCESS: Garmin Montana 710 detected at $detected_device"
    
    # Test device permissions
    if [ -r "$detected_device" ] && [ -w "$detected_device" ]; then
        echo "✅ Device permissions OK"
    else
        echo "⚠️ Device permissions may need fixing"
        echo "   Try: sudo chmod 666 $detected_device"
    fi
    
    rm -f "$DEVICE_FILE"
else
    echo "❌ FAILED: No Garmin Montana 710 detected"
fi
echo ""

# Test 4: GPSD Status
echo "Test 4: GPSD Status Check"
echo "------------------------"
if pgrep gpsd >/dev/null; then
    echo "⚠️ GPSD processes currently running:"
    ps aux | grep gpsd | grep -v grep
    echo ""
    echo "For fresh installation test, stop GPSD first:"
    echo "  sudo systemctl stop gpsd gpsd.socket"
    echo "  sudo pkill -f gpsd"
else
    echo "✅ No GPSD processes running (good for testing)"
fi
echo ""

# Test 5: Service Files
echo "Test 5: Service Files Check"
echo "---------------------------"
service_files=(
    "/etc/systemd/system/gps-stream.service"
    "/home/cuas/gps_startup_cleanup.sh"
    "/home/cuas/garminReader.py"
)

for file in "${service_files[@]}"; do
    if [ -f "$file" ]; then
        echo "✅ $file exists"
    else
        echo "❌ $file missing"
    fi
done
echo ""

echo "=========================================="
echo "Test Complete"
echo "=========================================="
echo ""
echo "Summary:"
echo "--------"
if ls /dev/ttyUSB* >/dev/null 2>&1; then
    echo "• USB serial devices found"
    
    # Quick final check
    garmin_found=false
    for device in /dev/ttyUSB*; do
        if [ -c "$device" ]; then
            device_num=$(basename "$device" | sed 's/ttyUSB//')
            usb_path="/sys/class/tty/ttyUSB${device_num}/device"
            
            if [ -d "$usb_path" ]; then
                current_path="$usb_path"
                for i in {1..5}; do
                    if [ -f "$current_path/idVendor" ] && [ -f "$current_path/idProduct" ]; then
                        vendor_id=$(cat "$current_path/idVendor" 2>/dev/null)
                        product_id=$(cat "$current_path/idProduct" 2>/dev/null)
                        
                        if [ "$vendor_id" = "091e" ] && [ "$product_id" = "0003" ]; then
                            garmin_found=true
                            echo "• ✅ Garmin Montana 710 READY at $device"
                            break 2
                        fi
                        break
                    fi
                    current_path=$(dirname "$current_path")
                done
            fi
        fi
    done
    
    if [ "$garmin_found" = false ]; then
        echo "• ❌ Garmin Montana 710 NOT FOUND"
        echo "• Expected: Vendor ID 091e, Product ID 0003"
    fi
else
    echo "• ❌ No USB serial devices found"
fi

echo ""
echo "Next Steps:"
echo "----------"
if [ "$garmin_found" = true ]; then
    echo "1. ✅ Hardware detection successful!"
    echo "2. Install/update the enhanced GPS system:"
    echo "   curl -fsSL https://raw.githubusercontent.com/max1990/garmin-gps-system/main/install.sh | sudo bash"
    echo "3. Reboot the system: sudo reboot"
    echo "4. Test the service: sudo systemctl status gps-stream.service"
else
    echo "1. ❌ Connect your Garmin Montana 710 via USB"
    echo "2. Re-run this test: sudo bash test_garmin_detection.sh"
    echo "3. Verify the device appears with vendor ID 091e and product ID 0003"
fi
