# DirCon Trainer Proxy for macOS — Implementation Spec

Nov 6, 2026 · @Ivan Remezov

## Overview

The proxy is a macOS command-line tool that holds the only Bluetooth connection to the trainer. It presents that trainer to Zwift, running on the same Mac, as a Wahoo Direct Connect (DirCon) device over TCP. Zwift pairs with the proxy's network entry instead of the trainer, so every command and every data packet passes through code you control.

DirCon is used on the Zwift side because a Mac cannot discover a Bluetooth peripheral that it advertises itself. DirCon is plain mDNS plus TCP over the Mac's own network interface, so same-machine discovery works. QZ uses the same route for its one-device Zwift mode ([QZ](https://github.com/cagnulein/qdomyos-zwift)).

**Goals**

- Connect to one FTMS trainer over Bluetooth LE and keep that link for the whole session, reconnecting on its own.
- Advertise `_wahoo-fitness-tnp._tcp` and serve DirCon on TCP port 36866 to Zwift on the same Mac.
- Mirror only standard Bluetooth SIG fitness services: FTMS, plus Cycling Power, Cycling Speed and Cadence and Heart Rate when the trainer has them.
- Make ERG (Set Target Power) and SIM (Set Indoor Bike Simulation Parameters) behave exactly as with direct pairing.
- Pass every message, in both directions, through an interceptor pipeline that can log, modify, drop or inject.

**Non-goals**

- No proprietary services: Zwift virtual shifting, Zwift Play or Click, `_zap._tcp` and vendor services are never exposed or answered.
- No Bluetooth peripheral role toward Zwift, and no ANT+.
- No GUI: a command-line tool set up by flags and a JSON config file, reporting through its log.

**Assumptions:** the trainer exposes FTMS (0x1826) with a Control Point; macOS 13 or later; Swift 5.9+ with CoreBluetooth and Network.framework as the reference stack.

## Architecture

The proxy is a handful of small modules on one serial queue: Bluetooth on one side, DirCon and mDNS on the other, and the interceptor pipeline in the middle.

&#91;embedded content: proxy architecture · 6 components\]

Every byte between Zwift and the trainer passes the pipeline. The mDNS responder only answers discovery, and the GATT model decides what Zwift can discover.

| Module | Responsibility |
| --- | --- |
| TrainerLink | CoreBluetooth central, GATT cache, operation queue, subscriptions, reconnect and replay |
| GattModel | Allowlist, UUID and property mapping, cached values |
| DirConCodec | Frame parsing and encoding only; no I/O, fully unit-tested |
| DirConServer | `NWListener`, sessions, per-client subscriptions, control ownership |
| MDNSResponder | UDP 5353 responder, announcements, goodbyes; Bonjour fallback |
| Pipeline | Interceptor chain and FTMS codecs |
| App | Command-line entry point: subcommands, config file, trainer picker, logging, signals |

## Trainer side (Bluetooth LE)

The proxy is the trainer's only Bluetooth client: it connects once, discovers everything, caches the GATT database and keeps the link up for the whole ride. Zwift never talks to the trainer directly.

**Scanning and selection**

- Scan with `scanForPeripherals(withServices: [0x1826])`.
- `dirconproxy scan` lists the trainers found (identifier, name, RSSI). The chosen identifier goes into the config file or the `--trainer` flag.
- `dirconproxy run` uses `retrievePeripherals(withIdentifiers:)`, then `connect`. It scans only if that fails, and asks the user to pick a trainer only when it runs on an interactive terminal.

**Connect and discover**

