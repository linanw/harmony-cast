import Foundation

// Mac's playback lease expires before the tablet's 6 second mute lease,
// leaving room for reply latency, timer jitter and the bounded playback queue.
// Only fresh confirmations from the current selection can enable playback.
final class AudioHandoff {
    enum Reply { case accepted, rejected, ignored }
    private(set) var desired = false
    private(set) var confirmed = false
    private(set) var serial: UInt32 = 0
    private(set) var sentAt: TimeInterval = -.infinity
    private var requestedAt: TimeInterval = 0
    private var acknowledgedAt: TimeInterval?
    private var pending: [UInt32: TimeInterval] = [:]

    func select(_ enabled: Bool, now: TimeInterval) {
        desired = enabled
        confirmed = false
        acknowledgedAt = nil
        requestedAt = now
        pending.removeAll()
    }

    func command(now: TimeInterval) -> Data {
        serial &+= 1
        if serial == 0 { serial = 1 }
        sentAt = now
        pending = pending.filter { now - $0.value < 0.9 }
        pending[serial] = now
        return Data([0xa1, desired ? 1 : 0,
                     UInt8(truncatingIfNeeded: serial >> 24), UInt8(truncatingIfNeeded: serial >> 16),
                     UInt8(truncatingIfNeeded: serial >> 8), UInt8(truncatingIfNeeded: serial)])
    }

    func accept(_ bytes: Data, now: TimeInterval) -> Reply {
        guard bytes.count == 6 else { return .ignored }
        let values = [UInt8](bytes)
        let received = values.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let issuedAt = pending.removeValue(forKey: received), now - issuedAt < 0.9 else { return .ignored }
        guard values[5] == 0, values[4] == (desired ? 1 : 0) else {
            confirmed = false
            return .rejected
        }
        acknowledgedAt = now
        confirmed = desired
        return .accepted
    }

    func expired(now: TimeInterval) -> Bool {
        desired && now - (acknowledgedAt ?? requestedAt) >= 3
    }
}
