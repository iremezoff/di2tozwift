# DirCon Proxy with Virtual Shimano Shifting — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS command-line tool, `dirconproxy`, that holds the Bluetooth link to a Magene T600, serves it to Zwift on the same Mac over DirCon, and adds 24 virtual Shimano gears shifted from the terminal keyboard.

**Architecture:** A SwiftPM package with a testable library (`DirConCore`) and a thin executable (`dirconproxy`). Protocol logic (DirCon frames, GATT filtering, FTMS, mDNS messages, gears and physics, request handling) is pure and unit-tested; I/O (CoreBluetooth, `NWListener`, the UDP 5353 socket, the terminal) sits in thin adapters. Everything runs on one serial `DispatchQueue`. Virtual shifting is an `Interceptor` in the pipeline.

**Tech Stack:** Swift 6.1 toolchain in Swift 5 language mode, macOS 13+, CoreBluetooth, Network.framework, BSD sockets for mDNS, swift-argument-parser ≥ 1.3, Swift Testing (`import Testing`; XCTest is not available with the installed Command Line Tools).

**Spec:** `docs/superpowers/specs/2026-11-06-dircon-virtual-shifting-design.md`, which defers to `DirCon Trainer Proxy for macOS — Implementation Spec.md` (the "proxy spec") and `Virtual Shimano 2×12 Shifting over FTMS — Specification.md` (the "shifting spec") in the repo root. Read all three before starting. Section names below refer to them.

## Global Constraints

- Package root: `/Users/iremezoff/di2bikecontrol` (next to the existing `di2dfly.*` files, which stay untouched). Products: library `DirConCore`, executable `dirconproxy`, test target `DirConCoreTests`.
- `swift-tools-version:5.9`, `platforms: [.macOS(.v13)]`, every target sets `swiftSettings: [.swiftLanguageMode(.v5)]` (or `-swift-version 5`), because CoreBluetooth delegates don't fit Swift 6 strict concurrency.
- Executable embeds `Info.plist` via `linkerSettings: [.unsafeFlags(["-Xlinker","-sectcreate","-Xlinker","__TEXT","-Xlinker","__info_plist","-Xlinker","Info.plist"])]`; plist keys exactly as the proxy spec's "Embedded Info.plist" table, `CFBundleIdentifier` = `com.iremezoff.dirconproxy`.
- One serial queue owns all state; no locks. Every public core type documents "call on the core queue".
- All multi-byte FTMS values little-endian; DirCon header length big-endian; UUIDs on the DirCon wire in textual left-to-right byte order.
- Limits (proxy spec "Limits"): BLE op timeout 2 s, reconnect window 30 s, max DirCon data length 512, max clients 4. Shifting: CP indication timeout 1 s with one retry.
- DirCon port 36866; service type `_wahoo-fitness-tnp._tcp`; instance `DirCon Proxy <last 4 hex of trainer id>`; host `dirconproxy-<same 4 hex>.local`.
- Status lines go to stderr, one per state change, exactly in the proxy spec's style (`trainer ready: T600_35381`, `client connected 192.168.1.20:52144`, `control granted`). While scanning or reconnecting: `trainer not found: spin the trainer to wake it`. On every gear change: `gear 14/24  36×14  k=0.692` (two spaces between fields, `×` U+00D7, k to 3 decimals).
- Exit codes: 0 normal, 1 usage/config, 2 Bluetooth off/unauthorized, 3 network (port in use, no IPv4).
- Commits: the folder is not a git repo yet. Run commit steps only if the user approved `git init`; otherwise skip them. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Hardware: the trainer sleeps when idle. If a hardware step can't find it or loses it, ask the user to spin the trainer before retrying.

## Review Focus

1. **Descents and odd road values.** Negative grades, grades beyond ±25 %, and Zwift sending Cw = 0 or Crr = 0 must give a valid, clamped 0x11 with the right sign; gear 21 must still reproduce Zwift's exact bytes. Test in Task 4 (`transformNegativeGrade`, `transformZeroCw`, `identityGearIsByteExact`).
2. **Trainer rejects a write the proxy made itself** (`80 11 03` or `80 11 04` after a shift). Zwift must not see it, the gear must stay, and the next road update must still be sent. Test in Task 6 (`ownWriteRejectedIsSwallowed`).
3. **Zwift quits and comes back mid-ride.** Control ownership is released on disconnect, the new client's Request Control is answered at once, and the stored gear and road state survive. Test in Task 5 (`ownerDisconnectReleasesControl`) and Task 6 (`gearSurvivesClientReconnect`).
4. **The terminal must be restored.** After Ctrl-C, SIGTERM, a crash path through `exit()`, or when stdin is not a TTY (launch agent), the terminal is never left in raw mode and keyboard input is simply off. Manual check in Task 10, step "terminal restore".
5. **Network not ready at start, or changing.** Port 36866 already taken or no IPv4 address exits with code 3 and a clear message; an IPv4 change during a ride re-announces mDNS. Test in Task 8 (`portInUseFails`) and manual check in Task 7.

---

### Task 1: Package scaffold, UUIDs and the DirCon codec

**Files:**
- Create: `Package.swift`, `Info.plist`, `.gitignore` (`.build/`, `.venv/`, `__pycache__/`)
- Create: `Sources/DirConCore/BLEUUID.swift`, `Sources/DirConCore/DirConCodec.swift`
- Create: `Sources/dirconproxy/main.swift` (placeholder that prints usage; replaced in Task 10)
- Test: `Tests/DirConCoreTests/DirConCodecTests.swift`

