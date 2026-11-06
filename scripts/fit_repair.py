#!/usr/bin/env python3
"""Finish a Zwift FIT file that was never closed (Zwift quit mid-ride, so no End Ride › Save): keep every complete message as is, then append the
stop event, lap, session and activity messages Zwift writes when a ride is saved.

  .venv/bin/python scripts/fit_repair.py <broken.fit> <fixed.fit>

The original file is only read. Summaries are computed from the records; calories are estimated."""
import struct, sys
from datetime import datetime, timezone

CRC_TABLE = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
             0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
def crc16(data, crc=0):
    for b in data:
        t = CRC_TABLE[crc & 0xF]; crc = (crc >> 4) & 0x0FFF; crc ^= t ^ CRC_TABLE[b & 0xF]
        t = CRC_TABLE[crc & 0xF]; crc = (crc >> 4) & 0x0FFF; crc ^= t ^ CRC_TABLE[(b >> 4) & 0xF]
    return crc

FIT_EPOCH = 631065600  # 1989-12-31T00:00:00Z

def walk(d, start):
    """Yield (offset_end, global_num, fields{num: raw bytes}) for each complete data message."""
    defs, o, last_ts = {}, start, None
    while o < len(d):
        h = d[o]
        if h & 0x80:  # compressed timestamp header: data message
            local = (h >> 5) & 3; body_at = o + 1
        elif h & 0x40:  # definition
            if o + 6 > len(d): return
            arch, gnum, n = d[o + 2], d[o + 3:o + 5], d[o + 5]
            gnum = struct.unpack("<H" if arch == 0 else ">H", gnum)[0]
            p = o + 6; fields = []
            if p + 3 * n > len(d): return
            for i in range(n):
                fields.append((d[p], d[p + 1])); p += 3
            dev = 0
            if h & 0x20:
                if p >= len(d): return
                nd = d[p]; p += 1
                if p + 3 * nd > len(d): return
                dev = sum(d[p + 3 * i + 1] for i in range(nd)); p += 3 * nd
            defs[h & 0x0F] = (gnum, arch, fields, dev)
            o = p
            continue
        else:
            local = h & 0x0F; body_at = o + 1
        if local not in defs: return
        gnum, arch, fields, dev = defs[local]
        size = sum(s for _, s in fields) + dev
        if body_at + size > len(d): return
        vals, p = {}, body_at
        for num, s in fields:
            vals[num] = d[p:p + s]; p += s
        o = body_at + size
        yield o, gnum, vals, arch

def u(b, arch):
    if b is None: return None
    fmt = {1: "B", 2: "H", 4: "I"}.get(len(b))
    if not fmt: return None
    return struct.unpack(("<" if arch == 0 else ">") + fmt, b)[0]

src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()
hs = d[0]
end, recs, start_ts = hs, [], None
for off, gnum, v, arch in walk(d[:-2], hs):  # the last 2 bytes are the file CRC, never data
    end = off
    if gnum == 21 and start_ts is None:  # first event = timer start
        start_ts = u(v.get(253), arch)
    if gnum == 20:  # record
        r = {k: u(v.get(k), arch) for k in (253, 5, 6, 7, 3, 4, 2)}
        recs.append(r)
data = d[hs:end]
print(f"kept {len(data)} bytes of complete messages (of {len(d) - hs - 2}); {len(recs)} records")

