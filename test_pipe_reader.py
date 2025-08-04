import os

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
                print(f"Received Heading: {line}°")
except KeyboardInterrupt:
    print("Exiting pipe reader.")
