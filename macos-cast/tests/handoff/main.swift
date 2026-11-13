import Foundation

func check(_ condition: @autoclosure () -> Bool, _ text: String) {
    if !condition() { fatalError(text) }
}
func ack(_ command: Data, enabled: Bool, success: Bool = true) -> Data {
    Data(command.suffix(4)) + Data([enabled ? 1 : 0, success ? 0 : 1])
}

let route = AudioHandoff()
route.select(true, now: 0)
let first = route.command(now: 0)
check(!route.confirmed, "Mac must wait for tablet mute confirmation")
check(route.accept(ack(first, enabled: true), now: 0.1) == .accepted, "Fresh confirmation rejected")
check(route.confirmed, "Valid tablet mute did not enable Mac")
let heartbeat = route.command(now: 0.75)
check(route.accept(ack(first, enabled: true), now: 0.8) == .ignored, "Stale acknowledgment accepted")
check(route.accept(ack(heartbeat, enabled: true), now: 0.85) == .accepted, "Heartbeat rejected")
check(!route.expired(now: 2.9), "Background scheduling jitter prematurely ended playback")
check(!route.expired(now: 3.84) && route.expired(now: 3.86), "Lease must expire before tablet unmutes")
route.select(false, now: 4)
check(!route.confirmed, "Disable must silence Mac before requesting tablet restore")
let off = route.command(now: 4)
check(route.accept(ack(heartbeat, enabled: true), now: 4.1) == .ignored, "Old enable resurrected Mac audio")
check(route.accept(ack(off, enabled: false), now: 4.2) == .accepted && !route.confirmed, "Tablet restore failed")
route.select(true, now: 5)
let failed = route.command(now: 5)
check(route.accept(ack(failed, enabled: false, success: false), now: 5.1) == .rejected,
      "Tablet mute failure was accepted")
check(!route.confirmed, "Mute failure enabled Mac")
route.select(true, now: 6)
let late = route.command(now: 6)
check(route.accept(ack(late, enabled: true), now: 6.95) == .ignored, "Late acknowledgment renewed lease")
check(route.expired(now: 9), "Missing acknowledgment did not expire")
route.select(true, now: 10)
let olderHeartbeat = route.command(now: 10)
_ = route.command(now: 10.75)
check(route.accept(ack(olderHeartbeat, enabled: true), now: 10.8) == .accepted,
      "A newer heartbeat invalidated a fresh same-selection confirmation")
route.select(false, now: 10.81)
check(!route.confirmed && route.accept(ack(olderHeartbeat, enabled: true), now: 10.82) == .ignored,
      "Old selection replay enabled Mac audio")
print("PASS: acknowledged handoff, stale/late replies, mute failure, immediate disable, heartbeat expiry")