**Interfaces:**
- Produces:
  - `struct BLEUUID: Hashable, CustomStringConvertible` with `let bytes: [UInt8]` (16, textual order), `init(short: UInt16)`, `init?(string: String)` (accepts `"2AD9"`, `"0x2AD9"` and full 36-char form), `init?(bytes: some Collection<UInt8>)`, `var short: UInt16?` (non-nil only on the SIG base `0000xxxx-0000-1000-8000-00805F9B34FB`), `var isSIGBase: Bool`.
  - `enum MessageType: UInt8 { discoverServices = 1, discoverCharacteristics, readCharacteristic, writeCharacteristic, enableNotifications, notification }`.
  - `enum ResponseCode: UInt8 { success = 0, invalidMessageType, genericError, serviceNotFound, characteristicNotFound, operationNotSupported, writeFailed }`.
  - `struct Frame: Equatable { var type: UInt8; var seq: UInt8; var code: UInt8; var data: Data }` (version is always 1), `func encoded() -> Data`.
  - `struct FrameParser { mutating func append(_ data: Data) throws -> [Frame] }`, throwing `FrameError.badVersion(UInt8)` / `.tooLong(Int)` for version ≠ 1 or length > 512.
  - `enum DirConRequest: Equatable { case discoverServices, discoverCharacteristics(BLEUUID), read(BLEUUID), write(BLEUUID, Data), enableNotifications(BLEUUID, Bool) }` with `static func decode(_ f: Frame) -> DirConRequest?` (nil for unknown types or short data).
  - Response builders: `Frame.response(to: Frame, code: ResponseCode, data: Data = Data())` and `Frame.notification(_ uuid: BLEUUID, _ value: Data, seq: UInt8 = 0)`.

- [ ] **Step 1: Write the package.** Two targets plus the test target as in Global Constraints; dependency `swift-argument-parser` from `1.3.0`, used only by the executable.
- [ ] **Step 2: Write the failing tests** in `DirConCodecTests.swift`, all built from the proxy spec's "Byte examples":
  - `discoverServicesRoundTrip`: parsing `01 01 01 00 00 00` gives `Frame(type: 1, seq: 1, code: 0, data: [])`; the response with FTMS and Cycling Power encodes to exactly `01 01 01 00 00 20` + the two 16-byte UUIDs from the spec.
  - `enableNotificationsDecode`: `01 05 05 00 00 11 <2AD2 uuid> 01` decodes to `.enableNotifications(BLEUUID(short: 0x2AD2), true)`.
  - `controlPointIndicationEncode`: `Frame.notification(BLEUUID(short: 0x2AD9), [0x80, 0x00, 0x01])` encodes to `01 06 00 00 00 13 <2AD9 uuid> 80 00 01`.
  - `splitFrame`: the 23-byte write frame fed in two pieces (10 + 13 bytes) yields nothing, then exactly one frame.
  - `twoFramesInOneRead`: two frames concatenated yield two frames in order.
  - `oversizedLengthThrows`: header with length 513 throws `.tooLong(513)`; version 2 throws `.badVersion(2)`.
  - `uuidForms`: `BLEUUID(string: "0x1826") == BLEUUID(short: 0x1826)`, `BLEUUID(string: "8ce5cc01-0a4d-11e9-ab14-d663bd873d93")!.isSIGBase == false`.
- [ ] **Step 3: Run** `swift test --filter DirConCodecTests`. Expected: compile failure (types not defined).
- [ ] **Step 4: Implement** `BLEUUID.swift` and `DirConCodec.swift`.
- [ ] **Step 5: Run** `swift test --filter DirConCodecTests`. Expected: all pass. Also `swift build` succeeds.
- [ ] **Step 6: Commit** `feat: package scaffold and DirCon codec`.

### Task 2: GATT model (allowlist, properties, lookup)

**Files:**
- Create: `Sources/DirConCore/GattModel.swift`
- Test: `Tests/DirConCoreTests/GattModelTests.swift`, `Tests/DirConCoreTests/Fixtures.swift`

**Interfaces:**
- Consumes: `BLEUUID` (Task 1).
- Produces:
  - `struct CharProps: OptionSet { read, write, writeWithoutResponse, notify, indicate }`.
  - `struct GattCharacteristic { let uuid: BLEUUID; let props: CharProps }`, `struct GattService { let uuid: BLEUUID; let characteristics: [GattCharacteristic] }`.
  - `struct CharacteristicID: Hashable { let service: BLEUUID; let characteristic: BLEUUID }`.
  - `struct GattModel { init(services: [GattService], log: (String) -> Void = { _ in }) }` with `var exposedServices: [BLEUUID]`, `func characteristics(of service: BLEUUID) -> [(uuid: BLEUUID, dirconProps: UInt8)]?` (nil = hidden/unknown), `func resolve(_ characteristic: BLEUUID) -> CharacteristicID?`, `func props(_ id: CharacteristicID) -> CharProps?`, `static func dirconProperties(_ p: CharProps) -> UInt8`, `static let allowlist: [UInt16] = [0x1826, 0x1818, 0x1816, 0x180D, 0x180A]`.
  - Test fixture `Fixtures.t600Services: [GattService]`: exactly the T600 table in the design document (all five services with their characteristics and properties as read on Nov 6), plus `Fixtures.t600Feature = Data([0x02,0x40,0x00,0x00,0x08,0x20,0x00,0x00])`.

- [ ] **Step 1: Write the failing tests:**
  - `hidesVendorService`: with the T600 fixture, `exposedServices` == `[0x180A, 0x1826, 0x1818, 0x1816]` in trainer order and never contains `8ce5cc01-…`.
  - `propertyMapping`: 0x2AD9 → `0x06`, 0x2AD2 → `0x04`, 0x2ACC → `0x01`, 0x2A55 (indicate + write) → `0x06`.
  - `duplicateCharacteristicFirstWins`: `resolve(0x2A5D)` returns the Cycling Power one (first in trainer order), and the log closure received one line containing `2A5D`.
  - `vendorCharacteristicInsideAllowedServiceHidden`: a Cycling Power service with an extra 128-bit characteristic exposes only the SIG ones.
  - `unknownServiceIsNil`: `characteristics(of: <vendor uuid>) == nil`.
