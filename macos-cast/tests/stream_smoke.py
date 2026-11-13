#!/usr/bin/env python3
"""Send a real Annex B stream and exercise rejection/reconnect on a running receiver.

Generate media with ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 -t 4
  -c:v libx264 -preset ultrafast -tune zerolatency
  -x264-params aud=1:repeat-headers=1 -f h264 test.h264
Run: python3 stream_smoke.py HOST CODE test.h264
"""
import math
import pathlib
import re
import socket
import struct
import sys
import time

host, code, path = sys.argv[1:]
assert re.fullmatch(r'\d{6}', code)

def connect(pin=code):
    sock = socket.create_connection((host, 47999), timeout=5)
    for part in [b'HC', b'AST01 ', pin[:2].encode(), pin[2:].encode()]:
        sock.sendall(part)
    return sock

with connect(f'{(int(code) + 1) % 1000000:06d}') as sock:
    assert sock.recv(1) == b'', 'Wrong code was accepted'
time.sleep(.15)
print('PASS: rejected wrong connection code')

for length, kind in [(0, 1), (4194305, 1), (1, 99)]:
    with connect() as sock:
        assert sock.recv(1) == b'\x01'
        sock.sendall(struct.pack('!IB', length, kind))
        assert sock.recv(1) == b'', 'Invalid media frame was accepted'
    time.sleep(.15)
print('PASS: rejected invalid sizes/types, slot reusable')

raw = pathlib.Path(path).read_bytes()
markers = [m.start() for m in re.finditer(b'\x00\x00\x00\x01\x09', raw)]
assert len(markers) > 30, 'Use the ffmpeg AUD settings from this script docstring'
markers.append(len(raw))
with connect() as sock:
    assert sock.recv(1) == b'\x01'
    start = time.monotonic()
    for frame, (a, b) in enumerate(zip(markers, markers[1:])):
        body = raw[a:b]
        packet = struct.pack('!IB', len(body), 1) + body
        # Deliberately fragment framing and payload across sends.
        for chunk in (packet[:2], packet[2:5], packet[5:47], packet[47:]):
            sock.sendall(chunk)
        audio = b''.join(struct.pack('<hh', int(1200 * math.sin(2 * math.pi * 440 * (frame * 1600 + i) / 48000)),
                                    int(1200 * math.sin(2 * math.pi * 440 * (frame * 1600 + i) / 48000)))
                         for i in range(1600))
        sock.sendall(struct.pack('!IB', len(audio), 2) + audio)
        time.sleep(max(0, start + (frame + 1) / 30 - time.monotonic()))
    time.sleep(.5)
print(f'PASS: sent {len(markers) - 1} fragmented H.264 access units with PCM audio')
print('Check receiver diagnostics: renderer=1 confirms video rendering.')
