import os
import time
import glob
from device_model_original import DeviceModel
import fcntl

PIPE_PATH = "/tmp/heading_pipe"

# create the pipe once
if not os.path.exists(PIPE_PATH):
    os.mkfifo(PIPE_PATH)

# Auto-detect USB serial port
def auto_detect_usb():
    devices = glob.glob('/dev/ttyUSB*')
    if not devices:
        print("❌ No USB serial devices found")
        return None

    print(f"🔍 Found USB serial devices: {devices}")

    for device in devices:
        vendor_id = get_usb_vendor_id(device)
        if vendor_id == "1a86":  # CH340
            print(f"✅ Found CH340 device: {device}")
            return device

    print(f"⚠️  Using first available device: {devices[0]}")
    return devices[0]

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
        pass
    return None

def write_pipe_nonblocking(pipe_path, data):
    """Open the FIFO in non-blocking mode and write a line."""
    try:
        # O_WRONLY|O_NONBLOCK: return immediately if no reader
        fd = os.open(pipe_path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        return  # no-one’s reading, just skip
    try:
        os.write(fd, (data + "\n").encode())
    finally:
        os.close(fd)

def main():
    port = auto_detect_usb()
    imu = DeviceModel("WT901", port, 9600, [0x50], lambda dev: None)
    imu.openDevice()
    time.sleep(1)  # let the thread spin up
    imu.loop = True
    imu.startLoopRead()

    try:
        while True:
            # synchronously request the angle registers
            # imu.readReg(0x44, 3)   # 0x44..0x46 = Roll/Pitch/Yaw
            # time.sleep(0.1)        # wait for the reply to arrive and be parsed

            raw = imu.get(0x50, "AngZ")  # yaw in degrees
            if raw is not None:
                # normalize and flip to your convention
                normalized = (raw + 360) % 360
                fixed = (360 - normalized) % 360

                # print to stdout
                print(f"Heading: {fixed:.2f}°")

                # write to FIFO, non-blocking
                write_pipe_nonblocking(PIPE_PATH, f"{fixed:.2f}")

            time.sleep(0.9)  # ~1 Hz update rate
    except KeyboardInterrupt:
        print("Exiting…")
    finally:
        imu.closeDevice()

if __name__ == "__main__":
    main()
