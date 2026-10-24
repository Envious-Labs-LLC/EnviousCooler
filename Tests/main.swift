import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() {
    fputs("FAILED: \(message)\n", stderr)
    exit(1)
  }
}
func mustReject(_ message: String, _ operation: () throws -> Void) {
  do {
    try operation()
    expect(false, message)
  } catch { expect(true, message) }
}
func reply(_ packet: Packet, status: UInt8 = 2) -> [UInt8] {
  var response = packet.bytes
  response[0] = status
  return response
}
final class FakeUSB: FeatureTransport {
  var connected = true
  var replies: [[UInt8]]
  var sends = 0
  var reads = 0
  init(_ replies: [[UInt8]]) { self.replies = replies }
  func send(_ bytes: [UInt8]) throws { sends += 1 }
  func read() throws -> [UInt8] {
    reads += 1
    guard !replies.isEmpty else { throw PadError("Disconnected") }
    return replies.removeFirst()
  }
}

let packet = try parse(["fan", "balanced"]).0!
let ok = reply(packet)
let accepted = try validateResponse(ok, to: packet)
expect(accepted, "valid reply accepted")
for length in [0, 1, 89, 91] {
  mustReject("short/oversized reply \(length)") {
    _ = try validateResponse([UInt8](repeating: 0, count: length), to: packet)
  }
}
for index in [1, 6, 7, 88, 89] {
  var bad = ok
  bad[index] ^= 1
  mustReject("mismatched framing byte \(index)") { _ = try validateResponse(bad, to: packet) }
}
var truncated = ok
truncated[5] = 0
truncated[88] = truncated[2...87].reduce(0, ^)
mustReject("truncated arguments") { _ = try validateResponse(truncated, to: packet) }
for status: UInt8 in [0, 3, 4, 5, 255] {
  mustReject("failure status \(status)") {
    _ = try validateResponse(reply(packet, status: status), to: packet)
  }
}
let busy = FakeUSB([reply(packet, status: 1), ok])
let pad = try Pad(transport: busy, settle: {})
_ = try pad.exchange(packet)
expect(busy.sends == 1 && busy.reads == 2, "busy retries reads without resending settings")
let permanentBusy = FakeUSB(Array(repeating: reply(packet, status: 1), count: 5))
let busyPad = try Pad(transport: permanentBusy, settle: {})
mustReject("bounded busy retries") { _ = try busyPad.exchange(packet) }
expect(permanentBusy.reads == 4 && permanentBusy.sends == 1, "busy retry bound")
let failed = FakeUSB([])
let controller = Automatic()
controller.pad = try Pad(transport: failed, settle: {})
controller.lastSent = 800
mustReject("disconnection is surfaced") { try controller.send(1000) }
expect(controller.lastSent == nil, "failed command clears stale acknowledged target")
controller.lastSent = 800
failed.connected = false
mustReject("disconnect detected even without a speed change") { try controller.send(800) }
expect(controller.lastSent == nil, "disconnected cached target becomes unknown")

var elapsed = 0.0
var polls = 0
let timedOut = waitForUSBCompletion(
  deadline: 1, completed: { false }, now: { elapsed },
  poll: {
    polls += 1
    expect(polls <= 12, "deadline cannot hang")
    elapsed += 0.25
  })
expect(!timedOut && polls == 4, "absent completion reaches deadline")
polls = 0
elapsed = 0
let completed = waitForUSBCompletion(
  deadline: 1, completed: { polls == 2 }, now: { elapsed },
  poll: {
    polls += 1
    expect(polls <= 12, "completion wait cannot hang")
    elapsed += 0.25
  })
expect(completed && polls == 2, "completion signal ends wait early")

for temperature in [Double.nan, .infinity, -.infinity, -1, 126] {
  var governor = Governor()
  expect(
    governor.update(temperature: temperature, now: 0, dt: 2) == 3200,
    "invalid temperature fails conservatively")
  expect(governor.smoothed == nil, "invalid temperature is not retained as a reading")
}
let now = Date().timeIntervalSince1970
let identifier = UUID().uuidString
func requestData(_ operation: String = "set", percent: Any = 50, date: Double? = nil) throws -> Data
{
  try JSONSerialization.data(withJSONObject: [
    "id": identifier, "operation": operation, "percent": percent, "createdAt": date ?? now,
  ])
}
for percent: Any in [true, "50", 50.5, -1, 101] {
  mustReject("invalid brightness \(percent)") {
    let request = try JSONDecoder().decode(
      LightingRequest.self, from: requestData(percent: percent))
    try request.validate(now: now)
  }
}
for date in [now - 6, now - 100, now + 0.1] {
  mustReject("expired/future request") {
    let request = try JSONDecoder().decode(LightingRequest.self, from: requestData(date: date))
    try request.validate(now: now)
  }
}
let request = try JSONDecoder().decode(LightingRequest.self, from: requestData())
try request.validate(now: now)
expect(request.percent == 50, "valid request decoded")
mustReject("unknown operation") {
  _ = try JSONDecoder().decode(LightingRequest.self, from: requestData("raw"))
}
let another = LightingRequest(percent: 20)
expect(
  LightingFiles.request(request.id) != LightingFiles.request(another.id),
  "requests cannot overwrite each other")

