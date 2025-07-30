#!/usr/bin/env python3
"""
System Watchdog - Ultimate Backup System Monitor
- Monitors critical system functions
- Automatic system restart as last resort
- Completely independent of main GPS service
- Handles missing hardware gracefully

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
HEARTBEAT_TIMEOUT = 300  # 5 minutes without heartbeat = problem (increased tolerance)
COMPASS_TIMEOUT = 300    # 5 minutes without compass = problem (increased tolerance)
CHECK_INTERVAL = 30      # Check every 30 seconds
MAX_FAILURES = 5         # Max consecutive failures before restart (increased tolerance)
RESTART_COMMAND = "/sbin/reboot"
GRACE_PERIOD = 300       # 5 minutes grace period on startup

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
        self.start_time = datetime.now()
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
        
        # Grace period - don't check for first 5 minutes
        if (now - self.start_time).total_seconds() < GRACE_PERIOD:
            logger.debug(f"Grace period active - {GRACE_PERIOD - (now - self.start_time).total_seconds():.0f}s remaining")
            return
        
        # Check GPS service (most important - if service is down, that's critical)
        if not self.is_service_running("gps-stream.service"):
            issues.append("GPS service not running")
        else:
            # Only check data streams if service is running
            service_start_time = self.get_service_start_time("gps-stream.service")
            if service_start_time:
                service_age = (now - service_start_time).total_seconds()
                
                # Allow service some time to start broadcasting
                if service_age > 60:  # Service has been running for more than 1 minute
                    # Check heartbeat (should always work)
                    if self.last_heartbeat:
                        heartbeat_age = (now - self.last_heartbeat).total_seconds()
                        if heartbeat_age > HEARTBEAT_TIMEOUT:
                            issues.append(f"No heartbeat for {heartbeat_age:.0f}s")
                    else:
                        issues.append("No heartbeat received yet (service running but not broadcasting)")
                    
                    # Check compass (only if we expect it to work)
                    # Don't fail if compass hardware is not connected
                    if self.last_compass:
                        compass_age = (now - self.last_compass).total_seconds()
                        if compass_age > COMPASS_TIMEOUT:
                            logger.warning(f"No compass data for {compass_age:.0f}s (hardware may be disconnected)")
                            # Don't add to issues - compass hardware may not be connected
                else:
                    logger.debug(f"Service starting up - {service_age:.0f}s old")
        
        # Check for critical system issues (these are always problems)
        if not os.path.exists("/dev/i2c-1"):
            logger.warning("I2C bus missing (compass will not work)")
            # Don't fail for this - I2C might be disabled if no compass hardware
        
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
    
    def get_service_start_time(self, service_name):
        """Get when a service was started"""
        try:
            result = subprocess.run(
                ['systemctl', 'show', service_name, '--property=ActiveEnterTimestamp'],
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                timestamp_str = result.stdout.strip().split('=')[1]
                if timestamp_str and timestamp_str != "n/a":
                    # Parse systemd timestamp format
                    return datetime.strptime(timestamp_str.split()[0] + " " + timestamp_str.split()[1], 
                                           "%Y-%m-%d %H:%M:%S")
        except Exception as e:
            logger.debug(f"Could not get service start time: {e}")
        return None
    
    def emergency_restart(self):
        """Last resort - restart the entire system"""
        logger.critical("EMERGENCY RESTART INITIATED - System health critical")
        logger.critical("All recovery attempts have failed")
        logger.critical("Executing system restart in 10 seconds...")
        
        # Try to restart the GPS service first as a last attempt
        try:
            logger.info("Attempting final service restart before system reboot...")
            subprocess.run(['systemctl', 'restart', 'gps-stream.service'], timeout=10)
            time.sleep(5)
            
            # Quick check if service is now running
            if self.is_service_running("gps-stream.service"):
                logger.info("Service restart successful, canceling system reboot")
                self.failure_count = 0
                return
        except Exception as e:
            logger.error(f"Final service restart failed: {e}")
        
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
        logger.info(f"Compass timeout: {COMPASS_TIMEOUT}s (warning only)")
        logger.info(f"Max failures before restart: {MAX_FAILURES}")
        logger.info(f"Grace period: {GRACE_PERIOD}s")
        logger.info("NOTE: System is designed to work without compass/GPS hardware")
        
        self.monitor_broadcasts()

if __name__ == "__main__":
    if os.geteuid() != 0:
        logger.error("Watchdog must run as root")
        sys.exit(1)
    
    watchdog = SystemWatchdog()
    watchdog.run()