INV = {1: 0xFF, 2: 0xFFFF, 4: 0xFFFFFFFF}
def ok(x, size): return x is not None and x != INV[size]
ts = [r[253] for r in recs if ok(r[253], 4)]
first, last = start_ts or ts[0], ts[-1]
elapsed = last - first
pauses = sum(b - a for a, b in zip(ts, ts[1:]) if b - a > 5)
timer = elapsed - pauses
dist = [r[5] for r in recs if ok(r[5], 4)]          # 1/100 m
spd = [r[6] for r in recs if ok(r[6], 2)]           # 1/1000 m/s
pwr = [r[7] for r in recs if ok(r[7], 2)]           # W
cad = [r[4] for r in recs if ok(r[4], 1)]           # rpm
alt = [r[2] for r in recs if ok(r[2], 2)]           # (m+500)*5
total_dist = dist[-1] if dist else 0
avg_spd = round(total_dist * 10 / timer) if timer else 0     # 1/1000 m/s from 1/100 m and s
max_spd = max(spd) if spd else 0
avg_pwr = round(sum(pwr) / len(pwr)) if pwr else 0
max_pwr = max(pwr) if pwr else 0
moving_cad = [c for c in cad if c > 0]
avg_cad = round(sum(moving_cad) / len(moving_cad)) if moving_cad else 0
max_cad = max(cad) if cad else 0
kcal = round(sum(pwr) / 1000 * 1.0)  # kJ ≈ kcal for cycling (~25 % efficiency × 4.18)
ascent = round(sum(max(0, b - a) for a, b in zip(alt, alt[1:])) / 5)

def msg(local, gnum, fields):
    """fields: list of (num, basetype, size, value). Returns definition + data bytes (little endian)."""
    defn = bytes([0x40 | local, 0, 0]) + struct.pack("<H", gnum) + bytes([len(fields)])
    for num, bt, size, _ in fields: defn += bytes([num, size, bt])
    body = bytes([local])
    for _, bt, size, val in fields:
        body += struct.pack({1: "<B", 2: "<H", 4: "<I"}[size], val)
    return defn + body

ENUM, U8, U16, U32 = 0x00, 0x02, 0x84, 0x86
tail = b""
tail += msg(12, 21, [(253, U32, 4, last), (0, ENUM, 1, 0), (1, ENUM, 1, 4), (4, U8, 1, 0)])  # timer stop_all
common = [(253, U32, 4, last), (2, U32, 4, first), (7, U32, 4, elapsed * 1000), (8, U32, 4, timer * 1000),
          (9, U32, 4, total_dist), (11, U16, 2, kcal)]
tail += msg(13, 19, common + [(13, U16, 2, avg_spd), (14, U16, 2, max_spd), (19, U16, 2, avg_pwr),
                             (20, U16, 2, max_pwr), (17, U8, 1, avg_cad), (18, U8, 1, max_cad),
                             (0, ENUM, 1, 9), (1, ENUM, 1, 1), (24, ENUM, 1, 0), (25, ENUM, 1, 2),
                             (254, U16, 2, 0)])                                      # lap
tail += msg(14, 18, common + [(14, U16, 2, avg_spd), (15, U16, 2, max_spd), (20, U16, 2, avg_pwr),
                             (21, U16, 2, max_pwr), (18, U8, 1, avg_cad), (19, U8, 1, max_cad),
                             (22, U16, 2, ascent), (25, U16, 2, 0), (26, U16, 2, 1),
                             (0, ENUM, 1, 8), (1, ENUM, 1, 1), (5, ENUM, 1, 2), (6, ENUM, 1, 58),
                             (28, ENUM, 1, 0), (254, U16, 2, 0)])                    # session
tail += msg(15, 34, [(253, U32, 4, last), (0, U32, 4, timer * 1000), (1, U16, 2, 1), (2, ENUM, 1, 0),
                     (3, ENUM, 1, 26), (4, ENUM, 1, 1)])                             # activity

body = data + tail
h = bytearray(d[:hs]); h[4:8] = struct.pack("<I", len(body))
if hs == 14: h[12:14] = struct.pack("<H", crc16(h[:12]))
out = bytes(h) + body
out += struct.pack("<H", crc16(out))
open(dst, "wb").write(out)
iso = lambda t: datetime.fromtimestamp(t + FIT_EPOCH, timezone.utc).astimezone().strftime("%H:%M:%S")
print(f"start {iso(first)}  end {iso(last)}  elapsed {elapsed}s  moving {timer}s  distance {total_dist/100:.0f} m")
print(f"avg power {avg_pwr} W (max {max_pwr})  avg cadence {avg_cad} rpm (max {max_cad})  "
      f"avg speed {avg_spd/1000*3.6:.1f} km/h (max {max_spd/1000*3.6:.1f})  ascent {ascent} m  ~{kcal} kcal")