let date = Date()
let formatter = ISO8601DateFormatter()
expect(stateIsFresh(["updated_at": formatter.string(from: date)], now: date), "fresh state")
expect(
  !stateIsFresh(["updated_at": formatter.string(from: date.addingTimeInterval(-20))], now: date),
  "stale state rejected")
expect(
  !stateIsFresh(["updated_at": formatter.string(from: date.addingTimeInterval(20))], now: date),
  "future state rejected")
expect(!stateIsFresh(["updated_at": true]), "malformed timestamp rejected")
expect(shouldResumeAfterSleep(started: 100, now: 111), "missed wake recovers without last tick timestamp")
expect(!shouldResumeAfterSleep(started: 100, now: 101), "pending sleep is not immediately cancelled")
expect(!shouldResumeAfterSleep(started: nil, now: 111), "missing sleep origin is not invented")
// Pad speed reports and button detection; traces from the 2026-10-24 calibration.
let fanQuery = Packet(tid: 2, cls: 0x0d, cmd: 0x81, size: 3, args: [1, 5])
func speedReply(_ units: UInt8) -> [UInt8] {
  var response = reply(fanQuery)
  response[10] = units
  response[88] = response[2...87].reduce(0, ^)
  return response
}
expect(decodeReportedRPM(speedReply(0x1e)) == 1500, "reported speed decoded in 50 RPM units")
expect(decodeReportedRPM(speedReply(0xe0)) == 11200, "pad-off value decodes for the watcher")
expect(PadWatch.plausible(11200) == nil && PadWatch.plausible(3400) == 3400, "only plausible speeds are shown")
var otherArguments = speedReply(0x1e)
otherArguments[9] = 0
expect(decodeReportedRPM(otherArguments) == nil, "reply for another query is not a speed")
expect(decodeReportedRPM([UInt8](repeating: 0, count: 10)) == nil, "short reply is not a speed")
let speedPad = try Pad(transport: FakeUSB([speedReply(0x40)]), settle: {})
let reportedSpeed = try speedPad.reportedRPM()
expect(reportedSpeed == 3200, "pad reports its speed through a validated exchange")

var watch = PadWatch()
expect(watch.observe(1500, now: 0) == .unknown, "no acknowledged command means no verdict")
watch.acknowledged(1500, now: 0)
for (second, rpm) in [(0, 1500), (2, 1650), (4, 3050), (6, 3400), (10, 3300)] {
  expect(watch.observe(rpm, now: Double(second)) == .settling, "a ramp is never a pad change")
}
watch.acknowledged(3200, now: 0)
for (second, rpm) in [(1, 1650), (3, 2600), (6, 3400), (8, 3350), (11, 3250)] {
  expect(watch.observe(rpm, now: Double(second)) == .settling, "max overshoot settles")
}
expect(watch.observe(3250, now: 13) == .matching, "settled speed within tolerance matches")
watch.acknowledged(1300, now: 20)
expect(watch.observe(1300, now: 33) == .matching, "settled automatic speed matches")
watch.acknowledged(1300, now: 40)
expect(watch.observe(1600, now: 41) == .settling, "one differing reading is not yet a pad change")
expect(watch.observe(1600, now: 43) == .changedOnPad(1600), "a 300 RPM button step after a refresh is a pad change")
watch.acknowledged(1300, now: 43, correction: true)
expect(watch.observe(1600, now: 47) == .settling, "a correction restarts settling")
expect(watch.observe(1300, now: 56) == .matching, "corrected speed matches")
// Recorded switch-off: one stray in-range value, then values far above range.
expect(watch.observe(2150, now: 58) == .settling, "a stray value while switching off is not a pad change")
expect(watch.observe(11200, now: 60) == .settling, "one off reading is not yet pad off")
expect(watch.observe(nil, now: 62) == .unknown, "a failed read is unknown")
expect(watch.observe(10000, now: 64) == .settling, "a failed read breaks the off count")
expect(watch.observe(0, now: 66) == .padOff, "zero or out-of-range twice means the pad is off")
expect(watch.observe(11000, now: 68) == .padOff, "pad stays off")
expect(watch.observe(1700, now: 70) == .settling, "first reading after power-on waits")
expect(watch.observe(1700, now: 72) == .changedOnPad(1700), "pad back on at its own speed")
var softwareOff = PadWatch()
softwareOff.acknowledged(0, now: 0)
expect(softwareOff.observe(0, now: 20) == .matching, "software fan off is never pad off")
expect(softwareOff.observe(0, now: 22) == .matching, "repeated zeros match software fan off")
expect(softwareOff.observe(800, now: 24) == .settling, "one start-up reading waits")
expect(softwareOff.observe(800, now: 26) == .changedOnPad(800), "fan started on the pad")
watch.reset()
expect(watch.observe(0, now: 100) == .unknown, "reset forgets the acknowledged command")
print("\(checks) native adversarial checks passed")
