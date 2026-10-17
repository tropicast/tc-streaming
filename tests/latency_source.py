"""Paced live audio for tests/latency.sh (#84): the "microphone".

Writes signed 16-bit stereo PCM to stdout in real time, 20 ms at a time.
Second j of the source plays a tone of 600 + 100 * (j % 16) Hz, so a listener
who decodes the stream can tell which second it hears (latency.py). The wall
clock time of the first sample goes to --t0 when it is written: second j left
the microphone at t0 + j.

    python3 latency_source.py --seconds 30 --rate 48000 --t0 FILE | ffmpeg -f s16le ...
"""

import argparse
import math
import struct
import sys
import time

CHUNK = 0.02


def frequency(second):
    return 600 + 100 * (second % 16)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, required=True)
    parser.add_argument("--rate", type=int, default=48000)
    parser.add_argument("--t0", required=True, help="file that receives the wall clock time of the first sample")
    args = parser.parse_args()

    per_chunk = int(args.rate * CHUNK)
    out = sys.stdout.buffer
    phase, sample, start = 0.0, 0, time.monotonic()
    total = args.seconds * args.rate
    try:
        while sample < total:
            frames = []
            for _ in range(min(per_chunk, total - sample)):
                # Phase stays continuous across a frequency change: no click.
                phase += 2 * math.pi * frequency(sample // args.rate) / args.rate
                value = int(16000 * math.sin(phase))
                frames.append(struct.pack("<hh", value, value))
                sample += 1
            if sample <= per_chunk:
                with open(args.t0, "w") as handle:
                    handle.write(f"{time.time():.6f}\n")
            out.write(b"".join(frames))
            out.flush()
            # Pace on the monotonic clock, so a late chunk does not shift the rest.
            delay = start + sample / args.rate - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    except BrokenPipeError:
        pass


if __name__ == "__main__":
    main()
