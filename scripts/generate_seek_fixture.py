#!/usr/bin/env python3
"""生成无版权依赖的定位测试 FLAC；仅重新生成时需要 numpy、soundfile。"""
from pathlib import Path
import re
import tempfile
import numpy as np
import soundfile as sf

RATE, SECONDS = 44100, 130
sample = np.arange(RATE * SECONDS, dtype=np.uint32)
t = sample.astype(np.float64) / RATE
mode = (sample // (RATE * 8)) % 4
# 时间编码的非周期信号；各段熵和有效位数不同，避免固定码率掩盖近似定位错误。
h = sample.copy() + np.uint32(0x12345678)
h ^= h << np.uint32(13)
h ^= h >> np.uint32(17)
h ^= h << np.uint32(5)
noise = h.astype(np.float64) / 2147483648 - 1
chirp = np.sin(2 * np.pi * (127 * t + 0.37 * t * t))
y = np.where(mode == 0, np.round(chirp * 48) / 32768,
    np.where(mode == 1, noise * .65,
    np.where(mode == 2, np.round(noise * 12) / 32768, chirp * .3 + noise * .015)))
y = np.round(y * 32767).astype(np.int16)

with tempfile.TemporaryDirectory() as folder:
    encoded = Path(folder) / "sample.flac"
    sf.write(encoded, y, RATE, subtype="PCM_16", format="FLAC", compression_level=0)
    data = bytearray(encoded.read_bytes())

# 插入有效 seektable，避免首次加载必须扫描完整文件才能测试未缓冲定位。
offset, last = 4, 4
while True:
    last = offset
    size = int.from_bytes(data[offset + 1:offset + 4], "big")
    offset += size + 4
    if data[last] & 128:
        break

def header(at):
    i = at + 4
    first = data[i]
    if first < 128:
        number = first
        i += 1
    else:
        length = 0
        for bit in range(7, -1, -1):
            if first & (1 << bit): length += 1
            else: break
        if not 2 <= length <= 6: return None
        number = first & ((1 << (7 - length)) - 1)
        for value in data[i + 1:i + length]:
            if value & 0xc0 != 0x80: return None
            number = (number << 6) | (value & 63)
        i += length
    code, rate = data[at + 2] >> 4, data[at + 2] & 15
    if code == 6: frames, i = data[i] + 1, i + 1
    elif code == 7: frames, i = int.from_bytes(data[i:i+2], "big") + 1, i + 2
    elif 2 <= code <= 5: frames = 576 << (code - 2)
    elif 8 <= code <= 15: frames = 256 << (code - 8)
    elif code == 1: frames = 192
    else: return None
    if rate == 12: i += 1
    elif rate in (13,14): i += 2
    crc = 0
    for b in data[at:i]:
        crc ^= b
        for _ in range(8): crc = ((crc << 1) ^ (7 if crc & 128 else 0)) & 255
    return (number, frames) if crc == data[i] else None

points, expected, total = [], 0, 0
for match in re.finditer(b"\xff\xf8", data[offset:]):
    at = offset + match.start()
    value = header(at)
    if value is None or value[0] != expected: continue
    number, frames = value
    if number % 8 == 0:
        points.append(total.to_bytes(8,"big") + (at-offset).to_bytes(8,"big") + frames.to_bytes(2,"big"))
    total += frames
    expected += 1
assert total == RATE * SECONDS, (total, RATE * SECONDS)
seek = b"".join(points)
data[last] &= 127
result = data[:offset] + bytes([0x83]) + len(seek).to_bytes(3,"big") + seek + data[offset:]
output = Path(__file__).resolve().parents[1] / "PaiDianTests/Fixtures/seek-marker.flac"
output.write_bytes(result)
actual, actual_rate = sf.read(output, dtype="int16")
assert actual_rate == RATE and np.array_equal(actual, y)
print(f"{output.name}: {len(result)} bytes, {SECONDS}s/{RATE}Hz, {len(points)} seekpoints; lossless round-trip passed")

# Fast-start M4A uses the same generated PCM. A front-loaded sample index permits genuine
# unbuffered seeks without AVFoundation first scanning an index-free MP3/FLAC stream.
import subprocess
with tempfile.TemporaryDirectory() as folder:
    wave, m4a = Path(folder) / "sample.wav", Path(folder) / "sample.m4a"
    sf.write(wave, y, RATE, subtype="PCM_16")
    subprocess.run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", str(wave), str(m4a)], check=True)
    mp4 = bytearray(m4a.read_bytes())

def atoms(data, start=0, end=None):
    end = len(data) if end is None else end
    while start < end:
        size, kind = int.from_bytes(data[start:start+4], "big"), bytes(data[start+4:start+8])
        header = 8
        if size == 1: size, header = int.from_bytes(data[start+8:start+16], "big"), 16
        if size == 0: size = end - start
        assert size >= header and start + size <= end
        yield start, size, kind, header
        start += size

layout = list(atoms(mp4))
moov_start, moov_size, _, moov_header = next(a for a in layout if a[2] == b"moov")
insert = next(a[0] for a in layout if a[2] == b"mdat")
if moov_start > insert:
    moov = bytearray(mp4[moov_start:moov_start+moov_size])
    def adjust(start, end):
        for at, size, kind, header in atoms(moov, start, end):
            if kind in (b"trak", b"mdia", b"minf", b"stbl"):
                adjust(at + header, at + size)
            elif kind in (b"stco", b"co64"):
                width = 4 if kind == b"stco" else 8
                count = int.from_bytes(moov[at+header+4:at+header+8], "big")
                for index in range(count):
                    pos = at + header + 8 + index * width
                    value = int.from_bytes(moov[pos:pos+width], "big")
                    assert insert <= value < moov_start
                    moov[pos:pos+width] = (value + moov_size).to_bytes(width,"big")
    adjust(moov_header, moov_size)
    mp4 = mp4[:insert] + moov + mp4[insert:moov_start] + mp4[moov_start+moov_size:]
(Path(__file__).resolve().parents[1] / "PaiDianTests/Fixtures/seek-marker.m4a").write_bytes(mp4)
print(f"seek-marker.m4a: {len(mp4)} bytes, front-loaded sample index")
