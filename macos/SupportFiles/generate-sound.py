"""Heed's arrival sound: three soft rising pips (C6, E6, G6), made from sine waves.

Run `make sound` to rewrite SupportFiles/Arrival.wav after changing it."""
import math, struct, sys, wave
RATE = 44100
def tone(freq, dur, start, out, amp, decay, attack, bright):
    n0 = int(start * RATE)
    for i in range(int(dur * RATE)):
        t = i / RATE
        # raised-cosine attack: no click at the start of each note
        a = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / attack))
        env = a * math.exp(-decay * t)
        ph = 2 * math.pi * freq * t
        s = math.sin(ph) + bright * math.sin(2 * ph)
        j = n0 + i
        if j < len(out): out[j] += amp * env * s
def lowpass(x, cutoff):
    rc = 1 / (2 * math.pi * cutoff); dt = 1 / RATE; k = dt / (rc + dt); y = 0.0; out = []
    for v in x: y += k * (v - y); out.append(y)
    return out
def write(path, out, level):
    peak = max(abs(x) for x in out) or 1
    # 12 ms fade-out so the tail ends cleanly
    n = int(0.012 * RATE)
    for i in range(n): out[-1 - i] *= i / n
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(x / peak * level * 32767)) for x in out))
# B soft: C6 -> E6 -> G6 (a major triad, warmer than the original G6-C7-E7), gentle attacks
b = [0.0] * int(0.40 * RATE)
for k, f in enumerate([1046.5, 1318.5, 1568.0]):
    tone(f, 0.16, k * 0.06, b, amp=0.40, decay=24, attack=0.010, bright=0.06)
tone(1568.0, 0.28, 0.12, b, amp=0.22, decay=11, attack=0.015, bright=0.0)
write(sys.argv[1], lowpass(b, 4500), 0.42)
