import time
import threading
import glob
import os
from device_model_original import DeviceModel

def auto_detect_usb():
    devices = glob.glob('/dev/ttyUSB*')
    if not devices:
        return None
    for device in devices:
        if "1a86" in get_usb_vendor_id(device):  # CH340
            return device
    return devices[0] if devices else None

def get_usb_vendor_id(device_path):
    try:
        dev_num = os.path.basename(device_path).replace("ttyUSB", "")
        base_path = f"/sys/class/tty/ttyUSB{dev_num}/device"
        for _ in range(5):
            vendor_file = os.path.join(base_path, "idVendor")
            if os.path.exists(vendor_file):
                with open(vendor_file, 'r') as f:
                    return f.read().strip()
            base_path = os.path.dirname(base_path)
    except:
        return None

class HeadingReader:
    def __init__(self):
        self.heading = None
        self._lock = threading.Lock()
        self._running = False
        self._thread = None
        self.imu = None

    def _read_loop(self):
        while self._running:
            raw = self.imu.get(0x50, "AngZ")
            if raw is not None:
                normalized = (raw + 360) % 360
                corrected = (360 - normalized) % 360
                with self._lock:
                    self.heading = corrected
            time.sleep(0.25)

    def get_heading(self):
        with self._lock:
            return self.heading

    def start(self):
        port = auto_detect_usb()
        if not port:
            raise RuntimeError("No USB serial device found")
        self.imu = DeviceModel("WT901", port, 9600, [0x50], lambda x: None)
        self.imu.openDevice()
        time.sleep(1)
        self.imu.loop = True
        self.imu.startLoopRead()

        self._running = True
        self._thread = threading.Thread(target=self._read_loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._running = False
        if self._thread:
            self._thread.join()
        self.imu.loop = False
        time.sleep(0.1)
        self.imu.stopLoopRead()
        self.imu.closeDevice()
