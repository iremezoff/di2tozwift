import ArgumentParser
import DirConCore
import Foundation

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Connect to the trainer, advertise and serve DirCon until stopped.")

    @Option(help: "Trainer identifier or name (see `scan`).") var trainer: String?
    @Option(help: "Name Zwift shows when pairing.") var name: String?
    @Option(help: "DirCon TCP port.") var port: UInt16?
    @Option(help: "mDNS mode: own or bonjour.") var mdns: String?
    @Option(name: .customLong("log-level"), help: "info or debug (hex dumps of every value).") var logLevel = "info"
    @Option(help: "JSON Lines capture of all values.") var capture: String?
    @Option(help: "Config file.") var config = ProxyConfig.defaultURL.path
    @Flag(help: "Use the built-in simulated trainer instead of Bluetooth.") var simulate = false
    @Flag(name: .customLong("no-shifting"), help: "Pure pass-through: no virtual gears.") var noShifting = false
    @Flag(help: "Shift with the Di2 levers (D-FLY Ch.1/2 easier, Ch.3/4 harder).") var di2 = false
    @Option(name: .customLong("di2-name"), help: "Advertised name of the Di2 rear derailleur.") var di2Name: String?

    func run() throws {
        Out.debug = logLevel == "debug"
        let url = URL(fileURLWithPath: (config as NSString).expandingTildeInPath)
        var cfg: ProxyConfig
        do { cfg = try ProxyConfig.load(from: url) } catch { Out.fail("config \(url.path): \(error)", .usage) }
        if let trainer { cfg.trainer = trainer }
        if let name { cfg.name = name }
        if let port { cfg.port = port }
        if let mdns {
            guard let m = MDNSMode(rawValue: mdns) else { Out.fail("--mdns must be own or bonjour", .usage) }
            cfg.mdns = m
        }
        if noShifting { cfg.shifting.enabled = false }
        if di2 { cfg.di2.enabled = true }
        if let di2Name { cfg.di2.name = di2Name }

        if cfg.trainer == nil, !simulate {
            cfg.trainer = pickTrainer()
            try? cfg.save(to: url)
            Out.status("saved trainer to \(url.path)")
        }

        let app = ProxyApp(config: cfg, simulate: simulate, capturePath: capture)
        app.start()
        withExtendedLifetime(app) { dispatchMain() }
    }

    /// Interactive pick; without a terminal, exit with a hint.
    private func pickTrainer() -> String {
        guard isatty(STDIN_FILENO) == 1 else {
            Out.fail("no trainer configured: run `dirconproxy scan`, then pass --trainer <id>", .usage)
        }
        Out.status("no trainer configured; scanning 10 s (spin the trainer to wake it)...")
        var picked: String?
        let scanner = BLEScanner()
        let done = DispatchSemaphore(value: 0)
        let q = DispatchQueue(label: "dirconproxy.scan")
        scanner.scan(seconds: 10, queue: q) { r in
            switch r {
            case .failure(let e): Out.fail(e.description, .bluetooth)
            case .success(let list):
                guard !list.isEmpty else { Out.fail("no trainer found: spin the trainer to wake it, then run again", .usage) }
                for (i, t) in list.enumerated() { Out.status(String(format: "%2d  %@  %d dBm", i + 1, t.name, t.rssi)) }
                FileHandle.standardError.write(Data("pick a trainer [1]: ".utf8))
                let line = readLine() ?? ""
                let n = Int(line.trimmingCharacters(in: .whitespaces)) ?? 1
                guard list.indices.contains(n - 1) else { Out.fail("no trainer number \(n)", .usage) }
                picked = list[n - 1].id.uuidString
            }
            done.signal()
        }
        done.wait()
        return withExtendedLifetime(scanner) { picked! }
    }
}

/// The running proxy: one serial queue owns the trainer link, the DirCon server, mDNS and input.
final class ProxyApp {
    private let config: ProxyConfig
    private let queue = DispatchQueue(label: "dirconproxy.core", qos: .userInteractive)
    private let scheduler: DispatchScheduler
    private let trainer: TrainerLink
    private let core: ProxyCore
    private let shifting: VirtualShifting?
    private let keyboard: KeyboardShiftInput
    private var di2: Di2ShiftInput?
    private var server: DirConServer?
    private var advertiser: MDNSResponder?
    private var records: ServiceRecords?
    private var anyClient = false
    private var stopping = false
    private var signals: [DispatchSourceSignal] = []

    init(config: ProxyConfig, simulate: Bool, capturePath: String?) {
        self.config = config
        scheduler = DispatchScheduler(queue: queue)
        keyboard = KeyboardShiftInput(queue: queue)

        if simulate {
            trainer = SimulatedTrainer(scheduler: scheduler)
        } else {
            let link = BLETrainerLink(target: TrainerTarget(config.trainer), queue: queue, scheduler: scheduler,
                                      status: Out.status, log: { Out.log("ble: " + $0) })
            link.onBluetoothError = { Out.fail($0.description, .bluetooth) }
            trainer = link
        }

        var interceptors: [Interceptor] = []
        if let p = capturePath {
            do { interceptors.append(CaptureInterceptor(try CaptureWriter(url: URL(fileURLWithPath: p)))) } catch {
                Out.fail("capture file \(p): \(error)", .usage)
            }
        }
        if Out.debug { interceptors.append(HexDumpInterceptor(log: { Out.log("pipeline: " + $0) })) }
        interceptors.append(LoggingInterceptor(verboseData: Out.debug, log: { Out.log("pipeline: " + $0) }))
        if let g = config.interceptors.gradeScale { interceptors.append(GradeScaleInterceptor(factor: g)) }
        if let w = config.interceptors.ergCapW { interceptors.append(ErgCapInterceptor(maxW: Int16(clamping: w))) }
        if let o = config.interceptors.powerOffsetW { interceptors.append(PowerOffsetInterceptor(offsetW: o)) }
        if config.shifting.enabled {
            let vs = VirtualShifting(config: config.shifting, status: Out.status, log: { Out.log("shifting: " + $0) })
            interceptors.append(vs)
            shifting = vs
        } else {
            shifting = nil
        }

        var statusSink: (String) -> Void = Out.status
        core = ProxyCore(trainer: trainer, interceptors: interceptors, scheduler: scheduler,
                         notificationSeq: config.notificationSeq,
                         status: { statusSink($0) }, log: { Out.log("dircon: " + $0) })
        statusSink = { [weak self] s in
            if s.hasPrefix("client connected") { self?.anyClient = true }
            Out.status(s)
        }
        core.onTrainerStateChange = { [weak self] s in self?.trainerState(s) }
    }

