"""How far behind the microphone a listener hears, for tests/latency.sh (#84).

Inputs: a recording and its arrival times (latency_listener.py), and the
live sessions that were on air (latency_source.py: start time and length).
Live audio plays 600 + 100 * (j % 16) Hz in second j of a session, AutoDJ
440 Hz.

Each MP3 frame or Ogg page gets the time its last byte arrived. A player
with no buffer of its own plays every frame as soon as it has it and the
previous one has finished: that is when the listener hears it ("heard"),
so a burst sent at connect is a delay the listener keeps. "wire" is when
the bytes arrived, which is what Icecast and the network add on their own.

Prints one JSON object, all values in seconds:
  first_audio       listener start to the first complete frame
  connect           heard delay of the live source just after connect
  steady            heard delay at the end of the first session
  wire_steady       the same, on the wire
  to_autodj         end of the first session to the first AutoDJ audio heard
  to_live           start of the second session to its first audio heard
  after_return      heard delay at the end of the second session
  timeline          "L A L A": live, AutoDJ, live, AutoDJ

    python3 latency.py RECORDING mp3|opus --session T0:SECONDS --session T0:SECONDS
"""

import argparse
import array
import bisect
import json
import statistics
import subprocess
import sys

from tone_timeline import BITRATES, RATES

RATE = 8000
WINDOW = RATE // 20  # 50 ms
AUTODJ_HZ = 440


def mp3_header(data, i):
    """(size, seconds of audio) of the MPEG-1/2 Layer III frame header at i, or None."""
    b1, b2 = data[i + 1], data[i + 2]
    version, layer = (b1 >> 3) & 3, (b1 >> 1) & 3
    bitrate_index, rate_index = b2 >> 4, (b2 >> 2) & 3
    if (data[i] != 0xFF or b1 & 0xE0 != 0xE0 or version not in (2, 3) or layer != 1
            or bitrate_index in (0, 15) or rate_index == 3):
        return None
    kbps, rate = BITRATES[version][bitrate_index], RATES[version][rate_index]
    size = (144 if version == 3 else 72) * kbps * 1000 // rate + ((b2 >> 1) & 1)
    return size, (1152 if version == 3 else 576) / rate


def mp3_frames(data):
    """(end offset, seconds of audio) of each MPEG-1/2 Layer III frame. A
    header only counts when another one follows it (or the data ends), so
    bytes inside a frame cut by a switch or by the join are not taken for
    a frame."""
    i = 0
    while i + 4 <= len(data):
        frame = mp3_header(data, i)
        if frame is None:
            i += 1
            continue
        size, seconds = frame
        if i + size > len(data):
            return
        if i + size + 4 <= len(data) and mp3_header(data, i + size) is None:
            i += 1
            continue
        yield i + size, seconds
        i += size


def opus_seconds(packet):
    """Length of one Opus packet, from its TOC byte (RFC 6716, 3.1)."""
    if not packet or packet.startswith((b"OpusHead", b"OpusTags")):
        return 0.0
    config, code = packet[0] >> 3, packet[0] & 3
    if config < 12:
        frame = (0.01, 0.02, 0.04, 0.06)[config % 4]
    elif config < 16:
        frame = (0.01, 0.02)[config % 2]
    else:
        frame = (0.0025, 0.005, 0.01, 0.02)[config % 4]
    count = 1 if code == 0 else 2 if code in (1, 2) else (packet[1] & 0x3F if len(packet) > 1 else 0)
    return frame * count


def ogg_pages(data):
    """(end offset, seconds of audio) of each Ogg Opus page, counted from
    the packets that end on it. Granule positions are not used: a listener
    who joins mid-stream, or a switch to a chained stream, would make them
    jump."""
    i, packet = 0, None
    while (i := data.find(b"OggS", i)) >= 0 and i + 27 <= len(data):
        segments = data[i + 26]
        lacing = data[i + 27:i + 27 + segments]
        size = 27 + segments + sum(lacing)
        if i + size > len(data):
            return
        if not data[i + 5] & 1:
            packet = b""  # not a continuation: drop a packet cut by a switch
        elif not packet:
            packet = None  # continues a packet whose start never arrived: drop it
        seconds, offset = 0.0, i + 27 + segments
        for value in lacing:
            if packet is not None:
                packet += data[offset:offset + value]
            offset += value
            if value < 255:
                if packet is not None:
                    seconds += opus_seconds(packet)
                packet = b""
        yield i + size, seconds
        i += size


