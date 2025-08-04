"""

garminReader: UDP rebroadcaster for Garmin NMEA Data with Compass Integration
Enhanced with automatic Garmin device detection and robust GPSD management

Author:		Maximilian Leutermann
Date:		30 July 2025

"""

import socket
import time
import threading
import logging
import subprocess
import os
import signal
import sys
from queue import Queue, Empty
import select
import glob

# For systemd watchdog notifications
try:
    import systemd.daemon
    SYSTEMD_AVAILABLE = True
except ImportError:
    SYSTEMD_AVAILABLE = False
    print("Warning: systemd python module not available, watchdog notifications disabled")

# === CONFIGURATION ===
BROADCAST_IP = "192.168.137.255"
BROADCAST_PORT = 60000
HEARTBEAT_INTERVAL = 10
HEADING_INTERVAL = 1
GPSD_HOST = "localhost"
GPSD_PORT = 2947
DEVICE_CHECK_INTERVAL = 5
WATCHDOG_INTERVAL = 30

# Garmin device identification
GARMIN_VENDOR_ID = "091e"
GARMIN_PRODUCT_ID = "0003"

# Compass I2C configuration
I2C_BUS = 1
QMC5883L_ADDR = 0x0D

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('/var/log/garmin_reader.log')
    ]
)
logger = logging.getLogger(__name__)

class GarminDeviceDetector:
    """Handles automatic detection of Garmin Montana 710 devices"""
    
    def __init__(self):
        self.detected_device = None
        self.last_detection_time = 0
        # Check environment variable first (from EnvironmentFile)
        self.env_device_path = os.environ.get('GARMIN_DEVICE_PATH', None)

    def wait_for_device_ready(self, device_path, timeout=30):
        """Wait for device to be actually ready for communication"""
        for i in range(timeout):
            if os.path.exists(device_path) and os.access(device_path, os.R_OK | os.W_OK):
                return True
            time.sleep(1)
        return False
    
    def find_garmin_device(self):
        """Get Garmin device path from environment (set by startup script)"""
        # ONLY check environment variable - no fallback detection
        if self.env_device_path:
            if os.path.exists(self.env_device_path):
                logger.info(f"✅ Using Garmin device: {self.env_device_path}")
                self.detected_device = self.env_device_path
                self.last_detection_time = time.time()
                return self.env_device_path
            else:
                logger.error(f"❌ Environment device {self.env_device_path} does not exist")
                return None
        else:
            logger.error("❌ GARMIN_DEVICE_PATH not set in environment")
            return None
    
    def _is_garmin_device(self, device_path):
        """Check if device is a Garmin by vendor/product ID"""
        try:
            # Extract device number (e.g., ttyUSB0 -> 0)
            device_num = os.path.basename(device_path).replace("ttyUSB", "")
            
            # Path to USB device info
            usb_base_path = f"/sys/class/tty/ttyUSB{device_num}/device"
            
            if not os.path.exists(usb_base_path):
                return False
            
            # Traverse up the USB hierarchy to find vendor/product IDs
            current_path = usb_base_path
            for _ in range(5):  # Max 5 levels up
                vendor_file = os.path.join(current_path, "idVendor")
                product_file = os.path.join(current_path, "idProduct")
                
                if os.path.exists(vendor_file) and os.path.exists(product_file):
                    try:
                        with open(vendor_file, 'r') as f:
                            vendor_id = f.read().strip()
                        with open(product_file, 'r') as f:
                            product_id = f.read().strip()
                        
                        logger.debug(f"Device {device_path}: Vendor={vendor_id}, Product={product_id}")
                        
                        # Check if this is our Garmin device
                        if vendor_id == GARMIN_VENDOR_ID and product_id == GARMIN_PRODUCT_ID:
                            return True
                    except Exception as e:
                        logger.debug(f"Error reading USB IDs for {device_path}: {e}")
                        break
                
                # Move up one level in the directory tree
                parent_path = os.path.dirname(current_path)
                if parent_path == current_path:  # Reached root
                    break
                current_path = parent_path
            
            return False
            
        except Exception as e:
            logger.debug(f"Error checking device {device_path}: {e}")
            return False
    
    def get_device_path(self):
        """Get current detected device path"""
        # Only re-read environment if we don't have a device
        if not self.detected_device:
            self.find_garmin_device()
        
        return self.detected_device