1. `connect(peripheral)`.
2. `discoverServices(nil)`, then `discoverCharacteristics(nil, for:)` on every service.
3. Build the GATT cache: service UUID → characteristics (UUID, CoreBluetooth properties, last value).
4. Read static characteristics once and cache them: Fitness Machine Feature 0x2ACC, Supported Power Range 0x2AD8, Supported Resistance Level Range 0x2AD6, Cycling Power Feature 0x2A65 and Device Information strings.
5. Enable indications on the FTMS Control Point 0x2AD9 at once and keep them on. FTMS requires the client to subscribe to Control Point indications before it sends commands ([Wahoo interfacing notes](https://redback-operations.github.io/redback-documentation/docs/project-1/iot/wahoo-devices/Wahoo-Device-Interfacing)).
6. Mark the trainer **ready**. Only then start the TCP listener and the mDNS announcements.

**Subscriptions**

- Data characteristics are subscribed on demand: 0x2AD2 Indoor Bike Data, 0x2A63 Cycling Power Measurement, 0x2A5B CSC Measurement, 0x2A37 Heart Rate Measurement, 0x2ADA Fitness Machine Status and 0x2AD3 Training Status.
- The first DirCon client that enables a characteristic triggers `setNotifyValue(true)`; the last one to disable or disconnect triggers `setNotifyValue(false)`.
- One reference count per characteristic, so one Bluetooth subscription serves every DirCon client.
- Control Point indications are exempt and stay on.

**Reads and writes**

- All Bluetooth operations go through one serial operation queue, with at most one outstanding write per characteristic.
- Writes use `.withResponse` when the characteristic has `.write`; otherwise `.withoutResponse`, completed immediately.
- Reads return the cached value for static characteristics; anything else uses `readValue(for:)`.
- Every operation times out after 2 s and is then reported to DirCon as failed.

**Reconnect**

- On `didDisconnectPeripheral`, the state becomes **reconnecting** and `connect` is called again at once. CoreBluetooth connect requests do not time out; they wait for the trainer.
- After reconnecting: rediscover, check against the cache, restore every Bluetooth subscription that still has DirCon subscribers, then replay the control state (see Lifecycle and errors).

**Exclusive use of the trainer**

- Close the trainer maker's app on phones and tablets before a ride; many trainers accept only one controlling client.
- Zwift on the same Mac can also see the trainer over Bluetooth. In Zwift's pairing screen the user must pick the proxy's DirCon entry, never the trainer's Bluetooth entry.

## What Zwift sees

Zwift sees a filtered mirror of the trainer: standard SIG fitness services and characteristics only, nothing vendor-specific, with DirCon property flags derived from the Bluetooth ones.

**Service allowlist** (each exposed only if the trainer has it)

| Service | UUID | Why it is exposed |
| --- | --- | --- |
| Fitness Machine (FTMS) | 0x1826 | Control (ERG and SIM) and Indoor Bike Data |
| Cycling Power | 0x1818 | Power and cadence source |
| Cycling Speed and Cadence | 0x1816 | Cadence on trainers that report it here |
| Heart Rate | 0x180D | Only when the trainer relays a heart-rate strap |
| Device Information | 0x180A | Manufacturer, model and serial strings |

**Filtering rules**

- Every service outside the allowlist is hidden, including 128-bit vendor services such as Wahoo's legacy trainer service `a026ee01-0a7d-4ab3-97fa-f1500f9feb8b` and any Zwift service.
- Inside an allowed service, any characteristic whose UUID is not on the SIG base UUID is hidden too. Some trainers put a vendor control characteristic inside the Cycling Power service.
- GAP (0x1800) and GATT (0x1801) are never exposed; CoreBluetooth hides them anyway.

**UUID handling**

- Store every UUID as 16 bytes. A 16-bit SIG UUID `xxxx` expands to `0000xxxx-0000-1000-8000-00805F9B34FB`.
- On the wire, DirCon carries those 16 bytes in textual left-to-right order, not in BLE's little-endian order ([WFTNP spec](https://github.com/elfrances/wahoo-fitness-tnp)).
- Inside the proxy, identity is (service UUID, characteristic UUID). DirCon requests carry only the characteristic UUID, so it resolves to the single exposed characteristic with that UUID ([DirCon gateway notes](https://github.com/Berg0162/DirCon)). If an exposed UUID would appear twice, expose the first and log the clash.

**Property mapping** (DirCon properties byte)

| CoreBluetooth property | DirCon bit |
| --- | --- |
| `.read` | 0x01 READ |
| `.write` or `.writeWithoutResponse` | 0x02 WRITE |
| `.notify` or `.indicate` | 0x04 NOTIFY |

DirCon has no separate indication type, because TCP is already reliable; BLE indications reach Zwift as ordinary notifications. So the Control Point 0x2AD9 (write + indicate) is advertised as 0x06, Indoor Bike Data 0x2AD2 as 0x04 and Fitness Machine Feature 0x2ACC as 0x01.

## DirCon wire protocol

DirCon is GATT over TCP: every message is a 6-byte header plus optional data, and every client request gets exactly one response. The only unsolicited message is the characteristic notification. The layout follows the reverse-engineered [WFTNP specification](https://github.com/elfrances/wahoo-fitness-tnp).

**Header (6 bytes)**

| Offset | Size | Field | Value |
| --- | --- | --- | --- |
| 0 | 1 | Version | 1 |
| 1 | 1 | Message type | see next table |
| 2 | 1 | Sequence number | set by the client, echoed in the response |
| 3 | 1 | Response code | 0 in requests |
| 4 | 2 | Data length | big-endian, bytes after the header |

**Message types**

| Type | Name | Request data | Response data |
| --- | --- | --- | --- |
| 0x01 | Discover Services | none | N × service UUID (16 bytes each) |
| 0x02 | Discover Characteristics | service UUID (16) | service UUID (16) + N × (characteristic UUID 16 + properties 1) |
| 0x03 | Read Characteristic | characteristic UUID (16) | characteristic UUID (16) + value |
| 0x04 | Write Characteristic | characteristic UUID (16) + value | characteristic UUID (16) |
| 0x05 | Enable Notifications | characteristic UUID (16) + 1 byte (0x01 on, 0x00 off) | characteristic UUID (16) |
| 0x06 | Characteristic Notification | server to client only | characteristic UUID (16) + value |

**Response codes**

| Code | Meaning | The proxy sends it when |
| --- | --- | --- |
| 0 | Success | the operation completed |
| 1 | Invalid message type | a client sends a type other than 1–5 |
| 2 | Generic error | a BLE read fails or times out, or the trainer is offline |
| 3 | Service not found | Discover Characteristics names a hidden or unknown service |
| 4 | Characteristic not found | the UUID is not in the exposed set |
| 5 | Operation not supported | e.g. a write to a read-only characteristic |
| 6 | Write failed | the BLE write returns an error or times out |

**Rules**

- Characteristic values are copied byte for byte from BLE, so multi-byte integers inside them stay little-endian. Only the header length field is big-endian.
- Discover Services lists every exposed service; that may be more than the TXT record lists.
- Error responses carry no data (length 0). This is an assumption; confirm it against a capture (see Risks).
- Responses echo the request's sequence number. Notifications use sequence number 0 by default, with a per-connection counter as a configurable alternative; the spec leaves this open.

**Byte examples** (hex; the FTMS UUID 0x1826 is `00 00 18 26 00 00 10 00 80 00 00 80 5F 9B 34 FB`)

```text
Discover Services, seq 1
  → 01 01 01 00 00 00
  ← 01 01 01 00 00 20  00 00 18 26 00 00 10 00 80 00 00 80 5F 9B 34 FB
                       00 00 18 18 00 00 10 00 80 00 00 80 5F 9B 34 FB

Enable notifications on Indoor Bike Data (0x2AD2), seq 5
  → 01 05 05 00 00 11  00 00 2A D2 00 00 10 00 80 00 00 80 5F 9B 34 FB  01
  ← 01 05 05 00 00 10  00 00 2A D2 00 00 10 00 80 00 00 80 5F 9B 34 FB

Write Request Control (op 0x00) to the Control Point (0x2AD9), seq 7
  → 01 04 07 00 00 11  00 00 2A D9 00 00 10 00 80 00 00 80 5F 9B 34 FB  00
  ← 01 04 07 00 00 10  00 00 2A D9 00 00 10 00 80 00 00 80 5F 9B 34 FB

Trainer's Control Point indication, forwarded as a notification
  ← 01 06 00 00 00 13  00 00 2A D9 00 00 10 00 80 00 00 80 5F 9B 34 FB  80 00 01
```

**TCP stream handling**

- Keep one receive buffer per connection. Parse while at least 6 bytes are buffered and 6 + length bytes are available; one read may hold several messages or part of one.
- A version other than 1 or a data length above 512 bytes closes the connection, with a log entry.
- Set `TCP_NODELAY` and keepalive on every accepted connection, as the WFTNP spec recommends.
- Handle one connection's requests strictly in order. A write's DirCon response goes out only after the BLE write completes or fails, so a newer command never overtakes an older one.
- Send each frame with a single write so frames never interleave; notifications may arrive between a request and its response.

## Network discovery (mDNS)

The proxy runs its own small mDNS responder for `_wahoo-fitness-tnp._tcp.local` that puts PTR, SRV, TXT and A records all in the Answers section. Zwift does not connect when the A record arrives only under Additional Records ([SmartSpin2k #340](https://www.github.com/doudar/SmartSpin2k/issues/340), [QZ #756](https://github.com/cagnulein/qdomyos-zwift/issues/756)).

**Records**

| Record | Name | Value |
| --- | --- | --- |
| PTR | `_wahoo-fitness-tnp._tcp.local` | `<instance>._wahoo-fitness-tnp._tcp.local` |
| SRV | `<instance>._wahoo-fitness-tnp._tcp.local` | priority 0, weight 0, port 36866, target `<host>.local` |
| TXT | `<instance>._wahoo-fitness-tnp._tcp.local` | `serial-number=…`, `mac-address=…`, `ble-service-uuids=…` |
| A | `<host>.local` | the Mac's IPv4 address on the active interface |

**Names and values**

- Instance: `DirCon Proxy <last 4 hex of trainer id>`. Zwift shows it in the pairing list, and custom names work; SHIFTR advertises as `SHIFTR <id>` ([SHIFTR](https://github.com/JuergenLeber/SHIFTR)).
- Host: a name of its own, such as `dirconproxy-1a2b.local`, never the Mac's own host name, so it never collides with records the system's mDNSResponder owns.
- `serial-number`: the trainer's Serial Number String (0x2A25) if available, else a generated stable ID.
- `mac-address`: the MAC of the Mac's active interface.
- `ble-service-uuids`: comma-separated 16-bit UUIDs of the exposed FTMS and Cycling Power services, e.g. `0x1826,0x1818`. The exact text formats are unverified; make them configurable (see Risks).
- TTLs: 120 s for SRV and A, 4500 s for PTR and TXT.

**Responder behaviour**

- Bind UDP 5353 on IPv4 with `SO_REUSEADDR` and `SO_REUSEPORT`, so the socket coexists with macOS's mDNSResponder. Join 224.0.0.251 on the active interface and keep `IP_MULTICAST_LOOP` on, so Zwift on the same Mac hears the replies.
- Answer a PTR query for the service type, and SRV, TXT or ANY queries for the instance, with all four records in Answers. Answer A queries for the host with the A record.
- If the query has the unicast-response (QU) bit set, reply unicast to the querier's address and port; otherwise multicast to 224.0.0.251:5353.
- On start, announce the records unsolicited three times, 1 s apart. When the trainer goes offline or the app quits, send goodbye records (TTL 0).
- Ignore every other service type, including `_zap._tcp`, which Zwift also queries ([zwiftplay #9](https://github.stncp.dns-dynamic.net/ajchellew/zwiftplay/issues/9)).
- Re-announce when the Mac's IPv4 address changes (`NWPathMonitor`).

**Fallback mode.** A second implementation of the same interface registers the service with system Bonjour (`NWListener.service`). It is simpler but places SRV, TXT and A under Additional Records, so it is a settings switch for testing, not the default. Never run both at once.

**TCP listener.** `NWListener` on port 36866, all interfaces. Zwift connects to the A-record address, which is the Mac's own LAN address, so the Mac needs an active interface with IPv4. Zwift needs a network connection anyway.

## Zwift session flow

A Zwift session is mDNS discovery, then GATT discovery answered from the proxy's cache, then a steady loop of notifications and Control Point writes.

&#91;embedded content: typical Zwift session · discovery, setup, riding\]

Each `04` write also gets its own DirCon response (type 04, code 0) once the BLE write completes; the drawing leaves it out. The order of the setup steps follows what Zwift does today and may change between versions.

**Control Point handling**

- Zwift sends no other Control Point command until `80 00 01` arrives. If it keeps resending Request Control, the indication is not reaching it ([DirCon gateway notes](https://github.com/Berg0162/DirCon)).
- SIM sends 0x11 on every gradient change; ERG sends 0x05 on every target step.
- Both pass the pipeline before the trainer sees them, and the trainer's result passes it on the way back.

## FTMS reference

In pass-through mode the proxy forwards FTMS bytes untouched; it decodes them only for logging and for interceptors. Values follow the [FTMS 1.0 specification](https://www.bluetooth.com/specifications/specs/fitness-machine-service-1-0); all multi-byte fields are little-endian.

**Characteristics**

| Name | UUID | BLE properties | DirCon properties |
| --- | --- | --- | --- |
| Fitness Machine Feature | 0x2ACC | read | 0x01 |
| Indoor Bike Data | 0x2AD2 | notify | 0x04 |
| Training Status | 0x2AD3 | read, notify | 0x05 |
| Supported Resistance Level Range | 0x2AD6 | read | 0x01 |
| Supported Power Range | 0x2AD8 | read | 0x01 |
| Fitness Machine Control Point | 0x2AD9 | write, indicate | 0x06 |
| Fitness Machine Status | 0x2ADA | notify | 0x04 |

**Control Point op codes Zwift uses**

| Op | Name | Parameters | When |
| --- | --- | --- | --- |
| 0x00 | Request Control | none | first, before any other command |
| 0x05 | Set Target Power | sint16, 1 W | ERG workouts |
| 0x11 | Set Indoor Bike Simulation Parameters | wind sint16 (0.001 m/s), grade sint16 (0.01 %), Crr uint8 (0.0001), Cw uint8 (0.01 kg/m) | free rides and routes (SIM) |

Other op codes, such as 0x01 Reset or 0x07 Start or Resume, are forwarded unchanged. Zwift sends 0x11 in normal riding and 0x05 in ERG workouts, and expects `80 00 01` after Request Control ([Stack Overflow answer](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/59653425/zwift-add-resistance-with-ftms-control-point)).

**Control Point response** (indication from the trainer): `80 <request op> <result>`. Results: 0x01 Success, 0x02 Op code not supported, 0x03 Invalid parameter, 0x04 Operation failed, 0x05 Control not permitted.

**Decoded example** from a Zwift log, `11 00 00 EE 00 28 33` ([Zwift forum](https://forums.zwift.com/t/zwift-documentation-for-interfacing-with-smart-trainers/20521)): wind 0 m/s; grade 0x00EE = 238 → 2.38 %; Crr 0x28 = 40 → 0.0040; Cw 0x33 = 51 → 0.51 kg/m.

**Indoor Bike Data (0x2AD2)**: a uint16 flags field, then the fields whose flag is set, in this order.

| Flag bit | Field | Type and unit |
| --- | --- | --- |
| 0 (inverted: present when 0) | Instantaneous Speed | uint16, 0.01 km/h |
| 1 | Average Speed | uint16, 0.01 km/h |
| 2 | Instantaneous Cadence | uint16, 0.5 rpm |
| 3 | Average Cadence | uint16, 0.5 rpm |
| 4 | Total Distance | uint24, 1 m |
| 5 | Resistance Level | sint16 |
| 6 | Instantaneous Power | sint16, 1 W |
| 7 | Average Power | sint16, 1 W |
| 8 | Expended Energy | uint16 kcal + uint16 kcal/h + uint8 kcal/min |
| 9 | Heart Rate | uint8, bpm |
| 10 | Metabolic Equivalent | uint8, 0.1 |
| 11 | Elapsed Time | uint16, s |
| 12 | Remaining Time | uint16, s |

**Fitness Machine Status (0x2ADA)** worth logging: 0x12 Indoor Bike Simulation Parameters Changed, 0xFF Control Permission Lost.

## Interception hooks

Every message crosses one pipeline in each direction, so changing the ride means adding an interceptor, never touching protocol code. The default pipeline only logs, which makes the proxy a pure pass-through.

```swift
enum Verdict {
    case forward(Data)          // send on, possibly modified
    case drop                   // swallow silently
    case reply(DirConResult)    // answer the client; the trainer is not touched (writes only)
}

protocol Interceptor: AnyObject {
    /// Zwift → trainer: Write Characteristic requests.
    func clientWrite(_ ch: CharacteristicID, _ value: Data, from client: ClientID) -> Verdict
    /// Trainer → Zwift: notifications and indications.
    func trainerValue(_ ch: CharacteristicID, _ value: Data) -> Verdict
    /// Read results, cached or live.
    func readResult(_ ch: CharacteristicID, _ value: Data) -> Data
}

/// Handed to each interceptor when it is registered.
protocol ProxyControl {
    func sendToTrainer(_ ch: CharacteristicID, _ value: Data) async throws
    func notifyClients(_ ch: CharacteristicID, _ value: Data)
}
```

**Rules**

- Interceptors run in registration order. The first `.drop` or `.reply` ends the chain.
- Default method implementations return the value unchanged.
- Hooks run on the core serial queue and must return within 5 ms; slower work goes through `ProxyControl` asynchronously.
- `.reply` on a Control Point write makes the proxy send DirCon success. The interceptor must then send the `80 <op> <result>` notification itself with `notifyClients`, because Zwift waits for it.
- Typed helpers, `FTMSControlCommand` and `IndoorBikeData`, parse and re-encode the bytes, so interceptors work in watts, rpm and percent.

**Example interceptors**

- Scale SIM gradient, e.g. to 50 % of the road, by rewriting the grade field of op 0x11.
- Cap ERG target power at a set maximum by rewriting op 0x05.
- Smooth or offset reported power in Indoor Bike Data before Zwift sees it.
- Record every frame with a timestamp for replay tests.

Built-in interceptors (grade scaling, ERG cap, power offset) are switched on and set in the config file. Custom interceptors are Swift types compiled into the binary.

## Lifecycle and errors

The proxy advertises only while the trainer is ready, keeps Zwift's TCP session open through short Bluetooth drops, and replays the last control command after a reconnect. ERG or SIM then resumes without re-pairing.

**States**

| State | What happens | mDNS | DirCon clients |
| --- | --- | --- | --- |
| Scanning | Retrieve the saved trainer, or scan for 0x1826 | silent | none |
| Connecting | Connect, discover, cache, enable Control Point indications | silent | none |
| Ready | Listener running, records announced | answering | served normally |
| Reconnecting | BLE link lost; `connect` reissued at once | answering | kept open; see below |
| Offline | Reconnecting for more than 30 s | goodbye sent | connections closed |

**While reconnecting**

- Reads return cached values; enable and disable requests are recorded and applied after reconnect.
- Control Point writes: keep only the newest command per op code and answer the DirCon write with success. The trainer's `80` result reaches Zwift once the command is replayed.
- Other writes get response code 2 (Generic error).

**Control-state replay after reconnect**

1. Restore Bluetooth subscriptions that still have DirCon subscribers; Control Point indications first.
2. Write Request Control (0x00).
3. Write the last Set Target Power (0x05) or Set Indoor Bike Simulation Parameters (0x11), whichever came last.
4. Swallow the trainer's `80` results for replayed commands Zwift did not send; forward results for queued commands it did send.

**Clients and control**

- Several DirCon clients may connect; each has its own subscription set.
- One client controls the trainer: the first to get a successful Request Control. Control is released when it disconnects.
- Control Point writes from any other client never reach the trainer. The proxy answers DirCon success and sends that client the notification `80 <op> 05` (Control not permitted).
- Control Point results go to the controlling client even if it never enabled notifications on 0x2AD9, because Zwift expects them regardless ([DirCon gateway notes](https://github.com/Berg0162/DirCon)).
- On disconnect, drop that client's subscriptions and decrement the Bluetooth reference counts; Control Point indications stay on.

**Limits**

| Item | Value |
| --- | --- |
| BLE operation timeout | 2 s |
| Reconnect window before Offline | 30 s |
| Maximum DirCon data length | 512 bytes |
| Maximum DirCon clients | 4 |

**Logging and runtime**

- One `Logger` category per layer: `ble`, `dircon`, `mdns`, `pipeline`.
- At debug level, a hex dump of every DirCon frame and BLE operation with a millisecond timestamp.
- Optional JSON Lines capture file of all frames, for replay tests.
- Hold `ProcessInfo.beginActivity(options: [.userInitiated, .latencyCritical])` while a trainer is connected, so timer coalescing never delays Bluetooth or socket callbacks.

## Command line and packaging

The proxy ships as one command-line binary, `dirconproxy`, run from a terminal or as a launch agent. It has no windows or menu: flags and a JSON config file set it up, and status goes to the log.

**Commands**

| Command | What it does |
| --- | --- |
| `dirconproxy scan [--timeout 10]` | Lists FTMS trainers in range: identifier, name, RSSI |
| `dirconproxy run [options]` | Connects to the trainer, advertises and serves DirCon until stopped |
| `dirconproxy doctor` | Checks Bluetooth authorization, the active IPv4 address, UDP 5353 and TCP 36866 |

**Options for `run`**

| Option | Default | Meaning |
| --- | --- | --- |
| `--trainer <id or name>` | from config | Trainer to connect to |
| `--name <instance>` | `DirCon Proxy <id>` | Name Zwift shows when pairing |
| `--port <n>` | 36866 | DirCon TCP port |
| `--mdns <mode>` | `own` | `own` responder or `bonjour` fallback |
| `--log-level <level>` | `info` | `debug` adds hex dumps of every frame |
| `--capture <file>` | off | JSON Lines capture of all frames |
| `--config <file>` | `~/.config/dirconproxy/config.json` | Config file |

The config file holds the trainer identifier, instance name, TXT value overrides and interceptor settings. Flags override it.

**Behaviour**

- With no trainer in flags or config, `run` on an interactive terminal scans, asks the user to pick one by number and saves it to the config. Without a terminal it exits with a hint to run `scan`.
- One status line per state change on stderr, e.g. `trainer ready: KICKR CORE 1A2B`, `client connected 192.168.1.20:52144`, `control granted`.
- Ctrl-C or SIGTERM sends mDNS goodbye records, closes DirCon connections, disconnects the trainer and exits.
- Exit codes: 0 normal stop, 1 usage or config error, 2 Bluetooth off or not authorized, 3 network error (port in use, no IPv4 address).

**Embedded Info.plist.** A command-line tool has no bundle, so the plist is linked into the binary's `__TEXT,__info_plist` section. macOS reads the usage descriptions from there.

| Key | Value |
| --- | --- |
| `CFBundleIdentifier` | e.g. `com.example.dirconproxy` |
| `NSBluetoothAlwaysUsageDescription` | Connects to your smart trainer. |
| `NSLocalNetworkUsageDescription` | Lets Zwift on this Mac find your trainer over the local network. |
| `NSBonjourServices` | `_wahoo-fitness-tnp._tcp`, only if the Bonjour fallback is built in |

**Build and signing**

- Swift Package Manager executable target, macOS 13 or later, with Swift Argument Parser for the subcommands.
- Embed the plist through linker flags in `Package.swift`: `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist`.
- Sign with a stable identity: `codesign --sign "<identity>" --identifier com.example.dirconproxy --options runtime dirconproxy`. macOS ties privacy grants to the code signature, so ad-hoc signed rebuilds can bring the permission prompts back.
- No sandbox, so no entitlements are needed.

**Permissions the user grants once**

- Run from a terminal, macOS normally attributes Bluetooth and Local Network access to the terminal app (Terminal, iTerm2 or an IDE's terminal). That app gets the prompts and must be allowed.
- Run as a launch agent, the `dirconproxy` binary itself is asked, using the embedded usage descriptions.
- Zwift needs Local Network access too, under System Settings › Privacy & Security › Local Network. Without it Zwift never sees the DirCon entry.
- With the application firewall on, allow incoming connections for `dirconproxy`.

**Start at login (optional).** A plist in `~/Library/LaunchAgents` runs `dirconproxy run` with `KeepAlive` set, so the proxy is waiting before Zwift starts. Its `StandardErrorPath` receives the status lines.

**Threading.** `main` hands control to `dispatchMain()`. One serial `DispatchQueue` owns `CBCentralManager`, `NWListener`, every `NWConnection`, the mDNS socket and the signal sources. All proxy state lives on that queue (or in an actor wrapping it), so there are no locks.

## Testing and acceptance

Test bottom-up so each layer is proven before Zwift is involved; Zwift is the last check, not the debugger.

1. **Codec unit tests.** Encode and decode the byte examples in the wire-protocol section. Cover one frame split across two reads, two frames in one read, and an oversized length.
2. **Mock trainer.** A `TrainerLink` implementation that simulates FTMS: power follows the target, cadence fixed at 85 rpm, correct `80` responses. DirCon and mDNS can then be tested without hardware, as the [DirCon gateway](https://github.com/Berg0162/DirCon) does with its software trainer.
3. **mDNS.** `dns-sd -B _wahoo-fitness-tnp._tcp` lists the instance; `dns-sd -L "<instance>" _wahoo-fitness-tnp._tcp` shows port 36866 and the TXT keys. Wireshark with filter `udp.port == 5353` shows PTR, SRV, TXT and A in Answers.
4. **Protocol client.** The Python package [wftnp](https://pypi.org/project/wftnp/) is an independent DirCon client with mDNS discovery. Use it to discover services and characteristics, subscribe and print raw notifications.
5. **Real trainer, no Zwift.** With the same client, write Request Control and then Set Target Power 150 W; the resistance must change and `80 05 01` must come back.
6. **Zwift.** In the pairing screen, pick the proxy's entry for Power source, Controllable and Cadence. Ride 10 minutes on a hilly route, then a short ERG workout.

**Acceptance criteria**

- [ ] Zwift on the same Mac lists the proxy within 10 s of the trainer becoming ready.
- [ ] Power and cadence shown in Zwift match the decoded Indoor Bike Data in the proxy log.
- [ ] SIM: resistance follows gradient changes, and each 0x11 command appears in the log with its decoded grade.
- [ ] ERG: each target-power step reaches the trainer within 2 s.
- [ ] Trainer power-cycled mid-ride: data and ERG or SIM resume within 30 s without re-pairing.
- [ ] Zwift quit and restarted: it finds the proxy again; the Bluetooth link is not dropped.
- [ ] No vendor service or characteristic appears in any Discover response.
- [ ] A 60-minute ride without a dropout, with median added latency under 50 ms from BLE notification in to DirCon frame out.

## Risks and open questions

The biggest risk is discovery, not the protocol: Zwift is strict about mDNS, and a few DirCon details are reverse-engineered rather than specified. Capturing a real DirCon trainer, or QZ in DirCon mode, with Wireshark settles most of the rows below in one session.

| Risk or open question | Impact | Mitigation |
| --- | --- | --- |
| Zwift rejects mDNS replies with the A record under Additional Records | Zwift never connects | Own responder by default; compare against a capture |
| Does Zwift on macOS resolve through system Bonjour? | If yes, the simpler fallback mode is enough | Test both modes in the first week |
| Exact TXT value formats (`0x` prefix in `ble-service-uuids`, `mac-address` separator) | Zwift may ignore the entry | Make formats configurable; copy a capture |
| Sequence number on notifications | Unlikely, but a client could check it | Default 0; counter as an option |
| Data in error responses: empty or the request UUID | A client could misparse an error | Default empty; confirm in a capture |
| User pairs the trainer's Bluetooth entry in Zwift | Proxy bypassed; trainer has two clients | Clear pairing instructions; the startup log prints both names |
| Local Network permission missing for Zwift | DirCon entry invisible | Permission checklist; a log hint if no client connects within 60 s |
| UDP 5353 shared with mDNSResponder | Responder misses queries | `SO_REUSEPORT`; Bonjour fallback switch |
| Trainer allows only one BLE client | Proxy cannot connect while a phone app holds it | "Trainer busy" state; close the maker's app |
| Zwift updates change DirCon behaviour | Silent breakage | Keep frame captures to diagnose quickly |

## References

- [elfrances/wahoo-fitness-tnp](https://github.com/elfrances/wahoo-fitness-tnp): unofficial WFTNP (DirCon) specification; message format, response codes, mDNS records.
- [Berg0162/DirCon](https://github.com/Berg0162/DirCon): ESP32 BLE-to-DirCon gateway; layering, multi-client subscriptions, Control Point behaviour with Zwift.
- [cagnulein/qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift): QZ, with DirCon emulation and a one-device Zwift mode; see [dirconprocessor.cpp](https://github.com/cagnulein/qdomyos-zwift/blob/master/src/dirconprocessor.cpp).
- [QZ issue #756](https://github.com/cagnulein/qdomyos-zwift/issues/756): Zwift's strict mDNS handling.
- [SmartSpin2k issue #340](https://www.github.com/doudar/SmartSpin2k/issues/340): the A record in the Answers section.
- [JuergenLeber/SHIFTR](https://github.com/JuergenLeber/SHIFTR): BLE-to-DirCon bridge with a pass-through mode.
- [wftnp](https://pypi.org/project/wftnp/): Python DirCon client for testing.
- [Bluetooth SIG FTMS 1.0](https://www.bluetooth.com/specifications/specs/fitness-machine-service-1-0): Fitness Machine Service specification.
- [Zwift forum: interfacing with smart trainers](https://forums.zwift.com/t/zwift-documentation-for-interfacing-with-smart-trainers/20521): logged 0x11 commands from Zwift.
- [Stack Overflow: Zwift and the FTMS Control Point](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/59653425/zwift-add-resistance-with-ftms-control-point): Request Control response; Zwift's use of 0x11 and 0x05.