class Player:
    """Plays frames in order, each once it has arrived: heard(x) is when
    second x of the decoded audio reaches the ear."""

    def __init__(self, frames, arrivals):
        times, totals = zip(*arrivals)
        self.audio, self.start, self.arrival, clock, audio = [], [], [], None, 0.0
        for end, seconds in frames:
            arrived = times[min(bisect.bisect_left(totals, end), len(times) - 1)]
            clock = arrived if clock is None else max(clock, arrived)
            self.audio.append(audio)
            self.start.append(clock)
            self.arrival.append(arrived)
            audio += seconds
            clock += seconds

    def _frame(self, x):
        return max(bisect.bisect_right(self.audio, x) - 1, 0)

    def heard(self, x):
        i = self._frame(x)
        return self.start[i] + (x - self.audio[i])

    def wire(self, x):
        return self.arrival[self._frame(x)]


def label(samples):
    """'A' (AutoDJ), 0-15 (second of a live session, mod 16) or None."""
    if sum(1 for s in samples if abs(s) > 1000) < len(samples) // 4:
        return None
    crossings = sum(1 for a, b in zip(samples, samples[1:]) if (a < 0) != (b < 0))
    hz = crossings / 2 / (len(samples) / RATE)
    if abs(hz - AUTODJ_HZ) <= 60:
        return "A"
    step = round((hz - 600) / 100)
    if 0 <= step < 16 and abs(hz - (600 + 100 * step)) <= 40:
        return step
    return None


def runs(labels):
    """[label, first window, windows], ignoring runs shorter than 100 ms."""
    out = []
    for i, value in enumerate(labels):
        if out and out[-1][0] == value:
            out[-1][2] += 1
        else:
            out.append([value, i, 1])
    return [r for r in out if r[0] is not None and r[2] >= 2]


def blocks(steady_runs):
    """Live and AutoDJ blocks: ("L" or "A", [runs])."""
    out = []
    for run in steady_runs:
        kind = "A" if run[0] == "A" else "L"
        if out and out[-1][0] == kind:
            out[-1][1].append(run)
        else:
            out.append((kind, [run]))
    return out


def delays(block, player, t0, length):
    """(heard, wire) delay of each change of second inside a live block."""
    out = []
    for previous, run in zip(block, block[1:]):
        if run[0] != (previous[0] + 1) % 16:
            continue
        x = (previous[1] + previous[2] + run[1]) / 2 * WINDOW / RATE
        heard, wire = player.heard(x), player.wire(x)
        # The second it is: the one of this label that left the microphone
        # less than 16 s before it was heard.
        for second in range(run[0], length, 16):
            if 0 <= heard - (t0 + second) < 16:
                out.append((heard - (t0 + second), wire - (t0 + second)))
                break
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("recording")
    parser.add_argument("format", choices=["mp3", "opus"])
    parser.add_argument("--session", action="append", required=True, help="T0:SECONDS of a live session, in order")
    args = parser.parse_args()
    sessions = [(float(t0), int(length)) for t0, length in (s.split(":") for s in args.session)]

    with open(args.recording, "rb") as handle:
        data = handle.read()
    with open(args.recording + ".arrivals") as handle:
        rows = [tuple(map(float, line.split())) for line in handle if line.strip()]
    listen_start, arrivals = rows[0][0], [(t, int(n)) for t, n in rows[1:]]
    frames = list((mp3_frames if args.format == "mp3" else ogg_pages)(data))
    player = Player(frames, arrivals)

    pcm = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "quiet", "-i", args.recording, "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"],
        capture_output=True, check=True,
    ).stdout
    samples = array.array("h", pcm[:len(pcm) // 2 * 2])
    if sys.byteorder != "little":
        samples.byteswap()
    labels = [label(samples[i:i + WINDOW]) for i in range(0, len(samples) - WINDOW + 1, WINDOW)]
    timeline = blocks(runs(labels))

    def at(window):
        return window * WINDOW / RATE

    result = {"timeline": " ".join(kind for kind, _ in timeline), "first_audio": None}
    first_full = next((i for i, (_, seconds) in enumerate(frames) if seconds > 0), None)
    if first_full is not None:
        result["first_audio"] = player.arrival[first_full] - listen_start
    live = [b for kind, b in timeline if kind == "L"]
    autodj = [b for kind, b in timeline if kind == "A"]
    if live:
        first = delays(live[0], player, *sessions[0])
        if first:
            result["connect"] = statistics.median(d for d, _ in first[:3])
            result["steady"] = statistics.median(d for d, _ in first[-5:])
            result["wire_steady"] = statistics.median(w for _, w in first[-5:])
    if live and autodj and timeline[0][0] == "L":
        t0, length = sessions[0]
        result["to_autodj"] = player.heard(at(autodj[0][0][1])) - (t0 + length)
    if len(live) > 1 and len(sessions) > 1:
        result["to_live"] = player.heard(at(live[1][0][1])) - sessions[1][0]
        second = delays(live[1], player, *sessions[1])
        if second:
            result["after_return"] = statistics.median(d for d, _ in second[-3:])
    print(json.dumps({k: round(v, 2) if isinstance(v, float) else v for k, v in result.items()}))


if __name__ == "__main__":
    main()