class CompassReader:

    def read_heading(self):
        """ Independent compass reader for heading data """
        PIPE_PATH = "/tmp/heading_pipe"

        if not os.path.exists(PIPE_PATH):
            print(f"❌ FIFO not found: {PIPE_PATH}")
            exit(1)

        print(f"✅ Reading heading from {PIPE_PATH}...\n(Press Ctrl+C to stop)\n")

        try:
            with open(PIPE_PATH, "r") as pipe:
                while True:
                    line = pipe.readline().strip()
                    if line:
                        return line
        except Exception as e:
            logger.warning(f"Compass read error: {e}")

    """
    def __init__(self):
        self.heading = 0.0
        self.last_valid_heading = 0.0
        self.compass_active = False
        self.lock = threading.Lock()
        self.calibration_offset_x = 0.0
        self.calibration_offset_y = 0.0
        
    def load_calibration(self):
        # Load compass calibration from file
        try:
            with open('/home/cuas/compass_calibration.txt', 'r') as f:
                lines = f.readlines()
                self.calibration_offset_x = float(lines[0].strip())
                self.calibration_offset_y = float(lines[1].strip())
                logger.info(f"Loaded compass calibration: X={self.calibration_offset_x}, Y={self.calibration_offset_y}")
        except Exception as e:
            logger.warning(f"Could not load compass calibration: {e}, using defaults")
    
    def initialize(self):
        # Initialize compass with error handling
        try:
            import smbus
            self.bus = smbus.SMBus(I2C_BUS)
            
            # Initialize QMC5883L
            self.bus.write_byte_data(QMC5883L_ADDR, 0x0B, 0x01)  # SET/RESET
            time.sleep(0.1)
            self.bus.write_byte_data(QMC5883L_ADDR, 0x09, 0x1D)  # Control register
            
            self.load_calibration()
            self.compass_active = True
            logger.info("✅ Compass initialized successfully")
            return True
            
        except ImportError:
            logger.warning("smbus not available, compass disabled")
            return False
        except Exception as e:
            logger.warning(f"Compass initialization failed: {e}")
            return False
    
    def read_heading(self):
        # Read compass heading with error handling
        if not self.compass_active:
            with self.lock:
                return self.last_valid_heading
        
        try:
            # Read raw magnetometer data
            data = self.bus.read_i2c_block_data(QMC5883L_ADDR, 0x00, 6)
            
            # Convert to signed 16-bit values
            x = (data[1] << 8) | data[0]
            y = (data[3] << 8) | data[2]
            
            if x > 32767:
                x -= 65536
            if y > 32767:
                y -= 65536
            
            # Apply calibration
            x_cal = x - self.calibration_offset_x
            y_cal = y - self.calibration_offset_y
            
            # Calculate heading
            import math
            heading_rad = math.atan2(y_cal, x_cal)
            heading_deg = (math.degrees(heading_rad) + 360) % 360
            
            with self.lock:
                self.heading = heading_deg
                self.last_valid_heading = heading_deg
                
            return heading_deg
            
        except Exception as e:
            logger.warning(f"Compass read error: {e}")
            with self.lock:
                return self.last_valid_heading
    
    
    def get_heading(self):
        with self.lock:
            return self.heading

    """