- [ ] **Step 2: Run** `swift test --filter GattModelTests`. Expected: FAIL (not defined).
- [ ] **Step 3: Implement** `GattModel.swift` per the proxy spec's "Filtering rules", "UUID handling" and "Property mapping".
- [ ] **Step 4: Run** `swift test --filter GattModelTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: GATT allowlist model`.

### Task 3: FTMS codecs

**Files:**
- Create: `Sources/DirConCore/FTMS.swift`
- Test: `Tests/DirConCoreTests/FTMSTests.swift`

**Interfaces:**
- Consumes: `BLEUUID`, `CharacteristicID`.
- Produces:
  - `enum FTMSUUID` with `static let service, feature, indoorBikeData, trainingStatus, resistanceRange, powerRange, controlPoint, status: BLEUUID` (0x1826, 0x2ACC, 0x2AD2, 0x2AD3, 0x2AD6, 0x2AD8, 0x2AD9, 0x2ADA).
  - `struct SimParams: Equatable { var windRaw: Int16; var gradeRaw: Int16; var crrRaw: UInt8; var cwRaw: UInt8 }` with computed `windMS`, `gradePct`, `crr`, `cw` (units per the proxy spec's op code table).
  - `enum ControlCommand: Equatable { case requestControl, reset, setTargetResistance(UInt8), setTargetPower(Int16), startResume, stopPause(UInt8), simulation(SimParams), wheelCircumference(UInt16), other(op: UInt8, params: Data) }` with `init?(_ data: Data)`, `var opCode: UInt8`, `func encoded() -> Data`. Malformed known ops (wrong length) decode as `.other`.
  - `struct ControlResponse: Equatable { let requestOp: UInt8; let result: UInt8 }`, `init?(_ data: Data)` (needs `0x80` first), `func encoded() -> Data`, result constants `success = 1, notSupported = 2, invalidParameter = 3, failed = 4, notPermitted = 5`.
  - `struct IndoorBikeData { var speedKmh: Double?; var cadenceRpm: Double?; var powerW: Int?; var heartRate: Int? }`, `init?(_ data: Data)`: walks the flags table in the proxy spec, ignores trailing bytes beyond the flagged fields, returns nil only if a flagged field is cut off.
  - `enum FeatureBits { static func forZwift(_ trainer: Data) -> Data; static func targetSettings(_ v: Data) -> UInt32 }`: `forZwift` sets target-setting bits 13 and 3 and clears bit 14, leaves machine features untouched.
  - `func describe(_ cmd: ControlCommand) -> String` for logs, e.g. `SIM wind 0.000 m/s grade 2.38% Crr 0.0040 Cw 0.51`.

- [ ] **Step 1: Write the failing tests:**
  - `decodeZwiftSim`: `11 00 00 EE 00 28 33` → `.simulation`, gradePct 2.38, crr 0.0040, cw 0.51, windMS 0; `encoded()` returns the same 7 bytes.
  - `decodeTargetPower`: `05 96 00` → `.setTargetPower(150)`.
  - `controlResponse`: `80 00 01` → requestOp 0, result 1.
  - `t600IndoorBikeData`: `44002f01000000003d00000019002409151615` → speed 3.03 km/h, cadence 0, power 0 (trailing bytes ignored).
  - `featureForZwift`: `forZwift(Fixtures.t600Feature)` == `02 40 00 00 08 20 00 00` (T600 already has 3 and 13, bit 14 clear); and for `00 00 00 00 00 60 00 00` (bits 13 and 14) → `00 00 00 00 08 20 00 00`.
  - `malformedSimIsOther`: `11 00 00` → `.other(op: 0x11, …)`.
- [ ] **Step 2: Run** `swift test --filter FTMSTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `FTMS.swift`.
- [ ] **Step 4: Run** `swift test --filter FTMSTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: FTMS command and data codecs`.

### Task 4: Gear ladder and resistance physics

**Files:**
- Create: `Sources/DirConCore/GearLadder.swift`, `Sources/DirConCore/Physics.swift`
- Test: `Tests/DirConCoreTests/GearLadderTests.swift`, `Tests/DirConCoreTests/PhysicsTests.swift`

**Interfaces:**
- Consumes: `SimParams` (Task 3).
- Produces:
  - `struct Gear: Equatable { let number: Int; let ring: Int; let cog: Int; let ratio: Double; let k: Double }`.
  - `struct GearLadder { init(rings: [Int], cogs: [Int], physicalRing: Int, physicalCog: Int, minStepPct: Double = 0); let gears: [Gear]; var identityIndex: Int; func statusLine(_ g: Gear) -> String }` (format in Global Constraints). Sort ascending by ratio; ties keep ring order as given. `minStepPct` drops gears per the shifting spec's "Optional smoothing".
  - `struct RoadState: Equatable { var windMS, gradePct, crr, cw: Double }` with `init(_ p: SimParams)`.
  - `enum Physics { static let g = 9.81; static func roadForce(speed u: Double, road: RoadState, massKg: Double) -> Double; static func transform(_ r: RoadState, k: Double) -> RoadState; static func strategyB(_ r: RoadState, k: Double, maxGradePct: Double) -> SimParams; static func trainerSpeed(cadenceRpm: Double, ratio: Double, circumferenceMM: Double) -> Double }` (m/s). `transform` is the exact, unrounded form from "Resistance physics"; `strategyB` applies it and then the shifting spec's "Strategy B encoding rules" (rounding, clamps; Cw' clamped to ≥ 0.01 only when the input Cw > 0).

- [ ] **Step 1: Write the failing tests:**
  - `ladderMatchesTable` (shifting test T1): with defaults (rings [52, 36], cogs [11,12,13,14,15,17,19,21,24,27,30,34], physical 52×14), 24 gears whose (ring, cog) sequence is exactly the Gear model table's, rows 1…24; ratio and k to 4 decimals for gears 1 (1.0588, 0.2851), 5 (1.5294, 0.4118), 21 (3.7143, 1.0000), 24 (4.7273, 1.2727); `identityIndex` → gear 21.
  - `minStepFourPercentKeeps17`: `minStepPct: 4` gives 17 gears, every step between +5.9 % and +14.3 %.
  - `statusLineFormat`: gear 14 → `gear 14/24  36×14  k=0.692`.
  - `transformReproducesPower` (physics "Checked numerically"): road 5 % grade, Crr 0.004, Cw 0.51, wind 0, mass 85, v_p = trainerSpeed(90 rpm, 52/14, 2105); for gears 1, 4, 12, 21, 24, `roadForce(v_p, transform(road, k)) * v_p` equals `roadForce(k·v_p, road) * k·v_p` within 1e-9 relative.
  - `flatGear21Is450W` (T3 row): flat, Crr 0.004, Cw 0.51, 85 kg, 90 rpm, gear 21 → 450 W ± 1.
  - `steepGrade24ClampsTo25`: 20 % in gear 24: unclamped grade' 25.78 % ± 0.01 (`transform` + angle math); `strategyB(…, maxGradePct: 25)` gives `gradeRaw == 2500`.
  - `cwRounding`: Cw 0.51 in gear 24 → `cwRaw == 105`; in gear 1 → `cwRaw == 1`.
  - `transformNegativeGrade`: −8 % in gear 1 gives a negative `gradeRaw` equal to `round(tan(asin(k·sin θ))·10000)`; −40 % clamps to −2500.
  - `transformZeroCw`: Cw 0 stays `cwRaw == 0`; Crr 0 stays `crrRaw == 0`.
  - `identityGearIsByteExact`: for the Zwift frame `11 00 00 EE 00 28 33` and k = 1, `strategyB(...)` equals the decoded `SimParams` exactly.
- [ ] **Step 2: Run** `swift test --filter "GearLadderTests|PhysicsTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat: gear ladder and FTMS parameter transform`.

### Task 5: Trainer abstraction, simulated trainer, pipeline and request handling

The heart of the proxy: `ProxyCore` answers DirCon requests from several clients using a `TrainerLink` and the pipeline. Tested entirely with the simulated trainer.

**Files:**
- Create: `Sources/DirConCore/TrainerLink.swift` (protocol, state, errors), `Sources/DirConCore/SimulatedTrainer.swift`, `Sources/DirConCore/Pipeline.swift` (Verdict, Interceptor, ProxyControl, Scheduler, built-in interceptors), `Sources/DirConCore/ProxyCore.swift`
- Test: `Tests/DirConCoreTests/ProxyCoreTests.swift`, `Tests/DirConCoreTests/TestScheduler.swift`

**Interfaces:**
- Consumes: Tasks 1–3, and `Physics` (Task 4) for the simulated trainer.
- Produces:
  - `enum TrainerState: Equatable { case scanning, connecting, ready, reconnecting, offline }`; `enum TrainerError: Error { case timeout, offline, failed(String) }`.
  - `protocol TrainerLinkDelegate: AnyObject { func trainerStateChanged(_ s: TrainerState); func trainerValue(_ value: Data, for id: CharacteristicID) }`.
  - `protocol TrainerLink: AnyObject { var delegate: TrainerLinkDelegate? { get set }; var state: TrainerState { get }; var name: String { get }; var identifier: String { get }; var services: [GattService] { get }; func cachedValue(_ id: CharacteristicID) -> Data?; func start(); func stop(); func read(_ id: CharacteristicID, completion: @escaping (Result<Data, TrainerError>) -> Void); func write(_ id: CharacteristicID, _ value: Data, completion: @escaping (Result<Void, TrainerError>) -> Void); func setNotify(_ id: CharacteristicID, _ on: Bool) }`. Implementations call completions and the delegate on the core queue. Control Point indications are always on and are not managed through `setNotify`.
  - `protocol Scheduler { func after(_ seconds: Double, _ work: @escaping () -> Void) -> Cancellable }` with `DispatchScheduler(queue:)` for production and `TestScheduler` (manual `advance(by:)`) for tests; `protocol Cancellable { func cancel() }`.
  - `final class SimulatedTrainer: TrainerLink` — `init(queue: DispatchQueue, scheduler: Scheduler, cadenceRpm: Double = 85, massKg: Double = 85)`. Exposes `Fixtures`-equivalent T600 services and feature value (move the T600 table into `SimulatedTrainer.t600Services` and have the test fixture reuse it). Answers every Control Point write with `80 op 01`, except 0x12 → `80 12 02` (no bit 14, like the T600). Sends Indoor Bike Data at 4 Hz while subscribed: cadence fixed; power = target in ERG, else `roadForce(v_p, lastSim, mass) · v_p` with v_p from 52×14 and 2105 mm. `func simulateDisconnect()` / `simulateReconnect()` for tests. Records every write in `var writes: [(CharacteristicID, Data)]`.
  - `enum Verdict { case forward(Data), drop, reply(ResponseCode) }`.
  - `protocol Interceptor: AnyObject { func attach(_ control: ProxyControl); func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict; func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict; func readResult(_ ch: CharacteristicID, _ value: Data) -> Data; func trainerStateChanged(_ s: TrainerState); func clientDisconnected(_ client: ClientID) }` with default implementations that pass through. (Two hooks added to the proxy spec's protocol, `trainerStateChanged` and `clientDisconnected`, because shifting needs them; `sendToTrainer` uses a completion instead of `async` to stay on the serial queue.)
  - `protocol ProxyControl: AnyObject { func sendToTrainer(_ ch: CharacteristicID, _ value: Data, completion: @escaping (Result<Void, TrainerError>) -> Void); func notifyClients(_ ch: CharacteristicID, _ value: Data); func cachedValue(_ ch: CharacteristicID) -> Data?; var scheduler: Scheduler { get } }`. `notifyClients` on the Control Point goes to the controlling client only; on other characteristics, to subscribers.
  - Built-in interceptors: `LoggingInterceptor(log:)` (decodes CP commands, CP responses, IBD and status 0x12/0xFF), `GradeScaleInterceptor(factor:)`, `ErgCapInterceptor(maxW:)`, `PowerOffsetInterceptor(offsetW:)`.
  - `typealias ClientID = Int`; `final class ProxyCore: TrainerLinkDelegate { init(trainer: TrainerLink, interceptors: [Interceptor], queue: DispatchQueue, scheduler: Scheduler, notificationSeq: NotificationSeq = .zero, status: @escaping (String) -> Void, log: @escaping (String) -> Void); func clientConnected(_ c: ClientID, send: @escaping (Data) -> Void) -> Bool /* false when 4 clients already */; func clientDisconnected(_ c: ClientID); func receive(_ data: Data, from c: ClientID); var onCloseClient /* core asks the server to close a client */: ((ClientID) -> Void)?; var onTrainerStateChange: ((TrainerState) -> Void)? }`. `enum NotificationSeq { case zero, counter }`.

Behaviour to implement (all from the proxy spec): request handling and response codes per "Message types", "Response codes" and "Rules"; one request at a time per client, writes answered only after the BLE write completes; subscription reference counts ("Subscriptions"); control ownership and `80 <op> 05` for non-owners ("Clients and control"); everything under "While reconnecting" and "Control-state replay after reconnect" (the core replays only Control Point commands that actually reached the trainer through the pipeline; with shifting on, those are the forwarded ERG ones).

- [ ] **Step 1: Write the failing tests** (each builds a `ProxyCore` over a `SimulatedTrainer` on a test queue with `TestScheduler`, feeds raw frames, and asserts on the frames sent back):
  - `discoverServicesListsAllowedOnly`: response lists 0x180A, 0x1826, 0x1818, 0x1816.
  - `discoverCharacteristicsHiddenServiceIs3`: vendor service → code 3, empty data.
  - `unknownTypeIs1`, `readUnknownCharIs4`, `writeReadOnlyIs5`.
  - `readStaticUsesCache`: read 0x2ACC returns the T600 feature without a new BLE read.
  - `writeAnsweredAfterBLE`: Request Control → DirCon response with seq echoed, followed by notification `80 00 01` to that client even though it never enabled 0x2AD9.
  - `subscriptionRefCount`: two clients enable 0x2AD2 → one `setNotify(true)`; first disables → none; second disconnects → `setNotify(false)`.
  - `secondClientNotPermitted`: client B writes 0x05 after A owns control → DirCon success to B, notification `80 05 05` to B, trainer never sees it.
  - `ownerDisconnectReleasesControl`: A disconnects; B's Request Control succeeds and B gets `80 00 01`.
  - `reconnectingQueuesNewestPerOp`: during `.reconnecting`, two 0x05 writes get success; after `simulateReconnect()` the trainer receives `00`, then only the newer 0x05, and the client gets exactly one `80 05 01` (replayed Request Control result swallowed).
  - `fifthClientRefused`: `clientConnected` returns false for the 5th.
- [ ] **Step 2: Run** `swift test --filter ProxyCoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the four files.
- [ ] **Step 4: Run** `swift test`. Expected: all tests so far PASS.
- [ ] **Step 5: Commit** `feat: proxy core, pipeline and simulated trainer`.

### Task 6: Virtual shifting interceptor and shift input

**Files:**
- Create: `Sources/DirConCore/VirtualShifting.swift`, `Sources/DirConCore/ShiftInput.swift`
- Test: `Tests/DirConCoreTests/VirtualShiftingTests.swift`

**Interfaces:**
- Consumes: `Interceptor`, `ProxyControl`, `Scheduler` (Task 5); `GearLadder`, `Physics` (Task 4); FTMS types (Task 3).
- Produces:
  - `enum ShiftDirection { case up, down }`; `protocol ShiftInput: AnyObject { var onShift: ((ShiftDirection) -> Void)? { get set }; func start(); func stop() }`.
  - `struct ShiftingConfig: Codable, Equatable` with the shifting spec's "Configuration" keys that apply (`physical_ring`, `physical_cog`, `rings`, `cogs`, `wheel_circumference_mm`, `min_step_pct`, `start` (`"identity"` or a gear number), `strategy` (`auto | circumference | transform`), `max_grade_pct`, `repeat_interval_ms`) plus `enabled` (default true), with the spec's defaults; snake_case JSON keys.
  - `final class VirtualShifting: Interceptor { init(config: ShiftingConfig, status: @escaping (String) -> Void, log: @escaping (String) -> Void); func shift(_ d: ShiftDirection); var gear: Gear { get }; var strategy: Strategy { get } }`, `enum Strategy { case undecided, circumference, transform }`.

Behaviour (shifting spec "Control Point handling", "Control strategies", "Shift input and gear state", design "How the two specs combine"):
- On `trainerStateChanged(.ready)`: write Request Control; then, if feature bit 14 is set and strategy is `auto`/`circumference`, probe with 0x12 = L; success → `.circumference`, otherwise `.transform`; then apply the current gear if a road state is known.
- Zwift's 0x00 → `.reply(.success)` + notify `80 00 01`. 0x11 → store road state, mode SIM, `.reply(.success)` + notify `80 11 01`, schedule an apply. 0x12 → store base L, `.reply(.success)` + notify `80 12 01`, schedule an apply. 0x05 → mode ERG, `.forward`. Everything else → `.forward`.
- Apply = one Control Point write the interceptor owns: transform → `strategyB(road, k)`; circumference → Zwift's 0x11 unchanged when the road changed, `0x12 = L·k` when the gear changed. One write in flight; requests that arrive meanwhile collapse into the latest state; wait for the trainer's `80` indication (1 s timeout, one retry, then status `trainer link degraded`, keep the gear).
- `trainerValue`: drop `80 <op> x` that answers the interceptor's own in-flight write (any result, logged when not success); drop Fitness Machine Status 0x12/0x13 that arrive while its own write is in flight or within 1 s after; pass everything else.
- `readResult` on 0x2ACC → `FeatureBits.forZwift`.
- `shift`: move one gear, clamp at the ends (drop + log `gear limit`), print `ladder.statusLine(gear)` via `status`, then apply if in SIM; in ERG only store.
- Boot gear from `start`; survives client disconnects; on trainer reconnect the `.ready` sequence above re-applies.

- [ ] **Step 1: Write the failing tests** (ProxyCore + SimulatedTrainer + VirtualShifting, TestScheduler):
  - `requestControlAnsweredLocally`: Zwift's `00` → `80 00 01`; the trainer saw exactly one `00` (the interceptor's own at ready).
  - `gear21IsTransparent`: Zwift `11 00 00 EE 00 28 33` → trainer receives exactly those bytes.
  - `shiftDownSendsTransformed`: after the SIM frame, `shift(.down)` ×7 → gear 14 status line printed; trainer's last write equals `strategyB(road, k: 0.6923…, 25).encoded()`.
  - `burstCollapses` (shifting T7): ten `shift(.up)` from gear 21 while the first write is unanswered → gear 24, at most two trainer writes after the SIM write, last one for gear 24, no CP error seen by Zwift.
  - `ergIgnoresGears` (T8): `05 96 00` forwarded unchanged; shifts in ERG cause no trainer writes; the next `11` applies the stored gear.
  - `ownWriteRejectedIsSwallowed`: simulated trainer answers the shift's write with `80 11 04`; Zwift receives nothing for it; gear unchanged; the next Zwift `11` still produces a trainer write.
  - `noIndicationRetriesOnceThenDegraded`: trainer silent → one retry after 1 s, then status `trainer link degraded`.
  - `featureReadRewritten`: Zwift read of 0x2ACC returns `FeatureBits.forZwift`.
  - `wheelCircumferenceOwned`: Zwift `12 3A 52` (2105.0 mm) → answered `80 12 01` locally, trainer never sees it, base L becomes 2105.0.
  - `gearSurvivesClientReconnect`: Zwift client disconnects and reconnects; gear unchanged; its Request Control answered at once.
  - `reconnectReappliesGear` (T9 in simulation): `simulateDisconnect()` + `simulateReconnect()` → trainer receives `00` then the transformed `11` for the current gear.
  - `statusOnlyFromOwnWritesDropped`: status `12 …` arriving 200 ms after an own write is dropped; one arriving with no own write in the last second is forwarded.
- [ ] **Step 2: Run** `swift test --filter VirtualShiftingTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `VirtualShifting.swift` and `ShiftInput.swift` (protocol only).
- [ ] **Step 4: Run** `swift test`. Expected: all PASS.
- [ ] **Step 5: Commit** `feat: virtual shifting interceptor`.

### Task 7: mDNS messages and responder

**Files:**
- Create: `Sources/DirConCore/DNSMessage.swift` (pure encode/parse), `Sources/DirConCore/MDNSResponder.swift` (socket, announcements, goodbyes, path monitor), `Sources/DirConCore/BonjourAdvertiser.swift`, `Sources/DirConCore/NetworkInfo.swift` (active interface IPv4 and MAC via `getifaddrs`)
- Test: `Tests/DirConCoreTests/DNSMessageTests.swift`

**Interfaces:**
- Produces:
  - `struct ServiceRecords { var instance: String; var host: String; var port: UInt16; var ipv4: [UInt8]; var txt: [String: String] }` and `struct TXTFormat: Codable { var serviceUUIDs: String = "0x1826,0x1818"; var macSeparator: String = "-" }` (formats configurable, proxy spec "Risks").
  - `struct DNSQuestion: Equatable { let name: String; let type: UInt16; let unicastResponse: Bool }`; `enum DNSMessage { static func parseQuestions(_ packet: Data) -> (id: UInt16, isQuery: Bool, questions: [DNSQuestion])?; static func response(for records: ServiceRecords, ttlScale: Double = 1) -> Data /* PTR, SRV, TXT, A all in Answers, TTLs 4500/120/4500/120, ttlScale 0 → goodbye */; static func shouldAnswer(_ q: DNSQuestion, records: ServiceRecords) -> Bool }`. Parser must follow name-compression pointers.
  - `protocol Advertiser: AnyObject { func start(_ records: ServiceRecords) throws; func update(_ records: ServiceRecords); func stop() /* sends goodbyes */ }`; `final class MDNSResponder: Advertiser` (UDP 5353, `SO_REUSEADDR` + `SO_REUSEPORT`, joins 224.0.0.251, `IP_MULTICAST_LOOP` on, three announcements 1 s apart, QU → unicast reply, `NWPathMonitor` re-announce) and `final class BonjourAdvertiser: Advertiser` (registers via `NWListener.Service` on the DirCon listener; never both).
  - `enum NetworkInfo { static func activeIPv4() -> (interface: String, address: [UInt8], mac: [UInt8])? }`.

- [ ] **Step 1: Write the failing tests:**
  - `responseHasFourAnswers`: header ANCOUNT 4, ARCOUNT 0; record types in order PTR, SRV, TXT, A; SRV port 36866 and target host `dirconproxy-<4 hex>.local`; TXT contains `serial-number=…`, `mac-address=…`, `ble-service-uuids=0x1826,0x1818`.
  - `goodbyeHasZeroTTL`: `ttlScale: 0` → all four TTLs 0.
  - `parsesCompressedQuery`: a query with the PTR question `_wahoo-fitness-tnp._tcp.local` and a second question using a compression pointer parses to two questions; the QU bit is read from the class field.
  - `ignoresOtherServices`: `_zap._tcp.local` PTR → `shouldAnswer == false`; instance SRV/TXT/ANY and host A → true.
- [ ] **Step 2: Run** `swift test --filter DNSMessageTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the four files.
- [ ] **Step 4: Run** `swift test --filter DNSMessageTests`. Expected: PASS.
- [ ] **Step 5: Manual check (after Task 10 exists, re-run then):** `dns-sd -B _wahoo-fitness-tnp._tcp` lists the instance within 10 s; `dns-sd -L "DirCon Proxy <id>" _wahoo-fitness-tnp._tcp` shows port 36866 and the TXT keys; switching Wi-Fi off and on re-announces (instance reappears).
- [ ] **Step 6: Commit** `feat: mDNS responder and Bonjour fallback`.

### Task 8: DirCon TCP server

**Files:**
- Create: `Sources/DirConCore/DirConServer.swift`
- Test: `Tests/DirConCoreTests/DirConServerTests.swift`

**Interfaces:**
- Consumes: `ProxyCore` (Task 5), `Advertiser` (Task 7, only for the Bonjour mode's listener service).
- Produces: `final class DirConServer { init(core: ProxyCore, port: UInt16, queue: DispatchQueue, bonjourService: NWListener.Service? = nil, status: @escaping (String) -> Void); func start(ready: @escaping (Result<UInt16, Error>) -> Void); func stop() }`. `NWListener` on all interfaces, `TCP_NODELAY` and keepalive on every connection, maps each `NWConnection` to a `ClientID`, one `send` per frame, closes the connection on parser errors or when `ProxyCore` asks, refuses a 5th client by closing it. Status lines `client connected <ip>:<port>` / `client disconnected <ip>:<port>`.

- [ ] **Step 1: Write the failing tests** (real loopback TCP, `SimulatedTrainer`, port 0 → ephemeral):
  - `discoverOverTCP`: connect with `NWConnection` to 127.0.0.1, send `01 01 01 00 00 00`, receive the services response of Task 5's first test.
  - `oversizedFrameClosesConnection`: send a header with length 600 → connection closes.
  - `portInUseFails`: a second server on the first one's port → `ready` reports failure.
- [ ] **Step 2: Run** `swift test --filter DirConServerTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `DirConServer.swift`.
- [ ] **Step 4: Run** `swift test`. Expected: all PASS.
- [ ] **Step 5: Commit** `feat: DirCon TCP server`.

### Task 9: CoreBluetooth trainer link

**Files:**
- Create: `Sources/DirConCore/BLETrainerLink.swift`, `Sources/DirConCore/BLEScanner.swift`

**Interfaces:**
- Consumes: `TrainerLink` protocol (Task 5), `GattService`/`CharProps` (Task 2).
- Produces: `final class BLETrainerLink: NSObject, TrainerLink, CBCentralManagerDelegate, CBPeripheralDelegate { init(target: TrainerTarget, queue: DispatchQueue, scheduler: Scheduler, status: @escaping (String) -> Void, log: @escaping (String) -> Void) }`, `enum TrainerTarget { case identifier(UUID), name(String), first }`; `final class BLEScanner { func scan(seconds: Double, queue: DispatchQueue, completion: @escaping (Result<[(id: UUID, name: String, rssi: Int)], BluetoothError>) -> Void) }`; `enum BluetoothError: Error { case poweredOff, unauthorized, unsupported }` (maps to exit code 2).

Behaviour: the proxy spec's "Trainer side" section exactly: retrieve by identifier, else scan for 0x1826 (match by name if given); discover all services and characteristics; read and cache the static characteristics; enable Control Point indications; `ready`. Serial operation queue with one outstanding write per characteristic and the 2 s timeout; `.withResponse` when `.write` is present. Reconnect: `.reconnecting` + immediate `connect`, `.offline` after 30 s (keep trying), rediscover, restore notifications. Status line `trainer not found: spin the trainer to wake it` when a scan has run 10 s without a match, and on entering `.reconnecting`. Hold `ProcessInfo.beginActivity(options: [.userInitiated, .latencyCritical])` while connected.

- [ ] **Step 1: Implement** both files (no unit tests: CoreBluetooth needs hardware; the protocol behaviour above is already proven against `SimulatedTrainer`).
- [ ] **Step 2: Build** `swift build`. Expected: success.
- [ ] **Step 3: Hardware check** (needs Task 10's `scan` command; if the trainer isn't listed, ask the user to spin it): `swift run dirconproxy scan --timeout 10` lists `T600_35381` with its identifier.
- [ ] **Step 4: Commit** `feat: CoreBluetooth trainer link`.

### Task 10: Command line, config, keyboard input and logging

**Files:**
- Create: `Sources/dirconproxy/main.swift` (replace placeholder), `Sources/dirconproxy/RunCommand.swift`, `Sources/dirconproxy/ScanCommand.swift`, `Sources/dirconproxy/DoctorCommand.swift`, `Sources/dirconproxy/KeyboardShiftInput.swift`, `Sources/DirConCore/Config.swift`, `Sources/DirConCore/Capture.swift`
- Create: `scripts/build.sh` (release build + `codesign --sign - --identifier com.iremezoff.dirconproxy --options runtime .build/release/dirconproxy`)
- Test: `Tests/DirConCoreTests/ConfigTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `struct ProxyConfig: Codable, Equatable { var trainer: String?; var name: String?; var port: UInt16 = 36866; var mdns: MDNSMode = .own; var txt: TXTFormat; var serialNumber: String?; var notificationSeq: NotificationSeq = .zero; var interceptors: InterceptorConfig; var shifting: ShiftingConfig }`, `static func load(from url: URL) throws -> ProxyConfig` (missing file → defaults), `func save(to url: URL) throws`. Default path `~/.config/dirconproxy/config.json`.
  - `final class CaptureWriter { init(url: URL) throws; func record(direction: String, kind: String, uuid: BLEUUID?, data: Data) }` (JSON Lines, ms timestamps).
  - `final class KeyboardShiftInput: ShiftInput`: active only when `isatty(STDIN_FILENO)`; raw mode via `termios` with the original settings restored on `stop()`, at exit (`atexit`) and from the SIGINT/SIGTERM handlers; keys `]` or Up-arrow = `.up` (harder), `[` or Down-arrow = `.down` (easier); terminal key repeat gives repeats on hold.
  - Subcommands exactly as the proxy spec's "Commands" and "Options for run" tables, plus `run --simulate` (uses `SimulatedTrainer`, for testing without the T600) and `run --no-shifting` (pure pass-through).

Behaviour: wiring per the proxy spec's "Threading" (one queue, `dispatchMain()`), "Behaviour" (interactive trainer pick and save; non-TTY hint; Ctrl-C/SIGTERM via `DispatchSource` signal sources: mDNS goodbyes, close clients, disconnect trainer, restore terminal, exit 0), "Logging and runtime" (`os.Logger` subsystem `com.iremezoff.dirconproxy`, categories `ble`, `dircon`, `mdns`, `pipeline`; `--log-level debug` adds hex dumps with ms timestamps to stderr). Start listener and advertiser only when the trainer is `ready`; send goodbyes on `offline`. At startup print the two pairing names: `In Zwift pair "DirCon Proxy <id>", not "T600_35381"`. `doctor` checks Bluetooth authorization, active IPv4, UDP 5353 bindable with SO_REUSEPORT, TCP 36866 free. Log hint `no Zwift client after 60 s: check Zwift's Local Network permission` (proxy spec risks).

- [ ] **Step 1: Write the failing tests:** `configDefaults` (empty JSON → port 36866, mdns own, shifting enabled, gear start identity, strategy auto, rings [52, 36]); `configRoundTrip` (save → load equals); `configSnakeCaseKeys` (`{"shifting":{"min_step_pct":4}}` decodes).
- [ ] **Step 2: Run** `swift test --filter ConfigTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run** `swift test`. Expected: all PASS. `scripts/build.sh` succeeds.
- [ ] **Step 5: Simulated end-to-end check:** `.build/release/dirconproxy run --simulate` prints `trainer ready`, then the pairing hint; in another terminal `dns-sd -B _wahoo-fitness-tnp._tcp` shows the instance (Task 7 step 5 checks); install `wftnp` into `.venv` (`.venv/bin/pip install wftnp`) and with a short script in `scripts/dircon_check.py` discover services, enable 0x2AD2, send Request Control and `11 00 00 F4 01 28 33` (5 %), and print notifications: IBD arrives about 4×/s, `80 00 01` and `80 11 01` come back; pressing `[` in the proxy terminal prints a gear line and the simulated power drops.
- [ ] **Step 6: Terminal restore check:** with the proxy in front, press Ctrl-C → the shell echoes typed characters normally; repeat with `kill -TERM`; run `dirconproxy run --simulate < /dev/null` → starts with keyboard input off and a log line saying so.
- [ ] **Step 7: Commit** `feat: dirconproxy command line`.

### Task 11: Real trainer check and rider hand-off

**Files:**
- Create: `docs/TESTING.md` (rider steps)

- [ ] **Step 1: Builder check on the T600 (no pedalling needed).** Close the Magene app on the phone. Run `.build/release/dirconproxy run` (pick the T600 when asked; ask the user to spin the trainer if it isn't found). With `scripts/dircon_check.py`: Discover lists 0x180A, 0x1826, 0x1818, 0x1816 and never `8ce5cc01-…`; Request Control returns `80 00 01`; in `--no-shifting` mode Set Target Power 150 W returns `80 05 01` from the trainer; with shifting on, sending the 5 % SIM frame and then pressing `[` three times logs three trainer writes each answered `80 11 01` (decoded grade dropping with each gear).
- [ ] **Step 2: Write `docs/TESTING.md`** for the rider: permissions (Terminal: Bluetooth + Local Network; Zwift: Local Network), the two-monitor setup, pairing in Zwift (Power, Controllable, Cadence → `DirCon Proxy …`, never `T600_35381`), the keys, and one section per shifting test T2–T9 with the exact ride (grade, cadence, duration), the expected numbers from the shifting spec, and which log lines to copy back (`gear …` lines, decoded `SIM …` lines, IBD power). T4 decides whether Strategy C is needed; say what result means what.
- [ ] **Step 3: Ask the user** to pair Zwift with the proxy and confirm it appears within 10 s and shows power and cadence (proxy spec acceptance, first two rows). That, plus Steps 1–2, completes this build.
- [ ] **Step 4: Commit** `docs: rider test guide`.
