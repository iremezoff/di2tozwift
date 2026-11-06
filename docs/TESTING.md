# Riding tests for dirconproxy

These are the tests that need someone on the bike. Everything that runs without pedalling has already been checked; see "Already verified" at the end.

## Before every session

1. **Close anything else that talks to the trainer.** That means the Magene app on your phone, and any **BikeControl** app: a device called `BikeControl 35381` was seen advertising on your network as a DirCon trainer. The T600 accepts one controlling app at a time.
2. **Permissions, once:**
   - Terminal (or iTerm): System Settings › Privacy & Security › **Bluetooth** and **Local Network**.
   - Zwift: System Settings › Privacy & Security › **Local Network**. Without it Zwift never sees the proxy.
   - If the firewall is on, allow incoming connections for `dirconproxy`.
3. **Build** (after any code change): `scripts/build.sh`
4. **Check the Mac:** `.build/release/dirconproxy doctor`. All lines should show ✓.
5. **Wake the trainer** by spinning the flywheel.

## Start the proxy

In Terminal, on the second monitor:

```sh
cd ~/di2bikecontrol
.build/release/dirconproxy run --log-level debug 2>&1 | tee ride.log
```

The first time it scans and asks you to pick the trainer; the choice is saved to `~/.config/dirconproxy/config.json`. Wait for:

```
trainer ready: T600_35381
DirCon listening on 192.168.x.x:36866
In Zwift pair "DirCon Proxy AA8D", not "T600_35381"
```

If you see `trainer not found: spin the trainer to wake it`, spin it.

**Shifting:** click the Terminal window, then press `]` or ↑ for harder and `[` or ↓ for easier. Each shift prints a line such as `gear 14/24  36×14  k=0.692`. You start in gear 21 (52×14), which feels exactly like the real bike.

Stop with Ctrl-C.

## Pair Zwift

Zwift full-screen on the first monitor. In the pairing screen choose **DirCon Proxy AA8D** for **Power Source**, **Controllable** and **Cadence**. Never choose `T600_35381`: that bypasses the proxy and gives the trainer two controllers. Set Trainer Difficulty to 100 % for the closest match to a real bike.

**Check A: pairing.** The proxy appears in Zwift within 10 s of `trainer ready`, the log shows `client connected …` then `control granted`, and the power and cadence in Zwift match the `data: … W` lines in the log.

## Shifting tests

For power tests, hold the cadence steady for 30 s and read the average of the last 20 s (Zwift's 3 s power is fine to eyeball). The expected numbers assume the trainer models an 85 kg rider and bike; your numbers can differ by a constant factor, but the **ratios between gears** should match.

T3, T4 and T5 can be ridden **without Zwift**, using the check script for an exact road. Run it in a third window while the proxy runs; it holds the trainer in the given road for `--listen` seconds and prints power:

```sh
.venv/bin/python scripts/dircon_check.py --grade 0 --crr 0.004 --cw 0.51 --listen 120
```

### T2 · Gear 21 is transparent

Zwift, flat road then a 5 % section, gear 21, 80 rpm. Then quit Zwift, pair it to `T600_35381` directly (proxy stopped), and ride the same. **Pass:** power through the proxy is within ±2 % of the direct ride at the same grade and cadence.

### T3 · Power per gear, flat

Check script: `--grade 0 --crr 0.004 --cw 0.51 --listen 300`, 90 rpm. Shift to each gear (from gear 21: `[` ×20 to gear 1, `[` ×13 to gear 8, ×9 to gear 12, ×4 to gear 17, `]` ×3 to gear 24).

| Gear | Ring × cog | Expected W | W per extra 10 kg |
|---|---|---|---|
| 1 | 36 × 34 | 21 | 1.3 |
| 8 | 36 × 19 | 75 | 2.3 |
| 12 | 36 × 15 | 136 | 3.0 |
| 17 | 36 × 12 | 248 | 3.7 |
| 21 | 52 × 14 | 450 | 4.6 |
| 24 | 52 × 11 | 898 | 5.9 |

Gear 24 needs about 900 W at 90 rpm; do it as a short effort or at 60 rpm (power scales close to cadence³ on the flat).

### T4 · Does the T600 honour Crr and Cw? (decides the method)

Proxy in pass-through: `.build/release/dirconproxy run --no-shifting`. Gear doesn't matter. 70 rpm, three runs of the check script:

1. `--grade 0 --crr 0.004 --cw 0.51` → about **224 W**
2. `--grade 0 --crr 0.004 --cw 0.25` → about **125 W** (≈ 99 W less)
3. `--grade 0 --crr 0.008 --cw 0.51` → about **254 W** (≈ 30 W more)

**Pass:** both changes move power by roughly those amounts. Then the current method (parameter transform) is right for the T600.
**Fail:** if power doesn't change with Cw or Crr, the T600 ignores them, and gears will feel wrong on flats while climbs still feel right. Then the calibration method (Strategy C, test T10 in the shifting spec) is needed; that's a follow-up build.

### T5 · Climb

Check script `--grade 5 --crr 0.004 --cw 0.51`, 70 rpm.

| Gear | Expected W |
|---|---|
| 1 | ≈ 121 |
| 4 | ≈ 178 |
| 8 | ≈ 235 |
| 12 | ≈ 317 |

### T6 · Shift latency

With `--log-level debug`, make 50 single shifts at a few seconds apart. In `ride.log` every `shifting: shift … → gear N` line is followed by `shifting: proxy → trainer: SIM …` with a timestamp at most **100 ms** later.

```sh
grep -E "shifting: (shift|proxy → trainer: SIM)" ride.log
```

### T7 · Burst

From gear 21, press `]` ten times as fast as you can. **Pass:** the last gear line says `gear 24/24`, the log has no `trainer rejected` or `trainer link degraded`, and the trainer's resistance settles in gear 24.

### T8 · ERG

Start a Zwift workout. **Pass:** the trainer holds Zwift's target whatever gear you pick; shifting prints gear lines but no `proxy → trainer: SIM` lines during the workout; after the workout, free-ride resistance uses the gear you left it in.

### T9 · Reconnect

Mid-ride, switch the trainer off and on again. **Pass:** within 5 s of the trainer advertising, the log shows `trainer ready` again, followed by `proxy → trainer: Request Control` and a `proxy → trainer: SIM` line for your current gear; Zwift keeps riding without re-pairing (the proxy keeps Zwift's connection open for up to 30 s).

## What to send back

For each test, send pass/fail, the numbers you saw, and `ride.log` (or the lines the test names).

## Already verified (no rider needed)

- 79 unit tests, among them the gear table (T1), the physics, the DirCon protocol and the shifting logic with a simulated trainer.
- mDNS: `dns-sd` and an independent client (wftnp with zeroconf) find `DirCon Proxy …` at port 36866 with all TXT keys and the A record; SIGTERM sends goodbye records.
- Real T600: discovery hides the Magene service; with shifting, Request Control → `80 00 01`, SIM 5 % in gear 19 → 4.40 % sent → `80 11 01`, a shift to gear 18 → 4.12 % → `80 11 01`; the T600's "simulation parameters changed" status messages are kept from Zwift; in pass-through, ERG 150 W → `80 05 01` from the trainer.
- Keyboard shifting and terminal restore after Ctrl-C.
