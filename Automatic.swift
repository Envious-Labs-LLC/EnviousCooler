import Darwin
import Foundation
import IOKit.pwr_mgt

let autoFolder = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/EnviousCooler")

final class Automatic {
  var thermals: Thermals?
  var pad: Pad?
  var governor = Governor()
  var lastTime: Double?
  var lastSent: Int?
  var brightnessPercent: Double?
  var lastBrightnessAttempt = -Double.infinity
  var sleeping = false
  var sleepStarted: Double?
  var inTick = false
  var stopping = false
  var pendingSleep: Int?
  var pendingStop = false
  var powerConnection: io_connect_t = 0
  var powerPort: IONotificationPortRef?
  var notifier: io_object_t = 0
  var signals: [DispatchSourceSignal] = []
  var lastLog = ""
  var lastLogTime = 0.0

  func writeState(_ fields: [String: Any]) {
    var state = fields
    state["pid"] = getpid()
    state["updated_at"] = ISO8601DateFormatter().string(from: Date())
    if state["mode"] == nil { state["mode"] = "automatic" }
    if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
      try? data.write(to: autoFolder.appendingPathComponent("state.json"), options: .atomic)
    }
  }
  func log(_ message: String) {
    let now = ProcessInfo.processInfo.systemUptime
    guard message != lastLog || now - lastLogTime >= 600 else { return }
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
    fflush(stdout)
    lastLog = message
    lastLogTime = now
  }
  func send(_ rpm: Int) throws {
    if pad == nil {
      pad = try Pad()
      lastSent = nil
      brightnessPercent = nil
    }
    do { try pad!.validateConnection() } catch {
      lastSent = nil
      throw error
    }
    if lastSent != rpm {
      let arguments = rpm == 0 ? ["fan", "off"] : ["fan", String(rpm)]
      let packet = try parse(arguments).0!
      lastSent = nil
      _ = try pad!.exchange(packet)
      lastSent = rpm
    }
  }
  func lighting() {
    guard let pad else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if brightnessPercent == nil && now - lastBrightnessAttempt >= 10 {
      lastBrightnessAttempt = now
      if let raw = try? pad.brightness() { brightnessPercent = Double(raw) * 100 / 255 }
    }
    try? LightingFiles.prepare()
    LightingFiles.cleanup()
    guard let urls = try? LightingFiles.pending(), let url = urls.first else { return }
    let filenameID = UUID(uuidString: String(url.lastPathComponent.dropLast(13)))!
    defer { try? FileManager.default.removeItem(at: url) }
    var response: [String: Any] = ["id": filenameID.uuidString]
    do {
      let request = try JSONDecoder().decode(LightingRequest.self, from: LightingFiles.read(url))
      guard request.id == filenameID else {
        throw PadError("Lighting request identity does not match its filename.")
      }
      try request.validate(now: Date().timeIntervalSince1970)
      switch request.operation {
      case .set:
        let raw = UInt8((Double(request.percent!) * 255 / 100).rounded())
        _ = try pad.exchange(Packet(cls: 0x0f, cmd: 4, size: 3, args: [1, 0, raw]))
        guard try pad.brightness() == raw else {
          throw PadError("Brightness readback did not match.")
        }
        brightnessPercent = Double(raw) * 100 / 255
      case .get:
        brightnessPercent = Double(try pad.brightness()) * 100 / 255
      }
      response["brightness_percent"] = brightnessPercent
      response["device_acknowledged"] = true
    } catch {
      brightnessPercent = nil
      response["error"] = String(describing: error)
    }
    do {
      try JSONSerialization.data(withJSONObject: response)
        .write(to: LightingFiles.response(filenameID), options: .atomic)
    } catch { log("Could not save lighting receipt: \(error)") }
  }
  func prepareSleep() {
    sleeping = true
    sleepStarted = monotonicNow()
    do {
      try send(0)
      log("Sleep: pad fan off.")
    } catch { log("Sleep: fan-off unconfirmed: \(error)") }
    pad = nil
    thermals = nil
    lastSent = nil
    lastTime = nil
    writeState(["status": "sleeping", "commanded_rpm": NSNull()])
  }
  func wake() {
    sleeping = false
    sleepStarted = nil
    governor = Governor()
    lastTime = nil
    log("Wake: refreshing sensors and pad.")
    tick()
  }
  func tick() {
    guard !stopping && !inTick else { return }
    // A resumed timer plus a continuous-clock gap also recovers a missed
    // wake notification. macOS cannot execute this timer during actual sleep.
    if sleeping {
      guard shouldResumeAfterSleep(started: sleepStarted, now: monotonicNow()) else { return }
      sleeping = false
      sleepStarted = nil
      governor = Governor()
      self.lastTime = nil
      log("Resuming after sleep gap.")
    }
    inTick = true
    defer {
      inTick = false
      if let token = pendingSleep {
        pendingSleep = nil
        prepareSleep()
        IOAllowPowerChange(powerConnection, token)
      }
      if pendingStop {
        pendingStop = false
        stop()
      }
    }
    let now = monotonicNow()
    let dt = lastTime.map { now - $0 } ?? 2
    lastTime = now
    // A long gap (sleep or a stalled process) invalidates smoothing/history.
    if dt > 10 {
      governor = Governor()
      thermals = nil
      pad = nil
      lastSent = nil
    }
    var validTemperature = false
    do {
      if thermals == nil { thermals = try Thermals() }
      let rows = try thermals!.readings()
      let selected = rows.filter {
        ["cpu", "gpu", "soc_die"].contains($0["kind"] as? String ?? "")
      }
      guard let temperature = selected.compactMap({ $0["celsius"] as? Double }).max() else {
        throw PadError(
          "No identified chip-temperature sensors. Automatic cooling cannot use unrelated sensors.")
      }
      let critical = ProcessInfo.processInfo.thermalState == .critical
      validTemperature = true
      let rpm = governor.update(temperature: temperature, now: now, dt: dt, critical: critical)
      // Periodic refresh catches a pad power-cycle without USB removal.
      if Int(now / 30) != Int((now - min(dt, 5)) / 30) { lastSent = nil }
      try send(rpm)
      lighting()
      writeState([
        "status": "running", "temperature_celsius": temperature,
        "smoothed_temperature_celsius": governor.smoothed!,
        "sensor_count": selected.count, "source": "hottest identified Mac chip sensor",
        "commanded_rpm": rpm, "measured_rpm": NSNull(),
        "brightness_percent": brightnessPercent.map { $0 as Any } ?? NSNull(),
      ])
      log("Fan target \(rpm) RPM.")
    } catch {
      thermals = nil
      // Sensor failure needs conservative cooling. USB loss doesn't: keep
      // following real temperatures so reconnection resumes at the right speed.
      if !validTemperature {
        do { try send(3200) } catch {
          pad = nil
          lastSent = nil
        }
        governor = Governor()
        governor.rpm = 3200
      } else {
        pad = nil
        lastSent = nil
      }
      writeState([
        "status": "degraded", "error": String(describing: error),
        "reason": validTemperature ? "fan_control_error" : "temperature_unavailable",
        "commanded_rpm": lastSent.map { $0 as Any } ?? NSNull(), "temperature_celsius": NSNull(),
      ])
      log(
        validTemperature
          ? "Waiting for pad connection: \(error)"
          : "Temperature unavailable; maximum cooling where reachable: \(error)")
    }
  }
  func stop() {
    if inTick {
      pendingStop = true
      return
    }
    stopping = true
    if !sleeping {
      do { try send(1500) } catch {
        lastSent = nil
        log("Stop: balanced fan setting unconfirmed: \(error)")
      }
    }
    writeState([
      "mode": "manual", "status": "stopped", "restore_acknowledged": lastSent == 1500,
      "restore_skipped_for_sleep": sleeping,
      "commanded_rpm": lastSent.map { $0 as Any } ?? NSNull(),
    ])
    pad = nil
    exit(0)
  }
  func run() throws {
    try FileManager.default.createDirectory(at: autoFolder, withIntermediateDirectories: true)
    let fd = open(
      autoFolder.appendingPathComponent("automatic.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW,
      S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw PadError("Cannot open automatic-mode lock.") }
    defer {
      flock(fd, LOCK_UN)
      close(fd)
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw PadError("Automatic mode is already running.")
    }
    // Verify a genuine chip reading before starting a persistent controller.
    thermals = try Thermals()
    guard
      try thermals!.readings().contains(where: {
        ["cpu", "gpu", "soc_die"].contains($0["kind"] as? String ?? "")
      })
    else {
      throw PadError("No identified chip sensors; refusing to enable automatic mode.")
    }
    powerConnection = IORegisterForSystemPower(
      Unmanaged.passUnretained(self).toOpaque(), &powerPort,
      { ref, _, type, argument in
        guard let ref else { return }
        let controller = Unmanaged<Automatic>.fromOpaque(ref).takeUnretainedValue()
        // IOMessage.h macros aren't imported by Swift: sys_iokit | common | code.
        if type == 0xe000_0280 && controller.inTick {
          controller.sleeping = true
          controller.pendingSleep = Int(bitPattern: argument)
          return
        }
        if type == 0xe000_0280 { controller.prepareSleep() }
        if type == 0xe000_0280 || type == 0xe000_0270 {
          IOAllowPowerChange(controller.powerConnection, Int(bitPattern: argument))
        }
        if type == 0xe000_0300 || (type == 0xe000_0290 && controller.sleeping) { controller.wake() }
      }, &notifier)
    guard powerConnection != 0, let port = powerPort,
      let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue()
    else {
      throw PadError("Cannot register sleep/wake handling; refusing automatic mode.")
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    for number in [SIGTERM, SIGINT, SIGHUP] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { self.stop() }
      signals.append(source)
      source.resume()
    }
    tick()
    let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.tick() }
    withExtendedLifetime(timer) { CFRunLoopRun() }
  }
}