    func start() {
        installSignalHandlers()
        queue.async { [self] in
            if let vs = shifting {
                Out.status(vs.ladder.statusLine(vs.gear))
                if KeyboardShiftInput.isAvailable {
                    keyboard.onShift = { vs.shift($0) }
                    keyboard.start()
                    Out.status("shift with ] or ↑ (harder) and [ or ↓ (easier) in this window")
                } else {
                    Out.status("keyboard shifting off: stdin is not a terminal")
                }
                if config.di2.enabled {
                    let d = Di2ShiftInput(name: config.di2.name, queue: queue, scheduler: scheduler,
                                          repeatInterval: Double(config.shifting.repeatIntervalMS) / 1000,
                                          status: Out.status, log: { Out.log("di2: " + $0) })
                    d.onShift = { vs.shift($0) }
                    d.start()
                    di2 = d
                    Out.status("looking for the Di2 (press a shifter to wake it)...")
                }
            }
            Out.status(trainer is SimulatedTrainer ? "starting simulated trainer" : "looking for the trainer...")
            trainer.start()
        }
    }

    // MARK: Trainer state

    private func trainerState(_ s: TrainerState) {
        switch s {
        case .ready:
            Out.status("trainer ready: \(trainer.name)")
            goOnline()
        case .offline:
            advertiser?.stop()
            advertiser = nil
            guard !stopping else { return }
            Out.status("mDNS goodbye sent; Zwift will drop the proxy until the trainer is back")
        default:
            break
        }
    }

    private func makeRecords() -> ServiceRecords? {
        guard let net = NetworkInfo.activeIPv4() else { return nil }
        let id = trainer.identifier.replacingOccurrences(of: "-", with: "")
        let tag = String(id.suffix(4)).uppercased()
        let serialID = CharacteristicID(service: BLEUUID(short: 0x180A), characteristic: BLEUUID(short: 0x2A25))
        let serial = config.serialNumber
            ?? trainer.cachedValue(serialID).flatMap { String(data: $0, encoding: .utf8) }
            ?? "DCP" + id.prefix(12)
        return ServiceRecords(
            instance: config.name ?? "DirCon Proxy \(tag)",
            host: "dirconproxy-\(tag.lowercased())",
            port: config.port,
            ipv4: net.address,
            txt: ["serial-number": serial,
                  "mac-address": config.txt.macAddress(net.mac),
                  "ble-service-uuids": config.txt.serviceUUIDs])
    }

    private func goOnline() {
        guard let r = makeRecords() else {
            if server == nil { Out.fail("no active IPv4 address; Zwift needs the Mac on a network", .network) }
            Out.status("no IPv4 address right now; will re-announce when the network is back")
            return
        }
        records = r
        if server == nil {
            let s = DirConServer(core: core, port: config.port, queue: queue,
                                 bonjourService: config.mdns == .bonjour ? BonjourService.service(for: r) : nil,
                                 status: { [weak self] line in
                                     if line.hasPrefix("client connected") { self?.anyClient = true }
                                     Out.status(line)
                                 })
            server = s
            s.start { [weak self] result in
                switch result {
                case .failure(let e): Out.fail("DirCon port \(r.port): \(e)", .network)
                case .success(let p):
                    Out.status("DirCon listening on \(r.ipv4.map(String.init).joined(separator: ".")):\(p)")
                    self?.advertise(r)
                }
            }
        } else {
            advertise(r)
        }
    }

    private func advertise(_ r: ServiceRecords) {
        if config.mdns == .own, advertiser == nil {
            let a = MDNSResponder(queue: queue, log: { Out.log("mdns: " + $0) })
            a.recordsForNewAddress = { [weak self] in self?.makeRecords() }
            do { try a.start(r) } catch { Out.fail("mDNS: \(error)", .network) }
            advertiser = a
        }
        Out.status("In Zwift pair \"\(r.instance)\", not \"\(trainer.name)\"")
        scheduler.after(60) { [weak self] in
            guard let self, !self.anyClient else { return }
            Out.status("no Zwift client after 60 s: check Zwift's Local Network permission")
        }
    }

    // MARK: Shutdown

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { [weak self] in self?.shutdown() }
            src.resume()
            signals.append(src)
        }
    }

    private func shutdown() {
        guard !stopping else { return }
        stopping = true
        Out.status("stopping...")
        keyboard.stop()
        di2?.stop()
        advertiser?.stop()
        server?.stop()
        trainer.stop()
        // Give the goodbye packets and the BLE disconnect a moment to leave.
        queue.asyncAfter(deadline: .now() + 0.3) {
            Terminal.restore()
            exit(ExitCode32.ok.rawValue)
        }
    }
}
