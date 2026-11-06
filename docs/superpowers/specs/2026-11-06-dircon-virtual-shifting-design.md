# DirCon Proxy with Virtual Shimano Shifting — Design

Nov 6, 2026

This document ties together two existing specs in the repo root and records the decisions made on top of them:

- **Proxy spec:** `DirCon Trainer Proxy for macOS — Implementation Spec.md` — how the Mac holds the trainer's Bluetooth link and serves it to Zwift over DirCon.
- **Shifting spec:** `Virtual Shimano 2×12 Shifting over FTMS — Specification.md` — the 24-gear ladder, the resistance physics and the FTMS rewriting rules.

Where this document says nothing, those specs apply as written. Where they conflict, this document says which wins.

## Intent

The rider has a bike on a Magene T600 trainer, chain fixed on 52×14, with Shimano Ultegra Di2 R8150 levers. They want to ride Zwift on the same Mac and shift through the 24 gears of a real 52-36 × 11-34 Ultegra drivetrain, with the trainer's resistance following the virtual gear, while Zwift drives the trainer in SIM mode as normal.

Success: Zwift pairs with the proxy as its power source, cadence source and controllable trainer; riding in gear 21 feels exactly like the bike paired directly; shifting changes resistance the way a real gear change would.

## Goals

- One command-line program, `dirconproxy`, built as the proxy spec describes: Bluetooth link to the trainer, filtered GATT mirror, DirCon over TCP, own mDNS responder, interceptor pipeline, command line, lifecycle and reconnect.
- Virtual shifting implemented as a built-in interceptor in that pipeline, following the shifting spec's FTMS interface, control strategies, gear model and configuration.
- A simulated trainer inside the program, so DirCon, mDNS, Zwift pairing and shifting can be tested without the real trainer.
- Testing on the real T600, which is next to the Mac.

## Non-goals

- The shifting spec's hardware inputs (BLE HID remote, GPIO buttons, LED, vendor status BLE service). It was written for a standalone bridge board; on the Mac they are replaced by the inputs below.
- Everything the proxy spec lists as a non-goal (no Zwift proprietary services, no ANT+, no GUI).
- Showing the virtual gear inside Zwift (Zwift cannot display it).

## Anti-goals

- Gear 21 (k = 1) must be fully transparent: if shifting misbehaves, the bike must feel like its physical setup, never worse.
- A shift must never cause a Control Point error that Zwift sees, or make Zwift lose control of the trainer.

## Decided

**Platform and stack** (from the proxy spec): Swift Package Manager executable, macOS 13+, CoreBluetooth and Network.framework, Swift Argument Parser, one serial queue, embedded Info.plist. The package lives in this folder (`/Users/iremezoff/di2bikecontrol`), next to the existing Di2 test scripts.

**The trainer: Magene T600** (read from the device on Nov 6, 2026)

| Item | Value |
| --- | --- |
| Advertised name | `T600_35381` |
| Services | FTMS 0x1826, Cycling Power 0x1818, CSC 0x1816, Device Information 0x180A, vendor `8ce5cc01-0a4d-11e9-ab14-d663bd873d93` (hidden from Zwift) |
| Fitness Machine Feature 0x2ACC | `02 40 00 00 08 20 00 00`: machine features cadence + power; target settings power (bit 3) and indoor bike simulation (bit 13); **wheel circumference (bit 14) not set** |
| Supported Power Range 0x2AD8 | 20–2200 W, step 1 |
| Supported Resistance Level Range 0x2AD6 | 0–100, step 1 |
| Training Status 0x2AD3 | not present |
| Characteristic present in two services | 0x2A5D Sensor Location (in Cycling Power and in CSC) |
| Indoor Bike Data 0x2AD2 | flags 0x0044 (speed, cadence, power) at about 4 Hz, followed by 11 bytes the flags do not account for; forwarded untouched |

So `strategy = auto` selects **Strategy B (parameter transform)** on this trainer. Strategy A is implemented as the spec describes but cannot be tested here. Whether the T600 honours the Crr and Cw it is sent is unknown until shifting test T4; if it does not, the rider pins `strategy = equivalent_grade` with calibrated constants (test T10).

**How the two specs combine**

