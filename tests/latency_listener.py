"""Time stamps what a listener receives, for tests/latency.sh (#84).

Reads a stream from stdin (curl -N) as it arrives, writes it to RECORDING,
and writes "<epoch seconds> <total bytes>" to RECORDING.arrivals after each
read. The first line is "<epoch seconds> 0": when the listener started.

    curl -sN URL | python3 latency_listener.py RECORDING
"""

import os
import sys
import time


def main():
    path = sys.argv[1]
    with open(path, "wb") as recording, open(path + ".arrivals", "w") as arrivals:
        arrivals.write(f"{time.time():.6f} 0\n")
        total = 0
        while chunk := os.read(0, 65536):
            now = time.time()
            recording.write(chunk)
            recording.flush()
            total += len(chunk)
            arrivals.write(f"{now:.6f} {total}\n")
            arrivals.flush()


if __name__ == "__main__":
    main()
