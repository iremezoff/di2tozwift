import Foundation

/// GATT layout and static values read from a Magene T600 (`T600_35381`) on Nov 6, 2026.
/// Used by the simulated trainer and by tests.
public enum T600Profile {
    public static let name = "T600_35381"
    public static let vendorService = BLEUUID(string: "8ce5cc01-0a4d-11e9-ab14-d663bd873d93")!

    private static func vendor(_ n: UInt8) -> BLEUUID {
        BLEUUID(string: String(format: "8ce5cc%02x-0a4d-11e9-ab14-d663bd873d93", n))!
    }

    private static func c(_ u: UInt16, _ p: CharProps) -> GattCharacteristic {
        GattCharacteristic(uuid: BLEUUID(short: u), props: p)
    }

    public static let services: [GattService] = [
        GattService(uuid: vendorService, characteristics: [2, 3, 5, 6].map {
            GattCharacteristic(uuid: vendor($0), props: [.write, .notify, .writeWithoutResponse])
        } + [GattCharacteristic(uuid: vendor(4), props: [.read])]),
        GattService(uuid: BLEUUID(short: 0x180A), characteristics: [
            c(0x2A29, .read), c(0x2A24, .read), c(0x2A25, .read), c(0x2A27, .read), c(0x2A26, .read), c(0x2A28, .read),
        ]),
        GattService(uuid: BLEUUID(short: 0x1826), characteristics: [
            c(0x2AD9, [.indicate, .write, .writeWithoutResponse]), c(0x2AD2, .notify), c(0x2ADA, .notify),
            c(0x2AD6, .read), c(0x2AD5, .read), c(0x2AD8, .read), c(0x2ACC, .read),
        ]),
        GattService(uuid: BLEUUID(short: 0x1818), characteristics: [
            c(0x2A63, .notify), c(0x2A65, .read), c(0x2A5D, .read),
        ]),
        GattService(uuid: BLEUUID(short: 0x1816), characteristics: [
            c(0x2A5B, .notify), c(0x2A5C, .read), c(0x2A5D, .read), c(0x2A55, [.indicate, .write]),
        ]),
    ]

    public static let feature = Data([0x02, 0x40, 0x00, 0x00, 0x08, 0x20, 0x00, 0x00])

    private static func id(_ s: UInt16, _ ch: UInt16) -> CharacteristicID {
        CharacteristicID(service: BLEUUID(short: s), characteristic: BLEUUID(short: ch))
    }

    /// Values of the readable characteristics, as read from the trainer.
    public static let staticValues: [CharacteristicID: Data] = [
        id(0x180A, 0x2A29): Data("Magene".utf8),
        id(0x180A, 0x2A24): Data("23".utf8),
        id(0x180A, 0x2A25): Data("P010224701G158W0035".utf8),
        id(0x180A, 0x2A27): Data("1".utf8),
        id(0x180A, 0x2A26): Data("0.112".utf8),
        id(0x180A, 0x2A28): Data("0.112".utf8),
        id(0x1826, 0x2AD6): Data([0x00, 0x00, 0x64, 0x00, 0x01, 0x00]),
        id(0x1826, 0x2AD5): Data([0x00, 0x00, 0xC8, 0x00, 0x01, 0x00]),
        id(0x1826, 0x2AD8): Data([0x14, 0x00, 0x98, 0x08, 0x01, 0x00]),
        id(0x1826, 0x2ACC): feature,
        id(0x1818, 0x2A65): Data([0x00, 0x00, 0x00, 0x00]),
        id(0x1818, 0x2A5D): Data([0x0C]),
        id(0x1816, 0x2A5C): Data([0x02, 0x00]),
        id(0x1816, 0x2A5D): Data([0x00]),
    ]
}