- Virtual shifting is an `Interceptor` registered in the proxy's pipeline, switched on by default and configurable off (which makes the proxy a pure pass-through, as the proxy spec's default).
- When shifting is on, the shifting spec's Control Point table wins over the proxy spec's control rules: the proxy requests control of the trainer itself as soon as the trainer is ready, answers Zwift's Request Control (0x00) locally with success, and owns Set Wheel Circumference (0x12). The proxy spec's rules for several DirCon clients still apply: only the client that sent Request Control first may control, the others get `80 <op> 05`.
- Fitness Machine Feature read by Zwift: the trainer's value with Target Setting bits 13 and 3 set and bit 14 cleared.
- Fitness Machine Status 0x12 and 0x13 caused by the proxy's own writes are not forwarded to Zwift.
- After a trainer reconnect, the proxy spec's control-state replay runs with the shifting spec's rule: request control, re-send the last road state with the current gear applied.
- Shifting configuration keys from the shifting spec live in the proxy's JSON config file under a `shifting` object; the BLE keys `ble.server_name` and `ble.trainer_address` do not apply (the proxy spec's `--name` and `--trainer` replace them).

**Shift input**

- An abstract shift input that produces `SHIFT_UP` (harder, toward 52×11) and `SHIFT_DOWN` (easier, toward 36×34) events, so the Di2 input can be added later without touching the gear logic. Each event moves one gear; shifts at either end are dropped.
- **Now: keyboard.** While `dirconproxy run` is on an interactive terminal, keys in that terminal shift (exact keys left to the builder; the rider's terminal key repeat gives repeated shifts on hold). This is a stand-in for testing, the builder's call, not something the rider asked for. Keys work only while that terminal window is in front; during Zwift test rides the rider runs Zwift full-screen on one monitor and the proxy's terminal on a second monitor, clicking the terminal to shift (the rider's setup; global keys or another input can be added later).
- **Later, not part of this build (postponed by the rider until the Di2 is available for testing): Di2 D-FLY.** This build only provides the abstract shift input that the Di2 source will plug into. Recorded here so the later build doesn't have to rediscover it: the proxy connects to the Di2 rear derailleur as a second Bluetooth peripheral, using the protocol and decoding in `di2dfly.swift`, which were verified on the rider's RD-R8150. Mapping decided by the rider:
  - D-FLY Ch.1 and Ch.2 (left lever) → `SHIFT_DOWN`; Ch.3 and Ch.4 (right lever) → `SHIFT_UP`.
  - Short press → one shift. Double press → two shifts. Long press → one shift at the long-press event, then repeated shifts until the release event (interval from `input.repeat_interval_ms`, default 150 ms).

**Wake hints:** the T600 sleeps when idle and advertises only after the flywheel turns. Whenever the proxy is scanning for or reconnecting to the trainer, its status line says so, e.g. `trainer not found: spin the trainer to wake it`.

**Gear feedback:** one status line in the terminal on every gear change, with gear number, ring × cog and k (for example `gear 14/24  36×14  k=0.692`).

**Testing order** (from the proxy spec's testing section, plus shifting): codec unit tests; gear table and transform unit tests (shifting tests T1 and the numeric check in the physics section); simulated trainer with DirCon and mDNS checks; real T600 without Zwift; Zwift with the T600; then shifting tests T2–T9 on the T600.

**Who tests what, and what "done" means** (builder's call, from the reviewer's questions):

- The builder runs everything that needs no rider: unit tests, the simulated trainer with DirCon, mDNS and a protocol client, and on the real T600 the connect, discovery, Request Control and a Set Target Power write.
- The rider runs everything that needs pedalling or Zwift: Zwift pairing and shifting tests T2–T9. The plan gives them exact steps and says what to read from the log for each.
- Done for this build = code complete, builder tests passing, Zwift pairs with the proxy on the T600, and T2–T9 handed to the rider. If T4 shows the T600 ignores Crr and Cw, calibration (T10) and switching to Strategy C are a follow-up, not part of this build.

## Left to the builder

- Module layout, file names, type names.
- Keyboard keys for the stand-in shift input.
- How the simulated trainer produces power in SIM mode (a fixed cadence with power from the shifting spec's road model is enough).
- The test framework (whatever runs with the installed toolchain: Apple Command Line Tools, Swift 6.1, no full Xcode).
- Anything both specs leave open, settled as each spec's risks table suggests (configurable where marked).
