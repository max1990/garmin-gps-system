# Garmin GPS System with Compass Integration

Mission-critical GPS and compass broadcasting system for Raspberry Pi with automatic recovery and self-healing capabilities.

## Features

🛰️ **GPS Broadcasting** - Rebroadcasts Garmin Montana 710 NMEA data via UDP
🧭 **Mission-Critical Compass** - Independent QMC5883L compass broadcasts (1Hz)
🔄 **Auto Recovery** - Automatic recovery from USB disconnects
🛡️ **System Watchdog** - Automatic system restart on critical failures
📡 **UDP Broadcasting** - Network-wide sensor data distribution
⚡ **Optimized for Pi 2** - Efficient resource usage

## Testing Hardware Compatibility

Before installation, test if your Garmin Montana 710 is properly detected:

```bash
# Download and run the hardware test
curl -fsSL https://raw.githubusercontent.com/max1990/garmin-gps-system/main/test_garmin_detection.sh | sudo bash

## Quick Installation

Run this single command on your Raspberry Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/max1990/garmin-gps-system/main/install.sh | sudo bash
