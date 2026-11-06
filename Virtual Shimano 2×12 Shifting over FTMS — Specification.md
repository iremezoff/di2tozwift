# Virtual Shimano 2×12 Shifting over FTMS — Specification

Nov 6, 2026 · @Ivan Remezov

## Purpose and scope

A small BLE bridge makes a bike that is physically locked in 52×14 ride like a Shimano 12-speed road drivetrain (52-36 crank, 11-34 cassette): 24 virtual gears on one up/down ladder, while Zwift keeps driving the trainer in SIM mode over FTMS.

- **Physical side:** the chain never moves. It stays on 52T × 14T, ratio 3.714.
- **Virtual side:** all 24 chainring × cog combinations, sorted by ratio into one ladder. There is no separate front shift; crossing between rings happens inside the ladder.
- **In scope:** gear table, resistance mapping, the FTMS server the bridge shows to Zwift, the FTMS client it uses on the trainer, shift input, configuration, acceptance tests.
- **Out of scope:** ERG workouts. In ERG the trainer holds a power target whatever the gear, so the bridge passes ERG commands through unchanged.
- **Why not Zwift's own virtual shifting:** it needs a Zwift Ready or Zwift Cog Compatible trainer plus a Zwift controller, and it uses Zwift's gear table rather than a Shimano one ([Zwift FAQ](https://support.zwift.com/en_us/virtual-shifting-faq-r16UiRFlT)). This bridge works with any FTMS trainer and any shifter.
- **Assumption:** small ring = 36T. Shimano's 12-speed road cranks pair 52T with 36T; the request said 35T. The ring sizes are configuration values, so 35T only changes the 12 small-ring rows.

## System architecture

&#91;embedded content: bridge architecture · 6 parts, commands down, data up\]

Zwift never talks to the trainer: every command passes through the bridge, which rewrites only simulation and circumference writes and relays everything else. The bridge can run on any board that is a BLE peripheral and central at the same time.

## Gear model

Every virtual gear is reduced to one number, the scale factor k = virtual ratio ÷ physical ratio (52/14 = 3.714). The ladder runs from k = 0.285 (36×34) to k = 1.273 (52×11); gear 21 (52×14) is k = 1, where the bridge changes nothing.

Cassette 11-12-13-14-15-17-19-21-24-27-30-34 per [Shimano CS-R8100 11-34](https://www.rei.com/product/195093/shimano-ultegra-cs-r8100-12-speed-cassette); crank 52-36 per [Shimano FC-R8100](https://bike.shimano.com/en-NZ/products/components/pdp.P-FC-R8100.html). Speed and circumference assume a 2105 mm wheel (700×25C).

| Gear | Ring (T) | Cog (T) | Ratio | k | Step vs previous | Speed @ 90 rpm (km/h) | Virtual circumference (mm) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 36 | 34 | 1.0588 | 0.2851 | — | 12.0 | 600.1 |
| 2 | 36 | 30 | 1.2000 | 0.3231 | +13.3% | 13.6 | 680.1 |
| 3 | 36 | 27 | 1.3333 | 0.3590 | +11.1% | 15.2 | 755.6 |
| 4 | 36 | 24 | 1.5000 | 0.4038 | +12.5% | 17.1 | 850.1 |
| 5 | 52 | 34 | 1.5294 | 0.4118 | +2.0% | 17.4 | 866.8 |
| 6 | 36 | 21 | 1.7143 | 0.4615 | +12.1% | 19.5 | 971.5 |
| 7 | 52 | 30 | 1.7333 | 0.4667 | +1.1% | 19.7 | 982.3 |
| 8 | 36 | 19 | 1.8947 | 0.5101 | +9.3% | 21.5 | 1073.8 |
| 9 | 52 | 27 | 1.9259 | 0.5185 | +1.6% | 21.9 | 1091.5 |
| 10 | 36 | 17 | 2.1176 | 0.5701 | +10.0% | 24.1 | 1200.1 |
| 11 | 52 | 24 | 2.1667 | 0.5833 | +2.3% | 24.6 | 1227.9 |
| 12 | 36 | 15 | 2.4000 | 0.6462 | +10.8% | 27.3 | 1360.2 |
| 13 | 52 | 21 | 2.4762 | 0.6667 | +3.2% | 28.1 | 1403.3 |
| 14 | 36 | 14 | 2.5714 | 0.6923 | +3.8% | 29.2 | 1457.3 |
| 15 | 52 | 19 | 2.7368 | 0.7368 | +6.4% | 31.1 | 1551.1 |
| 16 | 36 | 13 | 2.7692 | 0.7456 | +1.2% | 31.5 | 1569.4 |
| 17 | 36 | 12 | 3.0000 | 0.8077 | +8.3% | 34.1 | 1700.2 |
| 18 | 52 | 17 | 3.0588 | 0.8235 | +2.0% | 34.8 | 1733.5 |
| 19 | 36 | 11 | 3.2727 | 0.8811 | +7.0% | 37.2 | 1854.8 |
| 20 | 52 | 15 | 3.4667 | 0.9333 | +5.9% | 39.4 | 1964.7 |
| 21 | 52 | 14 | 3.7143 | 1.0000 | +7.1% | 42.2 | 2105.0 |
| 22 | 52 | 13 | 4.0000 | 1.0769 | +7.7% | 45.5 | 2266.9 |
| 23 | 52 | 12 | 4.3333 | 1.1667 | +8.3% | 49.3 | 2455.8 |
| 24 | 52 | 11 | 4.7273 | 1.2727 | +9.1% | 53.7 | 2679.1 |

- **Ladder rule:** the bridge builds this table at boot by computing ring ÷ cog for every pair and sorting ascending. Gear numbers are positions in the sorted list, not physical sprocket positions.
- **What "unbroken" costs:** from gear 4 to gear 19 the two rings interleave, so steps alternate between near-duplicates (+1.1% to +3.8%) and jumps of +9% to +13%. That is what a real 52-36 × 11-34 gives when every combination is used.
- **Optional smoothing:** `ladder.min_step_pct` (default 0, keep all 24) drops any gear less than that step above the last kept one. At 4% it keeps 17 gears with every step between +5.9% and +14.3%.

## Resistance physics

In virtual gear k the trainer must absorb the power the rider would need at the virtual speed k·v, while its flywheel actually turns at the physical speed v. So the brake force at the flywheel must equal k times the road force at speed k·v.

Road model, the same one FTMS simulation mode uses (θ = slope angle, Cw = ρ·CdA in kg/m as ANT+ FE-C defines it, so aero force is ½·Cw·v²; the k³ scaling below holds either way, w = headwind in m/s):

```latex
F_{road}(u) = m g \left(\sin\theta + C_{rr}\cos\theta\right) + \tfrac{1}{2} C_w \,(u + w)^2
```

At cadence c and wheel circumference L, the trainer turns at v\_p = c × 3.714 × L and the virtual bike moves at v\_v = k × v\_p. Power balance gives the brake force:

```latex
F_{brake}(v_p) = \frac{F_{road}(k\,v_p)\; k\,v_p}{v_p} = k\,F_{road}(k\,v_p) = m g\left(k\sin\theta + k\,C_{rr}\cos\theta\right) + \tfrac{1}{2}\,k^3 C_w \left(v_p + \tfrac{w}{k}\right)^2
```

A trainer running the standard model therefore produces exactly the right force if it is given these parameters:

```latex
\sin\theta' = k\sin\theta \qquad C_{rr}'\cos\theta' = k\,C_{rr}\cos\theta \qquad C_w' = k^3 C_w \qquad w' = \frac{w}{k}
```

- **Checked numerically:** at 5% grade, the transformed set reproduces the target power to within floating-point error for gears 1, 4, 12, 21 and 24.
- **Mass drops out:** every term scales by k whatever mass the trainer assumes, so the bridge never needs rider weight.
- **Zwift speed is unchanged:** Zwift derives speed from the power it receives, and that power is real. Shifting changes only how cadence trades against torque, as on a real bike.
- **Use the exact angle form:** grade' ≈ k × grade is fine below about 10%, but at 20% in gear 24 the exact value is 25.78%, not 25.45%.

## FTMS interface

The bridge is an FTMS server to Zwift and an FTMS client to the trainer: Zwift pairs with one indoor bike (default name `VS-Bridge`), and the trainer sees one controlling app. Field formats below are from the [FTMS v1.0 specification](https://community.appinventor.mit.edu/uploads/short-url/yTLhgjXECIekyCgPg0GOBz1k4Bh.pdf); all values are little-endian.

**GATT, Fitness Machine service 0x1826**

| Characteristic | UUID | Toward Zwift (server) | Toward trainer (client) |
| --- | --- | --- | --- |
| Fitness Machine Feature | 0x2ACC | Trainer's value, with Target Setting bit 13 (simulation) and bit 3 (power) set, bit 14 (wheel circumference) cleared | Read once; bits 13 and 14 pick the strategy |
| Indoor Bike Data | 0x2AD2 | Relayed unchanged: power, cadence, speed | Subscribe (notify) |
| Training Status | 0x2AD3 | Relayed | Subscribe |
| Supported Resistance Level Range | 0x2AD6 | Relayed | Read |
| Supported Power Range | 0x2AD8 | Relayed | Read |
| Fitness Machine Control Point | 0x2AD9 | Intercepted (table below) | Write + indicate; the bridge holds control from boot |
| Fitness Machine Status | 0x2ADA | Relayed, except 0x12 and 0x13 caused by the bridge's own writes | Subscribe |

**Control Point handling**

| Op code | Procedure | Parameters | Bridge behaviour |
| --- | --- | --- | --- |
| 0x00 | Request Control | none | Answered locally with Success; the bridge already owns the trainer |
| 0x01 | Reset | none | Forwarded; current gear re-applied after Success |
| 0x04 | Set Target Resistance Level | uint8, unitless, 0.1 | Forwarded unchanged |
| 0x05 | Set Target Power | sint16, W, 1 | Forwarded unchanged; mode becomes ERG (gears ignored) |
| 0x07 / 0x08 | Start or Resume / Stop or Pause | none / uint8 | Forwarded |
| 0x11 | Set Indoor Bike Simulation Parameters | wind sint16 0.001 m/s · grade sint16 0.01 % · Crr uint8 0.0001 · Cw uint8 0.01 kg/m | Stored as the road state; mode becomes SIM; the active strategy sends the trainer its own write |
| 0x12 | Set Wheel Circumference | uint16, mm, 0.1 | Owned by the bridge. From Zwift: stored as base circumference L, answered Success locally |
| other | any | any | Forwarded if the trainer advertises it, else answered 0x02 |

Every write is answered with an indication 0x80 · request op code · result (0x01 Success, 0x02 Op Code not supported, 0x03 Invalid Parameter, 0x04 Operation Failed, 0x05 Control Not Permitted). When the bridge forwards, it relays the trainer's result.

- **What Zwift sends in SIM mode:** a logged Zwift session shows frames such as `11 00 00 EE 00 28 33` = wind 0, grade +2.38%, Crr 0.0040, Cw 0.51 kg/m ([Zwift forum log](https://forums.zwift.com/t/zwift-documentation-for-interfacing-with-smart-trainers/20521)). The bridge must not assume these constants; it uses whatever arrives.
- **Timing:** a 0x11 from Zwift is answered within 100 ms; the matching trainer write goes out within 50 ms of the answer.

## Control strategies

The bridge imposes k on the trainer in one of three ways, chosen at connect time: wheel-circumference scaling when the trainer accepts it, else the parameter transform, else an equivalent grade recomputed from live speed.

| Strategy | Use when | Bridge sends to trainer | Trainer writes | Error |
| --- | --- | --- | --- | --- |
| A · Wheel circumference | Feature bit 14 set and 0x12 answered Success | Zwift's 0x11 unchanged; 0x12 = L × k (table column "Virtual circumference") | 1 per shift | None, if the trainer derives its simulated speed from circumference |
| B · Parameter transform | Bit 13 set; trainer honours the Crr and Cw it is sent | 0x11 with grade', Crr', Cw', wind' from the physics section | 1 per shift + 1 per Zwift update | Field rounding only; worst case Cw' in gear 1 rounds 0.0118 → 0.01, about 1.4 W low at 90 rpm |
| C · Equivalent grade | Trainer ignores sent Crr/Cw and uses its own constants | 0x11 with grade' recomputed from measured speed; Crr and Cw sent as the calibrated trainer values | 4 per second | Up to 250 ms lag on sprints; depends on calibration |

**Selection (`strategy = auto`)**

1. Read Fitness Machine Feature. If Target Setting bit 14 is set, send 0x12 with the base circumference L.
2. Success → Strategy A. The FTMS spec does not say what a server uses circumference for, so A stays provisional until acceptance test T3 passes for that trainer model.
3. Op Code not supported (a Tacx Flux S answers this, per a [Zwift forum test](https://forums.zwift.com/t/increase-baseline-resistance/19109/127)) or bit 14 clear → Strategy B.
4. If test T4 shows the trainer ignores Crr/Cw, pin `strategy = equivalent_grade` in config with its calibrated constants.

**Strategy B encoding rules**

- grade' = tan(asin(k·sin θ)) × 100, rounded to 0.01 %, clamped to ±`limits.max_grade_pct` (default 25).
- Crr' = k·Crr·cos θ ÷ cos θ', rounded to 0.0001, clamped 0–0.0255.
- Cw' = k³·Cw, rounded to 0.01, clamped 0.01–2.55 (never 0 when Zwift's Cw is above 0). Gear 24 gives 1.05, inside the field.
- wind' = w ÷ k, rounded to 0.001 m/s, clamped to the sint16 range.

**Strategy C formula** (v\_p = trainer speed from Indoor Bike Data; m\_t, Crr\_t, Cw\_t = the trainer's own constants from calibration; the road side uses m\_t too, so no rider weight is needed):

```latex
\sin\theta' = \frac{k\,F_{road}(k\,v_p) - \tfrac{1}{2} C_{w,t}\, v_p^2}{m_t\, g} - C_{rr,t}
```

- Speed is smoothed (exponential average, α = 0.5 at 4 Hz) before use, so resistance does not chase its own effect.
- Below 5 km/h trainer speed, grade' falls back to Strategy B's static value to avoid dividing noise at standstill.

## Shift input and gear state

Two inputs, up and down, move one step along the 24-gear ladder, and the new resistance reaches the trainer within 100 ms of the press. The bridge boots in gear 21 (52×14, k = 1), so if anything fails the bike feels exactly like its physical setup.

**Inputs** (any combination)

- BLE HID remote paired to the bridge: volume up = shift up (harder), volume down = shift down (easier).
- Two GPIO buttons on the bridge board, active low.
- Companion app or keyboard over the vendor status service (below).
- Zwift Click and Play use a proprietary protocol and are out of scope.

**Events and timing**

- `SHIFT_UP`: gear + 1, toward 52×11. `SHIFT_DOWN`: gear − 1, toward 36×34. At either end the event is dropped and the LED blinks twice.
- Debounce 30 ms. Holding a button longer than 400 ms repeats every 150 ms.
- FTMS allows one Control Point procedure in flight, so the bridge waits for each indication before the next write. Shifts that arrive meanwhile collapse into one write of the latest gear.
- No indication within 1 s: retry once, then mark the trainer link degraded and keep the gear in memory.

**Modes**

- **SIM** (after a 0x11 from Zwift): the gear is applied by the active strategy.
- **ERG** (after a 0x05): Zwift's power target is forwarded unchanged. Shifting still updates the stored gear, which is applied when SIM resumes.
- **Reconnect:** the gear survives a Zwift disconnect. After a trainer reconnect the bridge requests control, re-sends the last road state and re-applies the gear. A bridge reboot returns to gear 21.

**Vendor status service** (optional, custom 128-bit UUID): a notify characteristic carrying gear number, ring, cog and k, plus a write characteristic accepting `0x01` up, `0x02` down and `0x03 nn` jump to gear nn.

## Configuration

Everything drivetrain-specific is configuration, so a 52-35 crank, another cassette or a different physical cog needs no code change.

| Key | Default | Meaning |
| --- | --- | --- |
| `drivetrain.physical_ring` | 52 | Chainring the chain actually sits on |
| `drivetrain.physical_cog` | 14 | Trainer cog the chain actually sits on |
| `drivetrain.rings` | \[52, 36\] | Virtual chainrings; \[52, 35\] for the variant in the request |
| `drivetrain.cogs` | \[11, 12, 13, 14, 15, 17, 19, 21, 24, 27, 30, 34\] | Virtual cassette |
| `drivetrain.wheel_circumference_mm` | 2105 | Base L; replaced by Zwift's value if Zwift sends 0x12 |
| `ladder.min_step_pct` | 0 | Drop gears closer than this to the previous kept gear; 0 keeps all 24 |
| `gear.start` | identity | Gear on boot; `identity` = the gear whose k is nearest 1 (gear 21 here) |
| `strategy` | auto | `auto`, `circumference`, `transform` or `equivalent_grade` |
| `limits.max_grade_pct` | 25 | Clamp for grade' in both directions |
| `trainer.mass_kg` | — | Strategy C only, from calibration |
| `trainer.crr` | — | Strategy C only, from calibration |
| `trainer.cw_kg_per_m` | — | Strategy C only, from calibration |
| `equivalent_grade.rate_hz` | 4 | Strategy C update rate |
| `equivalent_grade.ema_alpha` | 0.5 | Strategy C speed smoothing |
| `input.debounce_ms` | 30 | Button debounce |
| `input.repeat_delay_ms` | 400 | Hold time before auto-repeat |
| `input.repeat_interval_ms` | 150 | Auto-repeat period |
| `ble.server_name` | VS-Bridge | Name Zwift sees |
| `ble.trainer_address` | empty | Trainer to connect; empty = first FTMS indoor bike found |

## Edge cases and limitations

Resistance per gear can be made exact; pedal inertia and the trainer's own limits cannot be changed over FTMS.

- **Inertia does not shift.** The flywheel is geared to the crank by the real 52×14, while a real bike's momentum felt at the crank scales with the square of the ratio. If inertia feels right in gear 21, gear 1 (k = 0.285) feels about 12 times smoother between pedal strokes than a real 36×34; gear 24 feels about 1.6 times lighter than a real 52×11.
- **52×14 helps the brake.** The flywheel always spins at big-gear speed (42 km/h equivalent at 90 rpm), even in gear 1, which is where eddy-current brakes produce the most torque on steep climbs.
- **Trainer limits win.** Grade' is clamped to 25%, and the trainer may clamp lower. A 20% Zwift grade in gear 24 asks for 25.78%, so steep climbs in big gears will feel capped. A trainer without a motor cannot push on descents.
- **Trainer Difficulty stacks.** Zwift's Trainer Difficulty setting already scales the grade it sends, and the bridge applies k on top. 100% gives the closest match to a real bike.
- **One controller only.** Zwift must pair to the bridge for power, cadence and controllable trainer, never to the trainer directly. The trainer's own app must be disconnected, or one of them gets Control Not Permitted.
- **No gear on Zwift's screen.** Zwift shows its own gear display only for its native virtual shifting, so gear feedback comes from the bridge's LED, display or vendor service.
- **Speed shown by other apps.** Zwift derives speed from power in SIM mode. Apps that display the trainer's speed field see physical-gear speed under Strategy B or C, and possibly virtual speed under Strategy A.

## Acceptance tests

The bridge passes when gear 21 is transparent, measured power in other gears matches the physics within ±5%, and shifts land within 100 ms. Power tests hold cadence steady for 30 s and average the last 20 s.

- [ ] **T1 · Ladder.** The boot table equals the Gear model table exactly: 24 rows, same order, ratio to 4 decimals.
- [ ] **T2 · Transparent at k = 1.** Gear 21, Zwift grade 0% then 5%, 80 rpm: power through the bridge is within ±2% of the trainer paired to Zwift directly.
- [ ] **T3 · Power per gear, flat.** Zwift on 0% with Crr 0.004, Cw 0.51, wind 0, at 90 rpm. Expected power below assumes the trainer models an 85 kg system; adjust the rolling share by the stated watts per 10 kg.
- [ ] **T4 · Does the trainer honour Crr and Cw?** Bridge in pass-through, gear 21, 0% grade, 70 rpm. Cw 0.51 → 0.25 must drop power by about 99 W (224 → 125 W); Crr 0.004 → 0.008 must raise it by about 30 W. No change in either → Strategy C.
- [ ] **T5 · Climb.** Zwift grade 5%, 70 rpm: gear 1 ≈ 121 W, gear 4 ≈ 178 W, gear 8 ≈ 235 W, gear 12 ≈ 317 W (85 kg; gravity dominates, so scale by trainer mass).
- [ ] **T6 · Shift latency.** 50 single shifts: button edge to Control Point write ≤ 100 ms each, from the bridge log.
- [ ] **T7 · Burst.** Ten up-presses within 1 s end in gear 21 + 10 clamped to 24, with no Control Point error and the trainer in the final gear.
- [ ] **T8 · ERG.** Start a Zwift workout: the trainer's power target equals Zwift's at any gear; shifting changes nothing until the free-ride resumes, then the stored gear applies.
- [ ] **T9 · Reconnect.** Power-cycle the trainer mid-ride: within 5 s of it advertising, the bridge holds control again with the last road state and gear applied.
- [ ] **T10 · Calibration (Strategy C only).** In pass-through at 0% grade, ride 20, 30 and 40 km/h and fit P = a·v + b·v³: a = Crr\_t·m\_t·g, b = ½·Cw\_t. Then ride 5% at 20 km/h; the power rise over flat gives m\_t.

**T3 expected power** (flat, 90 rpm)

| Gear | Ring × cog | Virtual speed (km/h) | Expected power (W) | Rolling share (W per 10 kg) |
| --- | --- | --- | --- | --- |
| 1 | 36 × 34 | 12.0 | 21 | 1.3 |
| 8 | 36 × 19 | 21.5 | 75 | 2.3 |
| 12 | 36 × 15 | 27.3 | 136 | 3.0 |
| 17 | 36 × 12 | 34.1 | 248 | 3.7 |
| 21 | 52 × 14 | 42.2 | 450 | 4.6 |
| 24 | 52 × 11 | 53.7 | 898 | 5.9 |

At 90 rpm gear 24 needs about 900 W, so test it as a short effort or at 60 rpm (expected power scales close to the cube of cadence on the flat).
