import Foundation

public struct CharProps: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let read = CharProps(rawValue: 1 << 0)
    public static let write = CharProps(rawValue: 1 << 1)
    public static let writeWithoutResponse = CharProps(rawValue: 1 << 2)
    public static let notify = CharProps(rawValue: 1 << 3)
    public static let indicate = CharProps(rawValue: 1 << 4)
}

public struct GattCharacteristic: Equatable {
    public let uuid: BLEUUID
    public let props: CharProps
    public init(uuid: BLEUUID, props: CharProps) {
        self.uuid = uuid
        self.props = props
    }
}

public struct GattService: Equatable {
    public let uuid: BLEUUID
    public let characteristics: [GattCharacteristic]
    public init(uuid: BLEUUID, characteristics: [GattCharacteristic]) {
        self.uuid = uuid
        self.characteristics = characteristics
    }
}

/// Identity of a characteristic inside the proxy: (service, characteristic).
public struct CharacteristicID: Hashable, CustomStringConvertible {
    public let service: BLEUUID
    public let characteristic: BLEUUID
    public init(service: BLEUUID, characteristic: BLEUUID) {
        self.service = service
        self.characteristic = characteristic
    }
    public var description: String { "\(service)/\(characteristic)" }
}

/// What Zwift may see: allowlisted SIG services and their SIG characteristics only.
public struct GattModel {
    public static let allowlist: [UInt16] = [0x1826, 0x1818, 0x1816, 0x180D, 0x180A]

    public let exposedServices: [BLEUUID]
    private let exposed: [BLEUUID: [GattCharacteristic]]
    private let byCharacteristic: [BLEUUID: CharacteristicID]
    private let propsByID: [CharacteristicID: CharProps]

    public init(services: [GattService], log: (String) -> Void = { _ in }) {
        var order: [BLEUUID] = []
        var exposed: [BLEUUID: [GattCharacteristic]] = [:]
        var byChar: [BLEUUID: CharacteristicID] = [:]
        var props: [CharacteristicID: CharProps] = [:]
        for service in services {
            guard let s = service.uuid.short, Self.allowlist.contains(s), exposed[service.uuid] == nil else { continue }
            var kept: [GattCharacteristic] = []
            for c in service.characteristics where c.uuid.isSIGBase {
                if let first = byChar[c.uuid] {
                    log("characteristic \(c.uuid) also in service \(service.uuid); exposing only \(first)")
                    continue
                }
                let id = CharacteristicID(service: service.uuid, characteristic: c.uuid)
                byChar[c.uuid] = id
                props[id] = c.props
                kept.append(c)
            }
            order.append(service.uuid)
            exposed[service.uuid] = kept
        }
        exposedServices = order
        self.exposed = exposed
        byCharacteristic = byChar
        propsByID = props
    }

    /// nil when the service is hidden or unknown.
    public func characteristics(of service: BLEUUID) -> [(uuid: BLEUUID, dirconProps: UInt8)]? {
        exposed[service]?.map { ($0.uuid, Self.dirconProperties($0.props)) }
    }

    public func resolve(_ characteristic: BLEUUID) -> CharacteristicID? {
        byCharacteristic[characteristic]
    }

    public func props(_ id: CharacteristicID) -> CharProps? {
        propsByID[id]
    }

    public static func dirconProperties(_ p: CharProps) -> UInt8 {
        var v: UInt8 = 0
        if p.contains(.read) { v |= 0x01 }
        if !p.isDisjoint(with: [.write, .writeWithoutResponse]) { v |= 0x02 }
        if !p.isDisjoint(with: [.notify, .indicate]) { v |= 0x04 }
        return v
    }
}
