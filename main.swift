import Darwin
import Foundation

do {
  var arguments = Array(CommandLine.arguments.dropFirst())
  if arguments == ["brightness", "get"] {
    let pad = try Pad()
    try output([
      "brightness_percent": Double(try pad.brightness()) * 100 / 255, "device_acknowledged": true,
    ])
    exit(0)
  }
  #if DIAGNOSTICS
    if arguments.first == "test-rpm", arguments.count == 2 {
      guard let rpm = Int(arguments[1]), (500...750).contains(rpm), rpm % 50 == 0 else {
        throw PadError("Diagnostic speed must be 500 to 750 RPM in steps of 50.")
      }
      // Explicit diagnostic-only override. Normal controls retain the 800 floor.
      // Construct the recovery command before entering the lower-speed state.
      let restorePacket = try parse(["fan", "balanced"]).0!
      let testPacket = Packet(tid: 2, cls: 0x0d, cmd: 1, size: 3, args: [1, 5, UInt8(rpm / 50), 0])
      let pad = try Pad()
      func state(_ value: Int, status: String) {
        let fields: [String: Any] = [
          "mode": "manual", "status": status, "commanded_rpm": value,
          "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fields) {
          try? data.write(to: autoFolder.appendingPathComponent("state.json"), options: .atomic)
        }
      }
      func restore() {
        do {
          _ = try pad.exchange(restorePacket)
          state(1500, status: "manual")
          try output(["phase": "restored", "commanded_rpm": 1500, "device_acknowledged": true])
          fflush(stdout)
        } catch {
          try? output(["phase": "restore_unconfirmed", "error": String(describing: error)])
          fflush(stdout)
          exit(1)
        }
      }
      // Signal handlers run on the main dispatch queue, not in a POSIX handler.
      var handlers: [DispatchSourceSignal] = []
      var starting = true
      var cancellationRequested = false
      for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let handler = DispatchSource.makeSignalSource(signal: number, queue: .main)
        handler.setEventHandler {
          if starting {
            cancellationRequested = true
            return
          }
          restore()
          exit(0)
        }
        handler.resume()
        handlers.append(handler)
      }
      do { _ = try pad.exchange(testPacket) } catch {
        restore()
        throw error
      }
      starting = false
      if cancellationRequested {
        restore()
        exit(0)
      }
      state(rpm, status: "diagnostic_test")
      try output([
        "phase": "test_started", "commanded_rpm": rpm, "requested_test_seconds": 30,
        "device_acknowledged": true, "physical_effect_verified": false,
      ])
      fflush(stdout)
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + 30)
      timer.setEventHandler {
        restore()
        exit(0)
      }
      timer.resume()
      withExtendedLifetime((timer, handlers)) { dispatchMain() }
    }
  #endif
  if arguments == ["sensors"] {
    try output(["source": "Mac hardware temperature sensors", "sensors": Thermals().readings()])
    exit(0)
  }
  if arguments == ["auto-run"] {
    try Automatic().run()
    exit(0)
  }
  if arguments.first == "simulate", arguments.count == 2 {
    let fields = arguments[1].split(separator: ",", omittingEmptySubsequences: false)
    let inputs = fields.compactMap { Double($0) }
    guard !inputs.isEmpty, inputs.count == fields.count,
      inputs.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 125 })
    else { throw PadError("Invalid simulation temperatures.") }
    var governor = Governor()
    let decisions = inputs.enumerated().map { index, temperature -> [String: Any] in
      let rpm = governor.update(temperature: temperature, now: Double(index * 2), dt: 2)
      return ["seconds": index * 2, "temperature": temperature, "rpm": rpm]
    }
    try output(["dry_run": true, "decisions": decisions])
    exit(0)
  }
  if arguments == ["auto-status"] {
    let data = try Data(contentsOf: autoFolder.appendingPathComponent("state.json"))
    FileHandle.standardOutput.write(data + Data([10]))
    exit(0)
  }
  if arguments == ["fan-state"] {
    // Read-only: what the pad reports, which follows its own buttons.
    let pad = try Pad()
    let rpm = try pad.reportedRPM()
    let brightness = try? pad.brightness()
    try output([
      "reported_rpm": rpm.map { $0 as Any } ?? NSNull(),
      "brightness_percent": brightness.map { Double($0) * 100 / 255 as Any } ?? NSNull(),
    ])
    exit(0)
  }
  if arguments == ["--help"] || arguments.isEmpty {
    print(
      "enviouscooler status\nenviouscooler sensors\nenviouscooler auto-status\nenviouscooler fan-state\nenviouscooler fan quiet|balanced|max|off|800..3200\nenviouscooler brightness 0..100\nenviouscooler rgb HEX|spectrum|wave|breath|off\nUse python3 auto-mode.py on|off|status for automatic mode.\nAdd --dry-run to a settings command to inspect its packet without opening USB."
    )
    exit(0)
  }
  let dryRun = arguments.last == "--dry-run"
  if dryRun { arguments.removeLast() }
  let (packet, details, brightnessRaw) = try parse(arguments)
  if dryRun {
    guard let packet else { throw PadError("Dry run is for settings commands.") }
    try output(
      details.merging(
        ["dry_run": true, "packet_hex": hex(packet.bytes)], uniquingKeysWith: { _, new in new }))
  } else {
    let pad = try Pad()
    if let packet {
      _ = try pad.exchange(packet)
      if let raw = brightnessRaw {
        guard try pad.brightness() == UInt8(raw) else {
          throw PadError("Brightness readback did not match the requested value.")
        }
      }
      try output(
        details.merging(
          ["device_acknowledged": true, "physical_effect_verified": false],
          uniquingKeysWith: { _, new in new }))
    } else {
      try output(pad.status())
    }
  }
} catch {
  let data =
    (try? JSONSerialization.data(
      withJSONObject: ["error": String(describing: error)], options: [.sortedKeys])) ?? Data()
  FileHandle.standardError.write(data + Data([10]))
  exit(1)
}
