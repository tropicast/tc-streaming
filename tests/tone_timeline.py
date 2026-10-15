"""Which source a listener heard, over time, for tests/autodj.sh.

The live source plays a 1000 Hz tone and AutoDJ a 440 Hz one. Decodes the
recorded stream with ffmpeg to 8 kHz mono and classifies each half second
by its zero-crossing rate: L (live), A (AutoDJ), - (silence or noise).
Prints the run-length timeline, e.g. "L L A L" for live, AutoDJ, live.

    python3 tone_timeline.py RECORDING [--raw | --mp3-frames]

--raw prints one letter per half second instead. --mp3-frames counts the
MPEG-1/2 Layer III frames per sample rate and bitrate, e.g.
"44100 Hz 128 kbps x120, 48000 Hz 64 kbps x80" (ffprobe no longer reports a
sample rate per frame).
"""

import subprocess
import sys

RATE = 8000
WINDOW = RATE // 2


def classify(samples):
    crossings = sum(1 for a, b in zip(samples, samples[1:]) if (a < 0) != (b < 0))
    loud = sum(1 for s in samples if abs(s) > 1000)
    if loud < len(samples) // 4:
        return "-"
    hz = crossings / 2 / (len(samples) / RATE)
    if 850 <= hz <= 1150:
        return "L"
    if 360 <= hz <= 520:
        return "A"
    return "-"


# MPEG-1 and MPEG-2 Layer III: bitrate (kbps) and sample rate (Hz) tables.
BITRATES = {3: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
            2: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]}
RATES = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000]}


def mp3_frames(data):
    counts, i = {}, 0
    while i + 4 <= len(data):
        b1, b2 = data[i + 1], data[i + 2]
        version, layer = (b1 >> 3) & 3, (b1 >> 1) & 3
        bitrate_index, rate_index = b2 >> 4, (b2 >> 2) & 3
        if (data[i] != 0xFF or b1 & 0xE0 != 0xE0 or version not in (2, 3) or layer != 1
                or bitrate_index in (0, 15) or rate_index == 3):
            i += 1
            continue
        kbps, rate = BITRATES[version][bitrate_index], RATES[version][rate_index]
        size = (144 if version == 3 else 72) * kbps * 1000 // rate + ((b2 >> 1) & 1)
        counts[(rate, kbps)] = counts.get((rate, kbps), 0) + 1
        i += max(size, 1)
    return ", ".join(f"{rate} Hz {kbps} kbps x{n}" for (rate, kbps), n in sorted(counts.items()))


def main():
    path, raw = sys.argv[1], "--raw" in sys.argv[2:]
    if "--mp3-frames" in sys.argv[2:]:
        with open(path, "rb") as handle:
            print(mp3_frames(handle.read()))
        return
    pcm = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "quiet", "-i", path, "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"],
        capture_output=True,
    ).stdout
    samples = [int.from_bytes(pcm[i:i + 2], "little", signed=True) for i in range(0, len(pcm) - 1, 2)]
    letters = [classify(samples[i:i + WINDOW]) for i in range(0, len(samples) - WINDOW + 1, WINDOW)]
    if raw:
        print("".join(letters))
        return
    # Runs, ignoring single-window blips at a switch.
    runs = []
    for letter in letters:
        if runs and runs[-1][0] == letter:
            runs[-1][1] += 1
        else:
            runs.append([letter, 1])
    timeline = []
    for letter, count in runs:
        if count > 1 and letter != "-" and (not timeline or timeline[-1] != letter):
            timeline.append(letter)
    print(" ".join(timeline))


if __name__ == "__main__":
    main()
