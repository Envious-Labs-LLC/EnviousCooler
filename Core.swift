import Foundation

struct PadError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}

func hex(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}

struct Governor {
  var smoothed: Double?
  var rpm = 800
  var lowerSince: Double?
  // 500 RPM was accepted over USB but coincided with red-light restarts.
  // Keep headroom above the reported low-speed protection threshold.
  static let points: [(Double, Double)] = [
    (45, 800), (55, 1000), (65, 1400), (75, 2200), (85, 3200),
  ]
  static func target(_ temperature: Double) -> Int {
    guard temperature.isFinite else { return 3200 }
    var value = points.last!.1
    if temperature <= points[0].0 {
      value = points[0].1
    } else {
      for index in 1..<points.count where temperature <= points[index].0 {
        let a = points[index - 1]
        let b = points[index]
        value = a.1 + (temperature - a.0) / (b.0 - a.0) * (b.1 - a.1)
        break
      }
    }
    return min(3200, max(800, Int((value / 50).rounded()) * 50))
  }
  mutating func update(temperature: Double, now: Double, dt: Double, critical: Bool = false) -> Int
  {
    if !temperature.isFinite || temperature <= 0 || temperature > 125 || !now.isFinite
      || !dt.isFinite || dt < 0 || critical || temperature >= 95
    {
      smoothed = temperature.isFinite && temperature > 0 && temperature <= 125 ? temperature : nil
      rpm = 3200
      lowerSince = nil
      return rpm
    }
    let elapsed = min(5, max(0, dt))
    let prior = smoothed ?? temperature
    smoothed = prior + (1 - exp(-elapsed / 10)) * (temperature - prior)
    let wanted = Self.target(smoothed!)
    if wanted >= rpm + 100 {
      lowerSince = nil
      rpm += min(wanted - rpm, Int(elapsed * 100 / 50) * 50)
    } else if wanted <= rpm - 100 {
      if lowerSince == nil { lowerSince = now }
      if now - lowerSince! >= 20 {
        rpm -= min(rpm - wanted, Int(elapsed * 50 / 50) * 50)
      }
    } else {
      lowerSince = nil
    }
    return rpm
  }
}

func validateResponse(_ response: [UInt8], to packet: Packet) throws -> Bool {
  guard response.count == 90 else {
    throw PadError("Incomplete USB response; setting is unconfirmed.")
  }
  guard response[1] == packet.bytes[1], response[6] == packet.bytes[6],
    response[7] == packet.bytes[7],
    response[5] <= 80, response[89] == 0,
    response[88] == response[2...87].reduce(0, ^)
  else {
    throw PadError("USB response does not match this command; setting is unconfirmed.")
  }
  if response[0] == 1 { return false }
  guard response[0] == 2, response[5] >= packet.bytes[5] else {
    throw PadError("Device rejected or truncated the command response (status \(response[0])).")
  }
  return true
}

// Only documented commands are reachable through this CLI. No raw packets,
// firmware writes, device-mode changes, or arbitrary report IDs are exposed.
struct Packet {
  let bytes: [UInt8]
  init(tid: UInt8 = 0x1f, cls: UInt8, cmd: UInt8, size: UInt8, args: [UInt8]) {
    precondition(args.count <= 80)
    var p = [UInt8](repeating: 0, count: 90)
    p[1] = tid
    p[5] = size
    p[6] = cls
    p[7] = cmd
    for (i, byte) in args.enumerated() { p[8 + i] = byte }
    p[88] = p[2...87].reduce(0, ^)
    bytes = p
  }
}

func output(_ value: [String: Any]) throws {
  let data = try JSONSerialization.data(
    withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}

func parse(_ arguments: [String]) throws -> (Packet?, [String: Any], Int?) {
  guard let command = arguments.first else {
    throw PadError(
      "Use status, fan quiet|balanced|max|off|800..3200, brightness 0..100, or rgb HEX|spectrum|wave|breath|off."
    )
  }
  if command == "status", arguments.count == 1 { return (nil, [:], nil) }
  guard arguments.count == 2 else { throw PadError("This command needs exactly one value.") }
  let value = arguments[1].lowercased()
  if command == "brightness" {
    guard let percent = Int(value), (0...100).contains(percent) else {
      throw PadError("Brightness must be 0 to 100.")
    }
    let raw = UInt8((Double(percent) * 255 / 100).rounded())
    return (
      Packet(cls: 0x0f, cmd: 4, size: 3, args: [1, 0, raw]),
      ["brightness_percent_requested": percent], Int(raw)
    )
  }
  if command == "fan" {
    if value == "off" {
      return (
        Packet(tid: 2, cls: 0x0d, cmd: 0x10, size: 3, args: [0, 6]), ["fan_requested": "off"], nil
      )
    }
    let presets = ["quiet": 800, "balanced": 1500, "max": 3200]
    guard let rpm = presets[value] ?? Int(value), (800...3200).contains(rpm), rpm % 50 == 0 else {
      throw PadError(
        "Fan speed must be 800 to 3200 RPM in steps of 50, or quiet/balanced/max/off. Lower speeds are blocked because this pad cycled at low RPM."
      )
    }
    let units = rpm / 50
    return (
      Packet(tid: 2, cls: 0x0d, cmd: 1, size: 3, args: [1, 5, UInt8(units), 0]),
      ["commanded_rpm": rpm, "measured_rpm": NSNull()], nil
    )
  }
  if command == "rgb" {
    let effects: [String: [UInt8]] = [
      "off": [1, 0, 0], "spectrum": [1, 0, 3], "wave": [1, 0, 4, 1, 40], "breath": [1, 0, 2],
    ]
    if let args = effects[value] {
      return (Packet(cls: 0x0f, cmd: 2, size: 6, args: args), ["lighting_requested": value], nil)
    }
    let color = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard color.count == 6, color.allSatisfy({ $0.isASCII && $0.isHexDigit }),
      let number = UInt32(color, radix: 16)
    else {
      throw PadError("Use a six-digit colour such as 00ff00, or spectrum/wave/breath/off.")
    }
    let args: [UInt8] = [
      1, 0, 1, 0, 0, 1, UInt8((number >> 16) & 255), UInt8((number >> 8) & 255),
      UInt8(number & 255),
    ]
    return (Packet(cls: 0x0f, cmd: 2, size: 9, args: args), ["lighting_requested": color], nil)
  }
  throw PadError("Unknown command: \(command).")
}
