#!/usr/bin/env python3
"""Independent DirCon check of a running dirconproxy, using the wftnp client and zeroconf discovery.

  .venv/bin/python scripts/dircon_check.py                 # discover, request control, SIM 5 %, watch data
  .venv/bin/python scripts/dircon_check.py --erg 150       # also send ERG 150 W
  .venv/bin/python scripts/dircon_check.py --listen 30     # watch data for 30 s
  .venv/bin/python scripts/dircon_check.py --grade 0 --crr 0.008 --cw 0.25 --listen 30
"""
import argparse
import asyncio
import struct
from uuid import UUID

from wftnp import Endpoint, WftnpClient
from wftnp.discovery import discover


def sig(short: int) -> UUID:
    return UUID(f"0000{short:04x}-0000-1000-8000-00805f9b34fb")


CP, IBD, STATUS = sig(0x2AD9), sig(0x2AD2), sig(0x2ADA)


def ibd_text(d: bytes) -> str:
    flags = struct.unpack_from("<H", d, 0)[0]
    o, out = 2, []
    if not flags & 1:
        out.append(f"{struct.unpack_from('<H', d, o)[0] / 100:.2f} km/h"); o += 2
    if flags & 2: o += 2
    if flags & 4:
        out.append(f"{struct.unpack_from('<H', d, o)[0] / 2:.1f} rpm"); o += 2
    if flags & 8: o += 2
    if flags & 16: o += 3
    if flags & 32: o += 2
    if flags & 64:
        out.append(f"{struct.unpack_from('<h', d, o)[0]} W")
    return "  ".join(out)


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="DirCon Proxy", help="instance name prefix to pick")
    ap.add_argument("--host", help="skip discovery and connect here")
    ap.add_argument("--grade", type=float, default=5.0, help="SIM grade in %%")
    ap.add_argument("--crr", type=float, default=0.004, help="SIM rolling resistance")
    ap.add_argument("--cw", type=float, default=0.51, help="SIM wind resistance coefficient (kg/m)")
    ap.add_argument("--erg", type=int, help="also send Set Target Power (W)")
    ap.add_argument("--listen", type=float, default=3.0, help="seconds to print data")
    a = ap.parse_args()

    if a.host:
        endpoint = Endpoint(a.host)
    else:
        ads = await discover(timeout=4.0)
        for ad in ads:
            print(f"found {ad.name!r} at {ad.addresses} port {ad.endpoint.port} services {[str(s)[4:8] for s in ad.services]}")
        mine = [ad for ad in ads if ad.name.startswith(a.name)]
        if not mine:
            raise SystemExit(f"no DirCon device named {a.name!r}* found")
        endpoint = Endpoint(mine[0].addresses[0] if mine[0].addresses else mine[0].endpoint.host, mine[0].endpoint.port)
    print(f"connecting to {endpoint.host}:{endpoint.port}")

    client = WftnpClient(endpoint, auto_reconnect=False, heartbeat_interval=None)
    await client.start()
    await client.wait_ready()
    try:
        for s in await client.discover_services():
            chars = await client.discover_characteristics(s.uuid)
            print(f"service {s.uuid}: " + ", ".join(f"{str(c.uuid)[4:8]}:{int(c.properties):#04x}" for c in chars))

        await client.subscribe(CP, lambda n: print(f"  control point ← {n.value.hex(' ')}"))
        await client.subscribe(IBD, lambda n: print(f"  data: {ibd_text(n.value)}"))
        await client.subscribe(STATUS, lambda n: print(f"  status ← {n.value.hex(' ')}"))

        print("→ Request Control 00")
        await client.write_characteristic(CP, b"\x00")
        await asyncio.sleep(0.5)
        grade = struct.pack("<hhBB", 0, round(a.grade * 100), round(a.crr * 10000), round(a.cw * 100))
        print(f"→ SIM grade {a.grade} %: 11 {grade.hex(' ')}")
        await client.write_characteristic(CP, b"\x11" + grade)
        await asyncio.sleep(0.5)
        if a.erg is not None:
            print(f"→ ERG {a.erg} W")
            await client.write_characteristic(CP, b"\x05" + struct.pack("<h", a.erg))
        await asyncio.sleep(a.listen)
    finally:
        await client.stop()


asyncio.run(main())
