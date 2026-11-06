#!/usr/bin/env python3
"""
Print Shimano Di2 D-FLY channel button events over Bluetooth LE (macOS / Linux / Windows).

Setup:
  1. In E-TUBE PROJECT Cyclist (phone app), assign the buttons you want to read
     to "D-FLY Ch.1" ... "D-FLY Ch.4".
  2. pip install bleak
  3. python3 di2_dfly.py   (press a shifter button first to wake the Di2)

On macOS, the app you run this from (Terminal, iTerm, VS Code...) needs Bluetooth
permission: System Settings > Privacy & Security > Bluetooth.

Protocol details are taken from BikeControl's open-source Di2 driver
(github.com/OpenBikeControl/bikecontrol, lib/bluetooth/devices/shimano/shimano_di2.dart).
Not an official Shimano API: untested here against real hardware, and firmware may change it.
"""
import asyncio

from bleak import BleakClient, BleakScanner

BASE = "-5348-494d-414e-4f5f424c4500"  # Shimano base UUID ("SHIMANO_BLE" in ASCII)
DFLY_SERVICE = "000018ef" + BASE       # runtime D-FLY service, no passkey needed
DFLY_CHAR = "00002ac2" + BASE          # indicates: 1 header byte + 1 byte per channel

# High nibble = event, low nibble = per-channel press counter.
# Observed on RD-R8150: 0x2_ long press start, 0x3_ (long|short bits) still held,
# 0x0_ released after a long press, 0x4_ double press, 0xf0 = not pressed yet.


def describe(value: int) -> str:
    if value == 0xF0:
        return "idle"
    if value & 0x40:
        return "double press"
    if value & 0x20:
        return "long held" if value & 0x10 else "long press"
    if value & 0x10:
        return "short press"
    return "released"


def is_di2(device, adv) -> bool:
    uuids = [u.lower() for u in (adv.service_uuids or [])]
    name = (device.name or adv.local_name or "").upper()
    return DFLY_SERVICE in uuids or name.startswith("RDR")


async def scan_all(seconds: float = 15) -> None:
    """Diagnostic: list every BLE device the Mac sees, flagging likely Di2 units."""
    print(f"Scanning {seconds:.0f}s for all BLE devices (press a shifter button to wake the Di2)...")
    found = await BleakScanner.discover(timeout=seconds, return_adv=True)
    for device, adv in sorted(found.values(), key=lambda x: -(x[1].rssi or -999)):
        mark = "  <-- Di2?" if is_di2(device, adv) or "5348-494d-414e" in " ".join(adv.service_uuids or []) else ""
        print(f"{adv.rssi:>4} dBm  {device.address}  {device.name or adv.local_name or '-'}"
              f"  uuids={adv.service_uuids or []}  mfr={ {k: v.hex() for k, v in adv.manufacturer_data.items()} }{mark}")


async def main() -> None:
    print("Scanning for Di2 (press a shifter button to wake it)...")
    device = await BleakScanner.find_device_by_filter(is_di2, timeout=30)
    if device is None:
        raise SystemExit("No Di2 found. Wake it, keep it close, and make sure your phone app isn't connected.")
    print(f"Found {device.name} ({device.address})")

    last: list[int] | None = None

    def on_data(_sender, data: bytearray) -> None:
        nonlocal last
        channels = list(data[1:])
        if last is None:  # first packet is just the current state
            last = channels
            print(f"Ready. {len(channels)} D-FLY channels reported.")
            return
        for i, (old, new) in enumerate(zip(last, channels), start=1):
            if old != new:
                print(f"D-FLY Ch.{i}: {describe(new):<13} raw=0x{new:02x}  packet={data.hex()}")
        last = channels

    async with BleakClient(device) as client:
        await client.start_notify(DFLY_CHAR, on_data)  # bleak subscribes to indications too
        print("Listening. Ctrl+C to quit.")
        await asyncio.Event().wait()


if __name__ == "__main__":
    import sys
    try:
        asyncio.run(scan_all() if "--scan" in sys.argv else main())
    except KeyboardInterrupt:
        pass