class EnhancedGPSDManager:
    """Enhanced GPSD manager with automatic Garmin device detection"""
    
    def __init__(self):
        self.device_detector = GarminDeviceDetector()
        self.device_present = False
        self.current_device_path = None
        
    def get_device_path(self):
        """Get current Garmin device path"""
        return self.device_detector.get_device_path()
    
    def check_device(self):
        """Check if Garmin GPS device is present"""
        device_path = self.get_device_path()
        present = device_path is not None and os.path.exists(device_path)
        
        if present != self.device_present:
            if present:
                logger.info(f"✅ Garmin GPS device {device_path} connected")
                self.current_device_path = device_path
            else:
                logger.warning(f"❌ Garmin GPS device disconnected")
                self.current_device_path = None
                
        self.device_present = present
        return present

    def restart_gpsd_with_device(self):
        """
        Restart GPSD with the detected Garmin device using proven method
        """
        try:
            device_path = self.get_device_path()
            if not device_path:
                logger.error("Cannot start GPSD: No Garmin device detected")
                return False
            
            logger.info(f"Starting GPSD restart sequence for device: {device_path}")
            
            # Step 1: Clean shutdown (like the working manual fix)
            logger.info("Stopping all GPSD processes...")
            subprocess.run(['sudo', 'pkill', '-f', 'gpsd'], check=False)
            time.sleep(2)
            
            # Step 2: Clean up sockets
            logger.info("Cleaning up sockets...")
            for socket_path in ['/var/run/gpsd.sock', '/tmp/gpsd.sock']:
                try:
                    if os.path.exists(socket_path):
                        os.remove(socket_path)
                        logger.debug(f"Removed socket: {socket_path}")
                except Exception as e:
                    logger.debug(f"Could not remove {socket_path}: {e}")
            
            # Step 3: Verify device exists and set permissions
            if not os.path.exists(device_path):
                logger.error(f"Device {device_path} not found")
                return False
            
            # Step 3a: Wait for device to be actually ready
            if not self.device_detector.wait_for_device_ready(device_path, timeout=15):
                logger.error(f"Device {device_path} exists but is not ready for communication")
                return False
            
            subprocess.run(['sudo', 'chmod', '666', device_path], check=False)
            logger.debug(f"Set permissions for {device_path}")
            
            # Step 4: Start GPSD (exact command that works)
            logger.info("Starting GPSD...")
            cmd = ['sudo', 'gpsd', '-b', '-n', '-N', '-F', '/tmp/gpsd.sock', device_path]
            
            # Start GPSD process
            process = subprocess.Popen(cmd, 
                                     stdout=subprocess.PIPE, 
                                     stderr=subprocess.PIPE)
            
            # Give GPSD time to start (critical timing)
            time.sleep(5)
            
            # Step 5: Verify GPSD is working
            if self.test_gpsd_connection():
                logger.info("✅ GPSD started successfully and responding")
                return True
            else:
                logger.error("❌ GPSD started but not responding properly")
                # Clean up failed attempt
                subprocess.run(['sudo', 'pkill', '-f', 'gpsd'], check=False)
                return False
                
        except Exception as e:
            logger.error(f"GPSD restart failed: {e}")
            return False

    def test_gpsd_connection(self):
        """Test GPSD connection and response"""
        try:
            # Connect to GPSD
            sock = socket.create_connection((GPSD_HOST, GPSD_PORT), timeout=10)
            sock.sendall(b'?WATCH={"enable":true,"nmea":true,"raw":1}\n')
            sock.settimeout(3.0)
            
            # Try to read response data
            buffer = ""
            for _ in range(10):  # Short test loop
                try:
                    data = sock.recv(4096).decode('utf-8', errors='ignore')
                    buffer += data
                    
                    # Look for NMEA data or JSON response from GPSD
                    if '$' in buffer or '"class":"VERSION"' in buffer:
                        sock.close()
                        logger.debug("GPSD connection test successful")
                        return True
                        
                except socket.timeout:
                    pass
                time.sleep(0.1)
            
            sock.close()
            logger.debug("GPSD connection test failed - no valid response")
            return False
            
        except Exception as e:
            logger.debug(f"GPSD connection test failed: {e}")
            return False

