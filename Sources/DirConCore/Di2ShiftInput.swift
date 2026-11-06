import CoreBluetooth
import Foundation

/// Shimano Di2 rear derailleur as a shift input: connects over BLE to the D-FLY service
/// (no passkey), decodes button events with `Di2ShiftMapper` and reconnects on its own.
/// Independent of the trainer link: it never blocks the trainer becoming ready. Runs on the core queue.
public final class Di2ShiftInput: NSObject, ShiftInput, CBCentralManagerDelegate, CBPeripheralDelegate {
    public static let service = CBUUID(string: "000018EF-5348-494D-414E-4F5F424C4500")
    public static let channels = CBUUID(string: "00002AC2-5348-494D-414E-4F5F424C4500")
    public static let notFoundHintAfter = 15.0

    public var onShift: ((ShiftDirection) -> Void)? {
        get { mapper.onShift }
        set { mapper.onShift = newValue }
    }

    private let name: String?
    private let queue: DispatchQueue
    private let scheduler: Scheduler
    private let status: (String) -> Void
    private let log: (String) -> Void
    private let mapper: Di2ShiftMapper
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var hint: Cancellable?
    private var stopped = false

    public init(name: String?, queue: DispatchQueue, scheduler: Scheduler, repeatInterval: Double,
                status: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.name = name
        self.queue = queue
        self.scheduler = scheduler
        self.status = status
        self.log = log
        mapper = Di2ShiftMapper(scheduler: scheduler, repeatInterval: repeatInterval)
    }

    public func start() {
        stopped = false
        if central == nil { central = CBCentralManager(delegate: self, queue: queue) }
    }

    public func stop() {
        stopped = true
        hint?.cancel()
        mapper.reset()
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn, !stopped, peripheral == nil else { return }
        log("scanning for Di2")
        c.scanForPeripherals(withServices: [Self.service], options: nil)
        scheduleHint("Di2 not found: press a shifter to wake it")
    }

    private func scheduleHint(_ text: String) {
        hint?.cancel()
        hint = scheduler.after(Self.notFoundHintAfter) { [weak self] in
            guard let self, !self.stopped, self.peripheral?.state != .connected else { return }
            self.status(text)
            self.scheduleHint(text)
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi: NSNumber) {
        let advName = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if let name, advName != name { return }
        c.stopScan()
        log("found Di2 \(advName ?? "-") \(rssi) dBm")
        peripheral = p
        p.delegate = self
        c.connect(p, options: nil)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.service])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard !stopped else { return }
        c.connect(p, options: nil)
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        mapper.reset()
        guard !stopped else { return }
        status("Di2 link lost: press a shifter to wake it")
        c.connect(p, options: nil)  // waits until the derailleur wakes
        scheduleHint("Di2 still asleep: press a shifter to wake it")
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else {
            log("Di2 has no D-FLY service: \(error?.localizedDescription ?? "")")
            central?.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics([Self.channels], for: s)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let c = s.characteristics?.first(where: { $0.uuid == Self.channels }) else {
            log("Di2 has no D-FLY channel characteristic")
            central?.cancelPeripheralConnection(p)
            return
        }
        p.setNotifyValue(true, for: c)  // indications
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error {
            log("Di2 subscribe failed: \(error.localizedDescription)")
            return
        }
        hint?.cancel()
        status("Di2 connected: \(p.name ?? "derailleur"); left lever = easier, right lever = harder")
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, c.uuid == Self.channels, let v = c.value else { return }
        log("Di2 packet " + v.map { String(format: "%02x", $0) }.joined())
        mapper.receive(v)
    }
}
