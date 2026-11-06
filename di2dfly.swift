// Print Shimano Di2 D-FLY channel button events over Bluetooth LE (macOS, CoreBluetooth).
//
// Setup:
//   1. In E-TUBE PROJECT Cyclist (phone app), assign the buttons you want to read
//      to "D-FLY Ch.1" ... "D-FLY Ch.4", then close the app (one BLE connection at a time).
//   2. Build:  swiftc -O -swift-version 5 di2dfly.swift -o di2dfly
//   3. Run:    ./di2dfly            (press a shifter button first to wake the Di2)
//              ./di2dfly --scan     (list every BLE device the Mac can see)
//
// The terminal app you run this from needs Bluetooth permission:
// System Settings > Privacy & Security > Bluetooth.
//
// Protocol from BikeControl's open-source Di2 driver
// (github.com/OpenBikeControl/bikecontrol, lib/bluetooth/devices/shimano/shimano_di2.dart),
// checked against an RD-R8150 (Ultegra 12-speed). Not an official Shimano API.

import CoreBluetooth
import Foundation

// Shimano base UUID ("SHIMANO_BLE" in ASCII).
let dflyService = CBUUID(string: "000018EF-5348-494D-414E-4F5F424C4500")  // runtime D-FLY service, no passkey
let dflyChar = CBUUID(string: "00002AC2-5348-494D-414E-4F5F424C4500")     // indicates: 1 counter byte + 1 byte per channel
let shimanoBaseSuffix = "5348-494D-414E-4F5F424C4500"

// Channel byte: high nibble = event, low nibble = per-channel press counter.
// Observed on RD-R8150: 0x1_ short, 0x2_ long press start, 0x3_ (long|short bits) still held,
// 0x0_ released after a long press, 0x4_ double press, 0xF0 = not pressed since connecting.
func describe(_ value: UInt8) -> String {
    if value == 0xF0 { return "idle" }
    if value & 0x40 != 0 { return "double press" }
    if value & 0x20 != 0 { return value & 0x10 != 0 ? "long held" : "long press" }
    if value & 0x10 != 0 { return "short press" }
    return "released"
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func isDi2(name: String?, serviceUUIDs: [CBUUID]) -> Bool {
    serviceUUIDs.contains(dflyService) || (name ?? "").uppercased().hasPrefix("RDR")
}

struct Seen {
    let id: UUID
    var name: String?
    var rssi: Int
    var uuids: [CBUUID]
    var manufacturer: Data?
}

final class Di2: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let scanOnly: Bool
    let scanSeconds: TimeInterval
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var seen: [UUID: Seen] = [:]
    var last: [UInt8]?

    init(scanOnly: Bool) {
        self.scanOnly = scanOnly
        self.scanSeconds = scanOnly ? 15 : 30
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScan()
        case .unauthorized:
            fail("Bluetooth permission denied. Allow your terminal app in System Settings > Privacy & Security > Bluetooth.")
        case .poweredOff:
            fail("Bluetooth is off.")
        case .unsupported:
            fail("Bluetooth LE is not supported on this Mac.")
        default:
            break  // .unknown / .resetting: wait for the next update
        }
    }

    func startScan() {
        if scanOnly {
            print("Scanning \(Int(scanSeconds))s for all BLE devices (press a shifter button to wake the Di2)...")
        } else {
            print("Scanning for Di2 (press a shifter button to wake it)...")
        }
        // Scan without a service filter: macOS only matches advertised UUIDs, and a name match needs everything.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: scanOnly])
        DispatchQueue.main.asyncAfter(deadline: .now() + scanSeconds) { [weak self] in
            guard let self else { return }
            if self.scanOnly {
                self.central.stopScan()
                self.printScanResults()
                exit(0)
            } else if self.peripheral == nil {
                self.fail("No Di2 found. Wake it, keep it close, and make sure your phone app isn't connected.")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []

        if scanOnly {
            var entry = seen[peripheral.identifier] ?? Seen(id: peripheral.identifier, name: name, rssi: RSSI.intValue, uuids: uuids)
            entry.name = name ?? entry.name
            if RSSI.intValue != 127 { entry.rssi = RSSI.intValue }  // 127 = RSSI unavailable
            if !uuids.isEmpty { entry.uuids = uuids }
            if let m = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data { entry.manufacturer = m }
            seen[peripheral.identifier] = entry
            return
        }

        guard self.peripheral == nil, isDi2(name: name, serviceUUIDs: uuids) else { return }
        central.stopScan()
        print("Found \(name ?? "-") (\(peripheral.identifier.uuidString))")
        self.peripheral = peripheral  // keep a strong reference or CoreBluetooth drops it
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([dflyService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("Connection failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Pending connects never time out, so this reconnects as soon as the Di2 wakes up again.
        print("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ""). Reconnecting (press a shifter button)...")
        last = nil  // the Di2 resets every channel to 0xF0 on a new connection
        central.connect(peripheral)
    }

    // MARK: Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == dflyService }) else {
            fail("D-FLY service not found on this device: \(error?.localizedDescription ?? "no 18EF service")")
        }
        peripheral.discoverCharacteristics([dflyChar], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let char = service.characteristics?.first(where: { $0.uuid == dflyChar }) else {
            fail("D-FLY characteristic not found: \(error?.localizedDescription ?? "no 2AC2 characteristic")")
        }
        peripheral.setNotifyValue(true, for: char)  // CoreBluetooth enables indications when that's what it supports
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("Subscribing to D-FLY failed: \(error.localizedDescription)") }
        print("Listening. Ctrl+C to quit.")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == dflyChar, let data = characteristic.value, !data.isEmpty else { return }
        let channels = Array(data.dropFirst())  // byte 0 is a message counter

        guard let previous = last else {  // first packet is just the current state
            last = channels
            print("Ready. \(channels.count) D-FLY channels reported.")
            return
        }
        for (i, (old, new)) in zip(previous, channels).enumerated() where old != new {
            print("D-FLY Ch.\(i + 1): \(pad(describe(new), 13)) raw=0x\(String(format: "%02x", new))  packet=\(hex(data))")
        }
        last = channels
    }

    // MARK: Helpers

    func printScanResults() {
        for s in seen.values.sorted(by: { $0.rssi > $1.rssi }) {
            let uuids = s.uuids.map { $0.uuidString.lowercased() }
            let likely = isDi2(name: s.name, serviceUUIDs: s.uuids)
                || uuids.contains { $0.hasSuffix(shimanoBaseSuffix.lowercased()) }
            var mfr = "{}"
            if let m = s.manufacturer, m.count >= 2 {
                let company = Int(m[m.startIndex]) | Int(m[m.startIndex + 1]) << 8  // little-endian company ID
                mfr = "{\(company): '\(hex(m.dropFirst(2)))'}"
            }
            let rssi = String(format: "%4d", s.rssi)
            print("\(rssi) dBm  \(s.id.uuidString)  \(s.name ?? "-")  uuids=\(uuids)  mfr=\(mfr)\(likely ? "  <-- Di2?" : "")")
        }
    }

    func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)  // flush each line, even when piped to a file
let app = Di2(scanOnly: CommandLine.arguments.contains("--scan"))
withExtendedLifetime(app) { dispatchMain() }
