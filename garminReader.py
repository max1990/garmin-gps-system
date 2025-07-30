"""
garminReader: UDP rebroadcaster for Garmin NMEA Data with Compass Integration
Enhanced with systemd watchdog support and comprehensive monitoring

Author:		Maximilian Leutermann
Date:		29 July 2025
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
DEVICE_PATH = "/dev/ttyUSB0"
DEVICE_CHECK_INTERVAL = 5
WATCHDOG_INTERVAL = 30  # Send watchdog keepalive every 30s

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

class CompassReader:
    """Independent compass reader for mission-critical heading data"""
    
    def __init__(self):
        self.heading = 0.0
        self.last_valid_heading = 0.0
        self.compass_active = False
        self.lock = threading.Lock()
        self.calibration_offset_x = 0.0
        self.calibration_offset_y = 0.0
        
    def load_calibration(self):
        """Load compass calibration from file"""
        try:
            with open('/home/cuas/compass_calibration.txt', 'r') as f:
                lines = f.readlines()
                self.calibration_offset_x = float(lines[0].strip())
                self.calibration_offset_y = float(lines[1].strip())
                logger.info(f"Loaded compass calibration: X={self.calibration_offset_x}, Y={self.calibration_offset_y}")
        except Exception as e:
            logger.warning(f"Could not load compass calibration: {e}, using defaults")
        
    def initialize_compass(self):
        """Initialize the QMC5883L compass"""
        try:
            import smbus
            self.bus = smbus.SMBus(I2C_BUS)
            
            # Load calibration
            self.load_calibration()
            
            # Initialize QMC5883L
            # Control Register 1: Continuous mode, 200Hz, 2G range, OSR 512
            self.bus.write_byte_data(QMC5883L_ADDR, 0x09, 0x1D)
            time.sleep(0.01)
            
            # Test read to verify connection
            chip_id = self.bus.read_byte_data(QMC5883L_ADDR, 0x0D)
            if chip_id != 0xFF:
                logger.warning(f"Unexpected chip ID: 0x{chip_id:02X}, expected 0xFF")
            
            self.compass_active = True
            logger.info("Compass initialized successfully")
            return True
            
        except ImportError:
            logger.error("smbus module not available - install python3-smbus")
            self.compass_active = False
            return False
        except Exception as e:
            logger.error(f"Failed to initialize compass: {e}")
            self.compass_active = False
            return False
    
    def read_compass(self):
        """Read compass heading, return degrees (0-359)"""
        if not self.compass_active:
            return self.last_valid_heading
            
        try:
            # Check data ready
            status = self.bus.read_byte_data(QMC5883L_ADDR, 0x06)
            if not (status & 0x01):  # Data not ready
                return self.last_valid_heading
            
            # Read X, Y, Z values (6 bytes)
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
            heading_deg = math.degrees(heading_rad)
            
            # Normalize to 0-359 degrees
            if heading_deg < 0:
                heading_deg += 360
                
            with self.lock:
                self.heading = heading_deg
                self.last_valid_heading = heading_deg
                
            return heading_deg
            
        except Exception as e:
            logger.warning(f"Compass read error: {e}")
            with self.lock:
                return self.last_valid_heading
    
    def get_heading(self):
        """Get current heading thread-safe"""
        with self.lock:
            return self.heading

class DeviceMonitor:
    """Monitor USB device connection and restart services if needed"""
    
    def __init__(self, device_path):
        self.device_path = device_path
        self.device_present = False
        
    def check_device(self):
        """Check if USB device is present"""
        return os.path.exists(self.device_path)
    
    def restart_gpsd(self):
        """Restart gpsd service"""
        try:
            logger.info("Restarting gpsd service...")
            subprocess.run(['sudo', 'pkill', 'gpsd'], check=False)
            time.sleep(2)
            subprocess.run(['sudo', 'gpsd', self.device_path, '-F', '/var/run/gpsd.sock'], check=True)
            time.sleep(2)
            logger.info("gpsd restarted successfully")
            return True
        except Exception as e:
            logger.error(f"Failed to restart gpsd: {e}")
            return False

class SystemHealth:
    """System health monitoring and watchdog notifications"""
    
    def __init__(self):
        self.last_heartbeat_sent = 0
        self.last_compass_sent = 0
        self.last_gps_data = 0
        self.system_healthy = True
        
    def update_heartbeat(self):
        """Update heartbeat timestamp"""
        self.last_heartbeat_sent = time.time()
        
    def update_compass(self):
        """Update compass timestamp"""
        self.last_compass_sent = time.time()
        
    def update_gps(self):
        """Update GPS data timestamp"""
        self.last_gps_data = time.time()
        
    def is_healthy(self):
        """Check if system is healthy"""
        now = time.time()
        
        # Check if compass is working (most critical)
        compass_age = now - self.last_compass_sent
        if compass_age > 30:  # No compass for 30 seconds
            logger.warning(f"Compass not working for {compass_age:.0f}s")
            self.system_healthy = False
            return False
            
        # Check heartbeat
        heartbeat_age = now - self.last_heartbeat_sent
        if heartbeat_age > 60:  # No heartbeat for 60 seconds
            logger.warning(f"No heartbeat for {heartbeat_age:.0f}s")
            self.system_healthy = False
            return False
        
        self.system_healthy = True
        return True
    
    def send_watchdog_notification(self):
        """Send systemd watchdog notification"""
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
        self.device_monitor = DeviceMonitor(DEVICE_PATH)
        self.health = SystemHealth()
        self.running = True
        self.gpsd_connected = False
        self.udp_sock = None
        self.setup_udp_socket()
        
    def setup_udp_socket(self):
        """Initialize UDP broadcast socket"""
        try:
            self.udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            # Set socket buffer size for better performance on Pi
            self.udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
            logger.info("UDP broadcast socket initialized")
        except Exception as e:
            logger.error(f"Failed to setup UDP socket: {e}")
    
    def broadcast_message(self, message):
        """Safely broadcast a message"""
        if self.udp_sock:
            try:
                self.udp_sock.sendto(message.encode('ascii', errors='ignore'), 
                                   (BROADCAST_IP, BROADCAST_PORT))
                return True
            except Exception as e:
                logger.warning(f"Broadcast failed: {e}")
                return False
        return False
    
    def compass_broadcast_loop(self):
        """Independent compass broadcast loop - MISSION CRITICAL"""
        logger.info("Starting compass broadcast loop...")
        
        # Try to initialize compass
        self.compass.initialize_compass()
        
        while self.running:
            try:
                heading = self.compass.read_compass()
                
                # Create NMEA HCHDG sentence with checksum
                nmea_sentence = f"HCHDG,{heading:.1f},,,,0.0"
                checksum = self.calculate_nmea_checksum(nmea_sentence)
                hchdg = f"${nmea_sentence}*{checksum:02X}"
                
                if self.broadcast_message(hchdg):
                    self.health.update_compass()
                    logger.debug(f"[COMPASS] {hchdg}")
                
                time.sleep(HEADING_INTERVAL)
                
            except Exception as e:
                logger.error(f"Compass broadcast error: {e}")
                time.sleep(HEADING_INTERVAL)
    
    def heartbeat_loop(self):
        """Broadcast heartbeat messages"""
        while self.running:
            try:
                timestamp = time.strftime('%H%M%S')
                heartbeat_sentence = f"PIHBX,HEARTBEAT,{timestamp}"
                checksum = self.calculate_nmea_checksum(heartbeat_sentence)
                heartbeat = f"${heartbeat_sentence}*{checksum:02X}"
                
                if self.broadcast_message(heartbeat):
                    self.health.update_heartbeat()
                    logger.info(f"Heartbeat sent: {timestamp}")
                
                time.sleep(HEARTBEAT_INTERVAL)
                
            except Exception as e:
                logger.error(f"Heartbeat error: {e}")
                time.sleep(HEARTBEAT_INTERVAL)
    
    def watchdog_loop(self):
        """Send systemd watchdog notifications"""
        while self.running:
            try:
                self.health.send_watchdog_notification()
                time.sleep(WATCHDOG_INTERVAL)
            except Exception as e:
                logger.error(f"Watchdog loop error: {e}")
                time.sleep(WATCHDOG_INTERVAL)
    
    def device_monitor_loop(self):
        """Monitor device connection and recover from disconnects"""
        while self.running:
            try:
                device_present = self.device_monitor.check_device()
                
                if not device_present and self.device_monitor.device_present:
                    logger.warning("USB device disconnected!")
                    self.gpsd_connected = False
                    
                elif device_present and not self.device_monitor.device_present:
                    logger.info("USB device reconnected, restarting gpsd...")
                    if self.device_monitor.restart_gpsd():
                        time.sleep(3)
                    
                self.device_monitor.device_present = device_present
                
                time.sleep(DEVICE_CHECK_INTERVAL)
                
            except Exception as e:
                logger.error(f"Device monitor error: {e}")
                time.sleep(DEVICE_CHECK_INTERVAL)
    
    def calculate_nmea_checksum(self, sentence):
        """Calculate NMEA checksum"""
        checksum = 0
        for char in sentence:
            checksum ^= ord(char)
        return checksum
    
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
        """Main GPSD data processing loop with recovery"""
        buffer = ""
        
        while self.running:
            gpsd_sock = None
            
            try:
                # Wait for device to be available
                while self.running and not self.device_monitor.check_device():
                    logger.info("Waiting for USB device...")
                    time.sleep(5)
                
                if not self.running:
                    break
                
                # Connect to gpsd
                gpsd_sock = self.connect_to_gpsd()
                if not gpsd_sock:
                    time.sleep(5)
                    continue
                
                # Process GPSD data
                while self.running and self.gpsd_connected:
                    try:
                        # Use select for non-blocking read with timeout
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
                                        sentence = line[1:]  # Remove $
                                        checksum = self.calculate_nmea_checksum(sentence)
                                        line = f"{line}*{checksum:02X}"
                                    
                                    if self.broadcast_message(line):
                                        self.health.update_gps()
                                        logger.debug(f"[GPSD] {line}")
                        
                        # Check if device is still connected
                        if not self.device_monitor.check_device():
                            logger.warning("Device disconnected during operation")
                            break
                            
                    except socket.timeout:
                        continue  # Normal timeout, continue loop
                    except Exception as e:
                        logger.error(f"GPSD read error: {e}")
                        break
            
            except Exception as e:
                logger.error(f"GPSD loop error: {e}")
            
            finally:
                if gpsd_sock:
                    try:
                        gpsd_sock.close()
                    except:
                        pass
                
                self.gpsd_connected = False
                logger.info("Disconnected from gpsd, will retry...")
                time.sleep(5)
    
    def signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully"""
        logger.info(f"Received signal {signum}, shutting down...")
        self.running = False
        
        # Notify systemd we're stopping
        if SYSTEMD_AVAILABLE:
            try:
                systemd.daemon.notify('STOPPING=1')
            except:
                pass
    
    def run(self):
        """Main execution method"""
        # Register signal handlers
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        logger.info("Starting Garmin Reader with compass integration and watchdog...")
        
        # Notify systemd we're ready
        if SYSTEMD_AVAILABLE:
            try:
                systemd.daemon.notify('READY=1')
                logger.info("Notified systemd service is ready")
            except Exception as e:
                logger.warning(f"Failed to notify systemd: {e}")
        
        # Start all threads
        threads = [
            threading.Thread(target=self.compass_broadcast_loop, daemon=True, name="CompassBroadcast"),
            threading.Thread(target=self.heartbeat_loop, daemon=True, name="Heartbeat"),
            threading.Thread(target=self.device_monitor_loop, daemon=True, name="DeviceMonitor"),
            threading.Thread(target=self.gpsd_loop, daemon=True, name="GPSDLoop"),
            threading.Thread(target=self.watchdog_loop, daemon=True, name="WatchdogLoop")
        ]
        
        for thread in threads:
            thread.start()
            logger.info(f"Started {thread.name} thread")
        
        # Wait a moment for threads to start
        time.sleep(2)
        
        try:
            # Main thread keeps running until signal received
            while self.running:
                # Periodic health check
                if not self.health.is_healthy():
                    logger.warning("System health check failed")
                
                time.sleep(10)  # Check every 10 seconds
                
        except KeyboardInterrupt:
            logger.info("Keyboard interrupt received")
        
        self.running = False
        
        # Wait for threads to finish
        for thread in threads:
            if thread.is_alive():
                thread.join(timeout=5)
        
        logger.info("Shutdown complete")

if __name__ == "__main__":
    if '--help' in sys.argv:
        print(__doc__)
        sys.exit()
    
    # Check if running as root
    if os.geteuid() != 0:
        logger.error("Must run as root for hardware access")
        sys.exit(1)
    
    reader = GarminReader()
    reader.run()
