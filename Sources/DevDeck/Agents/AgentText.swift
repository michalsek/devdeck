import Foundation

/// What agents and the user read about a call DevDeck held back or turned away. These
/// strings are a contract with the agents: they say who is in the way, what to do
/// instead, and when trying again helps.
struct AgentText {
    let book: LeaseBook
    let devices: DeviceIndex
    /// Why the Mac is too loaded for heavy work, e.g. "memory is low (12% free)".
    let memoryProblem: String?
    let now: Date

    /// "boot-device on iPhone 18 Pro" or "npx expo run:ios"
    func describe(_ waiter: LeaseBook.Waiter) -> String {
        waiter.devices.isEmpty ? waiter.action : "\(waiter.action) on \(devicesNamed(waiter))"
    }

    /// Why a call waits: "you're holding iPhone 17", "Codex · web is using Pixel 9", or room.
    func waitReason(_ waiter: LeaseBook.Waiter) -> String {
        if let approval = waiter.approval { return "it needs your OK: it \(approval)" }
        if let needs = waiter.needsUser { return needs }
        let blocked = blockedDevices(waiter)
        guard !blocked.isEmpty else { return roomProblem(waiter) }
        let names = blocked.map(devices.name(of:)).joined(separator: ", ")
        if blocked.contains(where: book.isHeldByUser) { return "you're holding \(names)" }
        if blocked.contains(where: book.queue.contains) { return "you're next in line for \(names)" }
        let agents = blocked.compactMap { book.leases[$0]?.holder.session?.label }
        return "\(agents.first ?? "another agent") is using \(names)"
    }

    /// "1 native build is running (limit 1)" or "memory is low (12% free)".
    func roomProblem(_ waiter: LeaseBook.Waiter) -> String {
        var problems: [String] = []
        if book.resources.memoryLow { problems.append(memoryProblem ?? "memory is low") }
        for pool in waiter.pools where book.isFull(pool, now: now) {
            let used = book.used(pool, now: now)
            problems.append("\(pool.count(used)) \(used == 1 ? "is" : "are") running (limit \(book.resources.limits[pool] ?? 0))")
        }
        return problems.isEmpty ? "it was busy" : problems.joined(separator: " and ")
    }

    /// Whether the call waits for room on the Mac rather than for a device.
    func waitsForRoom(_ waiter: LeaseBook.Waiter) -> Bool {
        waiter.approval == nil && waiter.needsUser == nil && !waiter.pools.isEmpty && blockedDevices(waiter).isEmpty
    }

    /// What the agent reads when its call is turned away after waiting.
    func denyReason(_ waiter: LeaseBook.Waiter?, _ reason: LeaseBook.DenyReason) -> String {
        if reason == .sessionEnded { return "DevDeck: your session ended, so this call was not run." }
        if let waiter, let approval = waiter.approval {
            return "DevDeck: \"\(waiter.action)\" \(approval), so it waits for the user's OK, and "
                + (reason == .dismissed ? "the user said no." : "the user didn't answer in time.")
                + " Act only on your own devices and processes: shut down your simulator by its UDID, stop the"
                + " server you started by its pid, and leave other agents' work alone."
        }
        if let waiter, let needs = waiter.needsUser {
            return "DevDeck: \(needs), so \"\(waiter.action)\" waited for the user, and "
                + (reason == .dismissed ? "the user turned it away." : "the user didn't get to it in time.")
                + " Ask the user to sort out the device, then try again."
        }
        if let waiter, waitsForRoom(waiter) {
            return "DevDeck: the Mac is busy, so \"\(waiter.action)\" was not run: \(roomProblem(waiter))."
                + (reason == .dismissed ? " The user turned it away." : " It waited too long.")
                + " The user set these limits to keep the Mac responsive. Wait for the running work to finish"
                + " (or stop work of yours you no longer need), then try again."
        }
        // Free devices of the same kind as the ones it wanted.
        let candidates = Set(devices.alternatives(for: waiter?.touched ?? []).values.joined())
        let free = devices.running
            .filter { candidates.contains($0.id) && book.leases[$0.id] == nil && !book.queue.contains($0.id) }
            .map(\.name)
        var text = "DevDeck: \(devicesNamed(waiter)) is in use by \(blockers(of: waiter)), so this call was not run"
        text += reason == .dismissed ? " (the user turned it away)." : " (it waited too long)."
        text += " Don't use that device until it's free."
        if !free.isEmpty { text += " Devices nobody is using: \(free.joined(separator: ", "))." }
        text += " Work on something else or ask the user, then try again."
        return text
    }

    /// What the agent reads when it's sent to a free device instead of waiting.
    func redirectReason(_ waiter: LeaseBook.Waiter, free: [String]) -> String {
        let names = free.map(devices.name(of:))
        return "DevDeck: \(devicesNamed(waiter)) is in use by \(blockers(of: waiter)), so this call was not run."
            + " Use \(names.count == 1 ? names[0] : "one of: " + names.joined(separator: ", ")) instead"
            + " (\(free.count == 1 ? "it's" : "they're") the same kind and nobody is using \(free.count == 1 ? "it" : "them")),"
            + " or wait and try this device again later. IDs: \(free.joined(separator: ", "))."
    }

    /// What the agent reads when it would boot a device while one of the same kind is free.
    func useRunningReason(_ waiter: LeaseBook.Waiter, free: [String]) -> String {
        let names = free.map(devices.name(of:))
        let first = names[0]
        let insist = Format.duration(book.timing.insist)
        return "DevDeck: \(names.count == 1 ? "\(first) is" : names.joined(separator: ", ") + " are") already running"
            + " and nobody is using \(names.count == 1 ? "it" : "them"), so booting \(devicesNamed(waiter)) was not run"
            + " (each simulator or emulator takes a few GB of memory). Use \(first) instead (ID \(free[0]))."
            + " If you need \(devicesNamed(waiter)) specifically, run the same command again within \(insist)"
            + " and DevDeck will let it through."
    }

    /// What the agent reads when it reaches for an Android emulator and the user wants
    /// Android testing on a physical phone.
    static func phonesOnly(_ phones: [DeviceItem]) -> String {
        var text = "DevDeck: the user wants Android apps tested on a physical phone, not an emulator"
            + " (emulators behave differently and slow the Mac down), so this call was not run."
        if phones.isEmpty {
            text += " No Android phone is connected. Ask the user to connect one with USB debugging on"
                + " (DevDeck has told them), then try again with its serial (adb devices)."
        } else {
            text += " Use " + phones.map { "\($0.name) (adb -s \($0.serial ?? $0.id))" }.joined(separator: " or ") + " instead."
        }
        return text
    }

    // MARK: Pieces

    private func blockedDevices(_ waiter: LeaseBook.Waiter) -> [String] {
        waiter.touched.filter { book.isBlocked($0, for: waiter.session, now: now) }
    }

    /// Who's in the way on the devices a call wanted: "the user" or "another agent (Codex · web)".
    private func blockers(of waiter: LeaseBook.Waiter?) -> String {
        guard let waiter else { return "someone else" }
        let holders = waiter.touched.compactMap { book.leases[$0]?.holder }.filter { $0.session?.id != waiter.session.id }
        if holders.contains(.user) { return "the user" }
        let agents = holders.compactMap(\.session?.label)
        return agents.isEmpty ? "someone else" : "another agent (\(agents.joined(separator: ", ")))"
    }

    private func devicesNamed(_ waiter: LeaseBook.Waiter?) -> String {
        guard let waiter, !waiter.touched.isEmpty else { return "this device" }
        return waiter.touched.map(devices.name(of:)).joined(separator: ", ")
    }
}
