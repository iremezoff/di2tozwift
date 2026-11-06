import Foundation
import Testing
@testable import DirConCore

struct GattModelTests {
    let vendor = BLEUUID(string: "8ce5cc01-0a4d-11e9-ab14-d663bd873d93")!

    @Test func hidesVendorService() {
        let model = GattModel(services: T600Profile.services)
        #expect(model.exposedServices == [0x180A, 0x1826, 0x1818, 0x1816].map { BLEUUID(short: $0) })
        #expect(!model.exposedServices.contains(vendor))
    }

    @Test func propertyMapping() {
        let model = GattModel(services: T600Profile.services)
        func props(_ s: UInt16, _ c: UInt16) -> UInt8? {
            model.characteristics(of: BLEUUID(short: s))?.first { $0.uuid == BLEUUID(short: c) }?.dirconProps
        }
        #expect(props(0x1826, 0x2AD9) == 0x06)
        #expect(props(0x1826, 0x2AD2) == 0x04)
        #expect(props(0x1826, 0x2ACC) == 0x01)
        #expect(props(0x1816, 0x2A55) == 0x06)
    }

    @Test func duplicateCharacteristicFirstWins() {
        var lines: [String] = []
        let model = GattModel(services: T600Profile.services) { lines.append($0) }
        #expect(model.resolve(BLEUUID(short: 0x2A5D)) ==
                CharacteristicID(service: BLEUUID(short: 0x1818), characteristic: BLEUUID(short: 0x2A5D)))
        #expect(lines.filter { $0.contains("2A5D") }.count == 1)
        // The clashing copy is not listed under CSC.
        let csc = model.characteristics(of: BLEUUID(short: 0x1816))!.map(\.uuid)
        #expect(!csc.contains(BLEUUID(short: 0x2A5D)))
    }

    @Test func vendorCharacteristicInsideAllowedServiceHidden() {
        let cps = GattService(uuid: BLEUUID(short: 0x1818), characteristics: [
            GattCharacteristic(uuid: BLEUUID(short: 0x2A63), props: [.notify]),
            GattCharacteristic(uuid: BLEUUID(string: "a026e005-0a7d-4ab3-97fa-f1500f9feb8b")!, props: [.write, .indicate]),
        ])
        let model = GattModel(services: [cps])
        #expect(model.characteristics(of: BLEUUID(short: 0x1818))!.map(\.uuid) == [BLEUUID(short: 0x2A63)])
        #expect(model.resolve(BLEUUID(string: "a026e005-0a7d-4ab3-97fa-f1500f9feb8b")!) == nil)
    }

    @Test func unknownServiceIsNil() {
        let model = GattModel(services: T600Profile.services)
        #expect(model.characteristics(of: vendor) == nil)
        #expect(model.resolve(BLEUUID(string: "8ce5cc04-0a4d-11e9-ab14-d663bd873d93")!) == nil)
    }

    @Test func propsLookup() {
        let model = GattModel(services: T600Profile.services)
        let cp = model.resolve(BLEUUID(short: 0x2AD9))!
        #expect(model.props(cp) == [.write, .writeWithoutResponse, .indicate])
    }
}
