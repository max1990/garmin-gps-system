#!/usr/bin/env python3
"""
System Watchdog - Ultimate Backup System Monitor
- Monitors critical system functions
- Automatic system restart as last resort
- Completely independent of main GPS service

Author: Maximilian Leutermann
Date: 29 July 2025
"""

import time
import socket
import subprocess
import logging
import os
import sys
from datetime import datetime, timedelta

# Configuration
BROADCAST_IP = "192.168.137.255"
BROADCAST_PORT = 60000
HEARTBEAT_TIMEOUT = 180  # 3 minutes without heartbeat = problem
COMPASS_TIMEOUT = 120    # 2 minutes without compass = problem
CHECK_INTERVAL = 30      # Check every 30 seconds
MAX_FAILURES = 3         # Max consecutive failures before restart
RESTART_COMMAND = "/sbin/reboot"

# Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [WATCHDOG] %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('/var/log/system_watchdog.log')
    ]
)
logger = logging.getLogger(__name__)

class SystemWatchdog:
    def __init__(self):
        self.last_heartbeat = None
        self.last_compass = None
        self.failure_count = 0
        self.sock = None
        self.setup_socket()
    
    def setup_socket(self):
        """Setup UDP socket for monitoring broadcasts"""
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.sock.bind(('', BROADCAST_PORT))
            self.sock.settimeout(CHECK_INTERVAL)
            logger.info("Watchdog socket initialized")
        except Exception as e:
            logger.error(f"Failed to setup socket: {e}")
    
    def monitor_broadcasts(self):
        """Monitor for heartbeat and compass broadcasts"""
        try:
            while True:
                try:
                    data, addr = self.sock.recvfrom(1024)
                    message = data.decode('ascii', errors='ignore')
                    now = datetime.now()
                    
                    if 'HEARTBEAT' in message:
                        self.last_heartbeat = now
                        logger.debug("Heartbeat received")
                    elif 'HCHDG' in message:
                        self.last_compass = now
                        logger.debug("Compass data received")
                
                except socket.timeout:
                    # Timeout is normal, allows us to check system health
                    self.check_system_health()
                    continue
                except Exception as e:
                    logger.warning(f"Socket error: {e}")
                    time.sleep(5)
        
        except KeyboardInterrupt:
            logger.info("Watchdog stopped by user")
        except Exception as e:
            logger.error(f"Monitor error: {e}")
    
    def check_system_health(self):
        """Check if system is healthy"""
        now = datetime.now()
        issues = []
        
        # Check heartbeat
        if self.last_heartbeat:
            heartbeat_age = (now - self.last_heartbeat).total_seconds()
            if heartbeat_age > HEARTBEAT_TIMEOUT:
                issues.append(f"No heartbeat for {heartbeat_age:.0f}s")
        else:
            issues.append("No heartbeat received yet")
        
        # Check compass (mission critical)
        if self.last_compass:
            compass_age = (now - self.last_compass).total_seconds()
            if compass_age > COMPASS_TIMEOUT:
                issues.append(f"No compass data for {compass_age:.0f}s")
        else:
            issues.append("No compass data received yet")
        
        # Check GPS service
        if not self.is_service_running("gps-stream.service"):
            issues.append("GPS service not running")
        
        # Check USB device
        if not os.path.exists("/dev/ttyUSB0"):
            issues.append("USB device missing")
        
        # Check I2C (for compass)
        if not os.path.exists("/dev/i2c-1"):
            issues.append("I2C bus missing")
        
        # Evaluate health
        if issues:
            self.failure_count += 1
            logger.warning(f"Health check failed ({self.failure_count}/{MAX_FAILURES}): {', '.join(issues)}")
            
            if self.failure_count >= MAX_FAILURES:
                self.emergency_restart()
        else:
            if self.failure_count > 0:
                logger.info("System health restored")
            self.failure_count = 0
    
    def is_service_running(self, service_name):
        """Check if a systemd service is running"""
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', service_name],
                capture_output=True,
                text=True
            )
            return result.returncode == 0 and result.stdout.strip() == 'active'
        except Exception:
            return False
    
    def emergency_restart(self):
        """Last resort - restart the entire system"""
        logger.critical("EMERGENCY RESTART INITIATED - System health critical")
        logger.critical("All recovery attempts have failed")
        logger.critical("Executing system restart in 10 seconds...")
        
        # Give time for log to be written
        time.sleep(10)
        
        try:
            # Sync filesystem
            subprocess.run(['sync'], timeout=5)
            
            # Restart system
            subprocess.run([RESTART_COMMAND], timeout=5)
        except Exception as e:
            logger.critical(f"Failed to restart system: {e}")
            # Force restart as absolute last resort
            os.system("/sbin/reboot -f")
    
    def run(self):
        """Main watchdog loop"""
        logger.info("System Watchdog started - Ultimate backup monitoring")
        logger.info(f"Heartbeat timeout: {HEARTBEAT_TIMEOUT}s")
        logger.info(f"Compass timeout: {COMPASS_TIMEOUT}s")
        logger.info(f"Max failures before restart: {MAX_FAILURES}")
        
        self.monitor_broadcasts()

if __name__ == "__main__":
    if os.geteuid() != 0:
        logger.error("Watchdog must run as root")
        sys.exit(1)
    
    watchdog = SystemWatchdog()
    watchdog.run()
