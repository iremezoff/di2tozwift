import Foundation
import Testing
@testable import DirConCore

let defaultCogs = [11, 12, 13, 14, 15, 17, 19, 21, 24, 27, 30, 34]
func defaultLadder(minStepPct: Double = 0) -> GearLadder {
    GearLadder(rings: [52, 36], cogs: defaultCogs, physicalRing: 52, physicalCog: 14, minStepPct: minStepPct)
}

struct GearLadderTests {
    @Test func ladderMatchesTable() {
        let ladder = defaultLadder()
        let expected: [(Int, Int)] = [
            (36, 34), (36, 30), (36, 27), (36, 24), (52, 34), (36, 21), (52, 30), (36, 19), (52, 27), (36, 17),
            (52, 24), (36, 15), (52, 21), (36, 14), (52, 19), (36, 13), (36, 12), (52, 17), (36, 11), (52, 15),
            (52, 14), (52, 13), (52, 12), (52, 11),
        ]
        #expect(ladder.gears.count == 24)
        #expect(ladder.gears.map { [$0.ring, $0.cog] } == expected.map { [$0.0, $0.1] })
        #expect(ladder.gears.map(\.number) == Array(1...24))
        func r4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }
        let checks: [(Int, Double, Double)] = [(1, 1.0588, 0.2851), (5, 1.5294, 0.4118), (21, 3.7143, 1.0000), (24, 4.7273, 1.2727)]
        for (n, ratio, k) in checks {
            #expect(r4(ladder.gears[n - 1].ratio) == ratio)
            #expect(r4(ladder.gears[n - 1].k) == k)
        }
        #expect(ladder.gears[ladder.identityIndex].number == 21)
    }

    @Test func minStepFourPercentKeeps17() {
        let ladder = defaultLadder(minStepPct: 4)
        #expect(ladder.gears.count == 17)
        let steps = zip(ladder.gears.dropFirst(), ladder.gears).map { ($0.ratio / $1.ratio - 1) * 100 }
        #expect(steps.allSatisfy { $0 >= 5.85 && $0 <= 14.35 })
        #expect(ladder.gears.map(\.number) == Array(1...17))
    }

    @Test func statusLineFormat() {
        let ladder = defaultLadder()
        #expect(ladder.statusLine(ladder.gears[13]) == "gear 14/24  36×14  k=0.692")
        #expect(ladder.statusLine(ladder.gears[20]) == "gear 21/24  52×14  k=1.000")
    }
}
