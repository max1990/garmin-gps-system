#!/usr/bin/env python3
import smbus
import time
import math

def calibrate_compass():
    bus = smbus.SMBus(1)
    QMC5883L_ADDR = 0x0D
    
    try:
        # Initialize compass
        bus.write_byte_data(QMC5883L_ADDR, 0x09, 0x1D)
        time.sleep(0.01)
        
        print("🧭 Compass Calibration Utility")
        print("=" * 40)
        print("Instructions:")
        print("1. Rotate the compass slowly in all directions")
        print("2. Make complete 360° rotations on all axes") 
        print("3. Continue for the full 30 seconds")
        print("4. Keep the compass level during calibration")
        print("")
        input("Press Enter when ready to start...")
        
        print("🔄 Calibrating... (30 seconds)")
        
        min_x = min_y = float('inf')
        max_x = max_y = float('-inf')
        
        start_time = time.time()
        count = 0
        
        while time.time() - start_time < 30:
            try:
                data = bus.read_i2c_block_data(QMC5883L_ADDR, 0x00, 6)
                
                x = (data[1] << 8) | data[0]
                y = (data[3] << 8) | data[2]
                
                if x > 32767: x -= 65536
                if y > 32767: y -= 65536
                
                min_x = min(min_x, x)
                max_x = max(max_x, x)
                min_y = min(min_y, y)
                max_y = max(max_y, y)
                
                heading = math.degrees(math.atan2(y, x))
                if heading < 0: heading += 360
                
                remaining = 30 - int(time.time() - start_time)
                if count % 5 == 0:  # Print every 5th reading
                    print(f"⏱️  {remaining:2d}s remaining - Heading: {heading:6.1f}° X:{x:6d} Y:{y:6d}")
                
                count += 1
                time.sleep(0.2)
                
            except Exception as e:
                print(f"❌ Error reading compass: {e}")
                time.sleep(0.1)
        
        # Calculate calibration offsets
        offset_x = (max_x + min_x) / 2
        offset_y = (max_y + min_y) / 2
        
        print("\n✅ Calibration Complete!")
        print("=" * 40)
        print(f"📊 Results:")
        print(f"   X Range: {min_x} to {max_x}")
        print(f"   Y Range: {min_y} to {max_y}")
        print(f"   X Offset: {offset_x:.1f}")
        print(f"   Y Offset: {offset_y:.1f}")
        
        # Save calibration
        with open('/home/cuas/compass_calibration.txt', 'w') as f:
            f.write(f"{offset_x:.1f}\n")
            f.write(f"{offset_y:.1f}\n")
        
        print(f"\n💾 Calibration saved to /home/cuas/compass_calibration.txt")
        print("🔄 Restart the GPS service to use new calibration:")
        print("   sudo systemctl restart gps-stream.service")
        
    except ImportError:
        print("❌ Error: smbus module not found")
        print("   Install with: sudo apt install python3-smbus")
    except Exception as e:
        print(f"❌ Calibration failed: {e}")
        print("   Check I2C connection and compass wiring")

if __name__ == "__main__":
    import os
    if os.geteuid() != 0:
        print("❌ Please run as root: sudo python3 calibrate_compass.py")
        exit(1)
    
    calibrate_compass()
