#!/usr/bin/env python3
"""Read a WAV file and print its duration and peak frequency. Synthesizes nothing.

usage: scripts/bark-preview.py <file.wav>

Reads 16-bit PCM (mono or the first channel). The peak frequency is the strongest bin of the spectrum of the first
200 ms: numpy's FFT when numpy is present, else a plain DFT over a short (about 40 ms) window.
"""
import cmath
import math
import struct
import sys
import wave


def read(path):
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            sys.exit("only 16-bit PCM WAV is supported")
        rate, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
        raw = w.readframes(n)
    vals = struct.unpack("<%dh" % (len(raw) // 2), raw)
    return rate, [v / 32768.0 for v in vals[::ch]]


def peak_hz(samples, rate):
    try:
        import numpy as np
    except ImportError:
        np = None
    if np is not None:
        seg = np.asarray(samples[: int(0.2 * rate)], dtype=float)
        if seg.size == 0:
            return 0.0, "fft"
        spec = np.abs(np.fft.rfft(seg * np.hanning(seg.size)))
        spec[0] = 0
        return float(np.argmax(spec)) * rate / seg.size, "fft"
    n = min(len(samples), int(0.04 * rate))
    seg = samples[:n]
    if n == 0:
        return 0.0, "dft"
    best, best_k = -1.0, 0
    for k in range(1, n // 2):
        w = -2j * math.pi * k / n
        mag = abs(sum(x * cmath.exp(w * i) for i, x in enumerate(seg)))
        if mag > best:
            best, best_k = mag, k
    return best_k * rate / n, "dft"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    rate, s = read(sys.argv[1])
    hz, how = peak_hz(s, rate)
    peak = max((abs(x) for x in s), default=0.0)
    print("duration: %.1f ms (%d samples at %d Hz)" % (1000.0 * len(s) / rate, len(s), rate))
    print("peak amplitude: %.3f" % peak)
    print("peak frequency: %.0f Hz (%s)" % (hz, how))


if __name__ == "__main__":
    main()
