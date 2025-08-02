import serial
import threading
import time
import struct

# Register address definitions for WT901
registerMap = {
    0x50: {  # Device address
        "AccX": 0x34,
        "AccY": 0x35,
        "AccZ": 0x36,
        "GyroX": 0x37,
        "GyroY": 0x38,
        "GyroZ": 0x39,
        "MagX": 0x3A,
        "MagY": 0x3B,
        "MagZ": 0x3C,
        "AngX": 0x3D,
        "AngY": 0x3E,
        "AngZ": 0x3F,  # <-- This is heading (yaw)
    }
}

def calculate_crc(buf):
    crc = 0
    for b in buf:
        crc += b
    return (~crc) & 0xFF

class DeviceModel:
    def __init__(self, name, port, baudrate, addr_list, update_callback=None):
        self.name = name
        self.port = port
        self.baudrate = baudrate
        self.addr_list = addr_list
        self.update_callback = update_callback
        self.deviceData = {}
        self.serialPort = None
        self.readThread = None
        self.running = False

    def openDevice(self):
        try:
            self.serialPort = serial.Serial(self.port, self.baudrate, timeout=1)
            return True
        except Exception as e:
            print(f"[{self.name}] Failed to open port: {e}")
            return False

    def closeDevice(self):
        self.running = False
        if self.readThread:
            self.readThread.join()
        if self.serialPort and self.serialPort.is_open:
            self.serialPort.close()

    def startLoopRead(self):
        self.running = True
        self.readThread = threading.Thread(target=self._read_loop, daemon=True)
        self.readThread.start()

    def stopLoopRead(self):
        self.running = False
        if self.readThread:
            self.readThread.join()

    def _read_loop(self):
        while self.running:
            for addr in self.addr_list:
                for name, reg in registerMap[addr].items():
                    self._read_register(addr, reg, name)
                    time.sleep(0.005)
            if self.update_callback:
                self.update_callback(self)

    def _read_register(self, device_addr, register_addr, field_name):
        if not self.serialPort or not self.serialPort.is_open:
            return

        cmd = bytearray([0xFF, 0xFF, device_addr, 0x27, register_addr])
        cmd.append(calculate_crc(cmd[2:]))
        self.serialPort.write(cmd)

        try:
            res = self.serialPort.read(8)
            if len(res) == 8 and res[0] == 0xFF and res[1] == 0xFF:
                raw = res[5] << 8 | res[6]
                if raw >= 0x8000:
                    raw -= 0x10000
                value = raw / 32768.0 * 180.0
                if device_addr not in self.deviceData:
                    self.deviceData[device_addr] = {}
                self.deviceData[device_addr][field_name] = value
        except Exception as e:
            print(f"[{self.name}] Read error: {e}")

    def get(self, device_addr, field_name):
        return self.deviceData.get(device_addr, {}).get(field_name)
