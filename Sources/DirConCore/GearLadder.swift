import Foundation

public struct Gear: Equatable {
    public let number: Int
    public let ring: Int
    public let cog: Int
    public let ratio: Double
    /// Virtual ratio ÷ physical ratio.
    public let k: Double
}

/// Every ring × cog combination sorted by ratio into one up/down ladder.
public struct GearLadder {
    public let gears: [Gear]
    /// Index of the gear whose k is nearest 1 (the physical gear).
    public let identityIndex: Int

    public init(rings: [Int], cogs: [Int], physicalRing: Int, physicalCog: Int, minStepPct: Double = 0) {
        let physical = Double(physicalRing) / Double(physicalCog)
        var combos: [(ring: Int, cog: Int, ratio: Double, order: Int)] = []
        for (ri, ring) in rings.enumerated() {
            for cog in cogs {
                combos.append((ring, cog, Double(ring) / Double(cog), ri))
            }
        }
        combos.sort { $0.ratio != $1.ratio ? $0.ratio < $1.ratio : $0.order < $1.order }
        var kept: [(ring: Int, cog: Int, ratio: Double, order: Int)] = []
        for c in combos {
            if let last = kept.last, minStepPct > 0, (c.ratio / last.ratio - 1) * 100 < minStepPct { continue }
            kept.append(c)
        }
        let list = kept.enumerated().map { i, c in
            Gear(number: i + 1, ring: c.ring, cog: c.cog, ratio: c.ratio, k: c.ratio / physical)
        }
        gears = list
        identityIndex = list.indices.min { abs(list[$0].k - 1) < abs(list[$1].k - 1) } ?? 0
    }

    public func statusLine(_ g: Gear) -> String {
        String(format: "gear %d/%d  %d×%d  k=%.3f", g.number, gears.count, g.ring, g.cog, g.k)
    }
}
