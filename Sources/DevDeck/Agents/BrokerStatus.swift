import Foundation

/// A script's command on the broker socket, e.g. `{"command": "hold", "device": "<udid>"}`.
struct ScriptCommand: Decodable {
    let command: String
    let device: String?
    let waiter: String?
}

/// The answer to a script's command: what `status` lists, or an error.
struct BrokerStatus: Encodable {
    struct Lease: Encodable {
        let device: String
        let holder: String
        let since: Double
        let turnEnded: Bool?
    }

    struct Waiting: Encodable {
        let id: String
        let devices: [String]
        let agent: String
        let action: String
        let pools: [String]
    }

    struct PoolUse: Encodable {
        let pool: String
        let used: Int
        let limit: Int
    }

    struct Claim: Encodable {
        let device: String
        let session: String
        let workspace: String
        let lastActivity: Double
        let stale: Bool
        let agent: String?
    }

    var ok = true
    var leases: [Lease] = []
    var queue: [String] = []
    var waiting: [Waiting] = []
    var pools: [PoolUse] = []
    var claims: [Claim] = []
    var memoryFree = 0
    var memoryLow = false

    init(book: LeaseBook, claims: [(ClaimStatus, ClaimState, ClaimOwner?)], memoryFree: Int, now: Date) {
        leases = book.leases.values.map { lease in
            switch lease.holder {
            case .agent(let session):
                Lease(device: lease.deviceID, holder: session.label, since: lease.since.timeIntervalSince1970,
                      turnEnded: lease.turnEnded)
            case .user:
                Lease(device: lease.deviceID, holder: "user", since: lease.since.timeIntervalSince1970, turnEnded: nil)
            }
        }
        queue = Array(book.queue)
        waiting = book.waiters.map {
            Waiting(id: $0.id.uuidString, devices: $0.touched, agent: $0.session.label, action: $0.action,
                    pools: $0.pools.map(\.rawValue))
        }
        pools = Pool.allCases.map {
            PoolUse(pool: $0.rawValue, used: book.used($0, now: now), limit: book.resources.limits[$0] ?? 0)
        }
        self.claims = claims.map { status, state, owner in
            Claim(device: status.claim.deviceID, session: status.claim.session, workspace: status.claim.workspace,
                  lastActivity: status.lastActivity.timeIntervalSince1970, stale: state.isStale,
                  agent: owner?.session.label)
        }
        self.memoryFree = memoryFree
        memoryLow = book.resources.memoryLow
    }
}

struct BrokerError: Encodable {
    var ok = false
    let error: String
}
