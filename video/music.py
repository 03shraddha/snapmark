# Writes a soft 30 second music bed to build/music.wav. Standard library only.
import math, struct, wave, os
SR = 44100; N = SR * 30
BPM = 96; BEAT = 60 / BPM
CHORDS = [[220.00, 277.18, 329.63, 415.30], [185.00, 233.08, 277.18, 349.23],   # Amaj7, F#m7
          [146.83, 220.00, 277.18, 369.99], [164.81, 246.94, 329.63, 415.30]]   # Dmaj7, E
buf = [0.0] * N
def add(freq, start, dur, amp, attack, release, harm=()):
    a = int(start * SR); n = int(dur * SR)
    w = 2 * math.pi * freq / SR
    for i in range(n):
        j = a + i
        if j >= N: break
        t = i / SR
        env = min(1, t / attack) * min(1, (dur - t) / release)
        v = math.sin(w * i)
        for k, g in harm: v += g * math.sin(w * k * i)
        buf[j] += amp * env * v
bar = BEAT * 4
t = 0.0; b = 0
while t < 30:
    ch = CHORDS[b % 4]
    for f in ch: add(f, t, bar + 0.4, 0.055, 0.5, 0.9, ((2, 0.25),))          # pad
    add(ch[0] / 2, t, bar, 0.11, 0.02, 0.6)                                    # bass
    order = [0, 2, 1, 3, 2, 3, 1, 2]
    for s in range(8):                                                         # pluck
        f = ch[order[s]] * 2
        n = int(0.45 * SR); a = int((t + s * BEAT / 2) * SR); w = 2 * math.pi * f / SR
        for i in range(n):
            if a + i >= N: break
            buf[a + i] += 0.075 * math.exp(-i / SR * 9) * (math.sin(w * i) + 0.3 * math.sin(2 * w * i))
    t += bar; b += 1
peak = max(abs(x) for x in buf)
os.makedirs('build', exist_ok=True)
with wave.open('build/music.wav', 'w') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(SR)
    out = bytearray()
    for i, x in enumerate(buf):
        fade = min(1, i / (SR * 0.8)) * min(1, (N - i) / (SR * 2.0))
        out += struct.pack('<h', int(x / peak * 0.6 * fade * 32767))
    f.writeframes(bytes(out))
print('music ok')