class SystemHealth:
    """System health monitoring and watchdog notifications"""
    
    def __init__(self):
        self.last_heartbeat_sent = 0
        self.last_compass_sent = 0
        self.last_gps_data = 0
        self.system_healthy = True
        
    def update_heartbeat(self):
        self.last_heartbeat_sent = time.time()
        
    def update_compass(self):
        self.last_compass_sent = time.time()
        
    def update_gps(self):
        self.last_gps_data = time.time()
        
    def is_healthy(self):
        now = time.time()
        
        compass_age = now - self.last_compass_sent
        if compass_age > 30:
            logger.warning(f"Compass not working for {compass_age:.0f}s")
            self.system_healthy = False
            return False
            
        heartbeat_age = now - self.last_heartbeat_sent
        if heartbeat_age > 60:
            logger.warning(f"No heartbeat for {heartbeat_age:.0f}s")
            self.system_healthy = False
            return False
        
        self.system_healthy = True
        return True
    
    def send_watchdog_notification(self):
        if SYSTEMD_AVAILABLE and self.is_healthy():
            try:
                systemd.daemon.notify('WATCHDOG=1')
                logger.debug("Watchdog notification sent")
            except Exception as e:
                logger.warning(f"Failed to send watchdog notification: {e}")

class GarminReader:
    """Main class handling GPSD connection and UDP broadcasting"""
    
    def __init__(self):
        self.compass = CompassReader()
        self.gpsd_manager = EnhancedGPSDManager()
        self.health = SystemHealth()
        self.running = True
        self.gpsd_connected = False
        self.udp_sock = None
        self.setup_udp_socket()
        
        # Initialize system on startup
        self.initialize_system()

    def initialize_system(self):
        """Initialize all system components"""
        logger.info("=== Garmin GPS System Initialization ===")
        
        # Wait a moment for startup script to complete
        time.sleep(2)
        
        # Initialize compass
        self.compass.initialize()
        
        # Find Garmin device
        device_path = self.gpsd_manager.get_device_path()
        if device_path:
            logger.info(f"✅ Garmin device detected: {device_path}")
            
            # Verify device is actually ready for use
            if self.gpsd_manager.device_detector.wait_for_device_ready(device_path, timeout=10):
                logger.info(f"✅ Garmin device ready for communication: {device_path}")
            else:
                logger.warning(f"⚠️ Garmin device detected but not ready: {device_path}")
        else:
            logger.error("❌ No Garmin device found - GPS functionality disabled")
        
        logger.info("=== System Initialization Complete ===")

    def setup_udp_socket(self):
        """Setup UDP broadcast socket"""
        try:
            self.udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            self.udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            logger.info(f"✅ UDP broadcast configured: {BROADCAST_IP}:{BROADCAST_PORT}")
        except Exception as e:
            logger.error(f"Failed to setup UDP socket: {e}")
    
    def broadcast_message(self, message):
        """Broadcast message via UDP"""
        if self.udp_sock:
            try:
                self.udp_sock.sendto(message.encode(), (BROADCAST_IP, BROADCAST_PORT))
            except Exception as e:
                logger.debug(f"UDP broadcast failed: {e}")
    
    def calculate_nmea_checksum(self, sentence):
        """Calculate NMEA checksum"""
        checksum = 0
        for char in sentence:
            checksum ^= ord(char)
        return f"{checksum:02X}"
    
    def heartbeat_loop(self):
        """Send periodic heartbeat messages"""
        while self.running:
            try:
                timestamp = time.strftime("%H%M%S", time.gmtime())
                device_status = "OK" if self.gpsd_manager.device_present else "NO_GPS"
                compass_status = "OK" if self.compass.compass_active else "NO_COMPASS"
                
                heartbeat = f"PIHBX,HEARTBEAT,{timestamp},{device_status},{compass_status}"
                checksum = self.calculate_nmea_checksum(heartbeat)
                message = f"${heartbeat}*{checksum}"
                
                self.broadcast_message(message)
                self.health.update_heartbeat()
                
                logger.debug(f"Heartbeat: {message}")
                time.sleep(HEARTBEAT_INTERVAL)
                
            except Exception as e:
                logger.error(f"Heartbeat error: {e}")
                time.sleep(HEARTBEAT_INTERVAL)
    
    def compass_loop(self):
        """Send periodic compass heading messages"""
        while self.running:
            try:
                heading = self.compass.read_heading()
                timestamp = time.strftime("%H%M%S", time.gmtime())
                
                # Create custom compass NMEA sentence -- FIX THIS, IT NEEDS TO BE STANDARD NMEA FORMAT
                compass_data = f"HCHDG,{timestamp},{heading:.1f}"
                checksum = self.calculate_nmea_checksum(compass_data)
                message = f"${compass_data}*{checksum}"
                
                self.broadcast_message(message)
                self.health.update_compass()
                
                logger.debug(f"Compass: {message}")
                time.sleep(HEADING_INTERVAL)
                
            except Exception as e:
                logger.error(f"Compass error: {e}")
                time.sleep(HEADING_INTERVAL)
    
    def device_monitor_loop(self):
        """Enhanced device monitoring with automatic recovery"""
        consecutive_failures = 0
        max_failures = 3
        
        while self.running:
            try:
                device_present = self.gpsd_manager.check_device()
                
                # Device disconnected
                if not device_present and self.gpsd_manager.device_present:
                    logger.warning("GPS device disconnected, starting recovery...")
                    self.gpsd_connected = False
                    consecutive_failures += 1
                    
                    if consecutive_failures >= max_failures:
                        logger.error(f"Device failed {consecutive_failures} times, running device discovery")
                        try:
                            subprocess.run(['/home/cuas/gps_startup_cleanup.sh'], check=True, timeout=120)
                            consecutive_failures = 0
                            logger.info("Device discovery and startup completed")
                        except Exception as e:
                            logger.error(f"Device discovery failed: {e}")
                
                # Device reconnected
                elif device_present and not self.gpsd_manager.device_present:
                    logger.info("GPS device reconnected! Starting recovery...")
                    try:
                        subprocess.run(['/home/cuas/gps_startup_cleanup.sh'], check=True, timeout=120)
                        consecutive_failures = 0
                        logger.info("Device reconnection recovery completed")
                    except Exception as e:
                        logger.error(f"Device reconnection recovery failed: {e}")
                        consecutive_failures += 1
                
                # Device stable
                elif device_present and self.gpsd_manager.device_present:
                    if consecutive_failures > 0:
                        consecutive_failures = 0
                        logger.info("Device stabilized, reset failure counter")
                
                time.sleep(DEVICE_CHECK_INTERVAL)
                
            except Exception as e:
                logger.error(f"Device monitor error: {e}")
                time.sleep(DEVICE_CHECK_INTERVAL)
    
    def connect_to_gpsd(self):
        """Connect to gpsd with timeout and error handling"""
        try:
            logger.info("Connecting to gpsd...")
            gpsd_sock = socket.create_connection((GPSD_HOST, GPSD_PORT), timeout=10)
            gpsd_sock.sendall(b'?WATCH={"enable":true,"nmea":true,"raw":1}\n')
            gpsd_sock.settimeout(1.0)
            
            self.gpsd_connected = True
            logger.info("Connected to gpsd successfully")
            return gpsd_sock
            
        except Exception as e:
            logger.error(f"Failed to connect to gpsd: {e}")
            self.gpsd_connected = False
            return None
    
    def gpsd_loop(self):
        """Main GPSD data processing loop with enhanced recovery"""
        buffer = ""
        
        while self.running:
            gpsd_sock = None
            
            try:
                # Wait for device to be available
                while self.running and not self.gpsd_manager.check_device():
                    logger.info("Waiting for Garmin GPS device...")
                    time.sleep(5)
                
                if not self.running:
                    break
                
                # Connect to gpsd
                gpsd_sock = self.connect_to_gpsd()
                if not gpsd_sock:
                    logger.warning("GPSD connection failed, attempting restart...")
                    try:
                        subprocess.run(['/home/cuas/gps_startup_cleanup.sh'], check=True, timeout=120)
                        time.sleep(3)
                        continue
                    except Exception as e:
                        logger.error(f"GPSD restart failed: {e}")
                        time.sleep(5)
                        continue
                
                # Process GPSD data
                while self.running and self.gpsd_connected:
                    try:
                        ready = select.select([gpsd_sock], [], [], 1.0)
                        
                        if ready[0]:
                            raw_data = gpsd_sock.recv(4096)
                            if not raw_data:
                                logger.warning("GPSD connection closed")
                                break
                            
                            buffer += raw_data.decode(errors='ignore')
                            
                            # Process complete lines
                            while "\n" in buffer:
                                line, buffer = buffer.split("\n", 1)
                                line = line.strip()
                                
                                if line.startswith("$"):
                                    # Add checksum if missing
                                    if '*' not in line:
                                        sentence = line[1:]
                                        checksum = self.calculate_nmea_checksum(sentence)
                                        line = f"{line}*{checksum}"
                                    
                                    # Broadcast NMEA data
                                    self.broadcast_message(line)
                                    self.health.update_gps()
                                    logger.debug(f"GPS: {line}")
                                    
                                elif '"class":"TPV"' in line or '"class":"SKY"' in line:
                                    # Process JSON data from GPSD if needed
                                    logger.debug(f"GPSD JSON: {line[:100]}...")
                        
                        # Send watchdog notification
                        self.health.send_watchdog_notification()
                        
                    except socket.timeout:
                        continue
                    except Exception as e:
                        logger.error(f"GPSD data processing error: {e}")
                        break
                
            except Exception as e:
                logger.error(f"GPSD loop error: {e}")
                self.gpsd_connected = False
                
            finally:
                if gpsd_sock:
                    try:
                        gpsd_sock.close()
                    except:
                        pass
                
                time.sleep(5)
    
    def watchdog_loop(self):
        """System watchdog monitoring"""
        while self.running:
            try:
                self.health.send_watchdog_notification()
                
                if not self.health.is_healthy():
                    logger.warning("System health check failed")
                
                time.sleep(WATCHDOG_INTERVAL)
                
            except Exception as e:
                logger.error(f"Watchdog error: {e}")
                time.sleep(WATCHDOG_INTERVAL)
    
    def signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        logger.info(f"Received signal {signum}, shutting down...")
        self.running = False
    
    def run(self):
        """Main execution function"""
        logger.info("=== Starting Garmin GPS Broadcasting System ===")
        
        # Setup signal handlers
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        
        # Start background threads
        threads = [
            threading.Thread(target=self.heartbeat_loop, daemon=True),
            threading.Thread(target=self.compass_loop, daemon=True),
            threading.Thread(target=self.device_monitor_loop, daemon=True),
            threading.Thread(target=self.watchdog_loop, daemon=True)
        ]
        
        for thread in threads:
            thread.start()
            logger.info(f"Started thread: {thread.name}")
        
        # Main GPSD processing loop
        try:
            self.gpsd_loop()
        except KeyboardInterrupt:
            logger.info("Received keyboard interrupt")
        except Exception as e:
            logger.error(f"Main loop error: {e}")
        finally:
            logger.info("Shutting down system...")
            self.running = False
            
            if self.udp_sock:
                self.udp_sock.close()
            
            logger.info("=== System Shutdown Complete ===")

def main():
    """Main entry point"""
    try:
        # Notify systemd that we're ready
        if SYSTEMD_AVAILABLE:
            systemd.daemon.notify('READY=1')
        
        # Create and run the GPS reader
        gps_reader = GarminReader()
        gps_reader.run()
        
    except Exception as e:
        logger.error(f"Critical error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()










