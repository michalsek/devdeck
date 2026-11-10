import Foundation

/// How much heavy work fits next to the user's own apps. The user's setting is the
/// ceiling; below it, a pool gets what fits in the available memory after a reserve for
/// the user's apps to grow, and while a game is in front, one simulator, emulator or build.
enum PoolRoom {
    struct Limit: Equatable {
        let value: Int
        /// Why it's below the ceiling: "to leave memory for your apps", "while Valheim is in front".
        let reason: String?
    }

    static let baseReserve: UInt64 = 2 << 30
    /// Of what the user's apps take, this share is kept free for them to grow into.
    static let appsGrowth = 0.25

    /// `used` is what's running (and reserved) in the pool now; nothing running is ever
    /// over its limit in a way that stops it, it only holds new work back.
    static func limit(
        _ pool: Pool, ceiling: Int, used: Int, available: UInt64, appsFootprint: UInt64, game: String?
    ) -> Limit {
        var limit = Limit(value: ceiling, reason: nil)
        let reserve = baseReserve + UInt64(Double(appsFootprint) * appsGrowth)
        let fits = used + Int((available > reserve ? available - reserve : 0) / pool.typicalFootprint)
        if fits < limit.value { limit = Limit(value: fits, reason: "to leave memory for your apps") }
        if let game, pool != .devServer, limit.value > 1 { limit = Limit(value: 1, reason: "while \(game) is in front") }
        return limit
    }
}
