import AppKit
import Darwin
import Foundation

final class CoolingApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/EnviousCooler")
  var instanceLock: Int32 = -1
  var item: NSStatusItem!
  var window: NSWindow?
  var timer: Timer?
  var busy = false
  var menuOpen = false
  var brightnessBusy = false
  var brightnessValue: Int?
  var brightnessInvalidAfter: Date?
  let brightnessSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
  let brightnessLabel = NSTextField(labelWithString: "—")
  var reading: [String: Any] = [:]
  var thermals: Thermals?
  // Every helper process runs here, so a pad poll never collides with a command.
  let usbQueue = DispatchQueue(label: "co.enviouslabs.enviouscooler.usb")
  var generation = 0
  var pollPending = false
  var manualWatch = PadWatch()
  var manualCommandStamp: String?
  var manualReported: Int?
  var manualCondition = PadCondition.unknown
  var changedOnPad: Int?
  var overrideNote: String?
  var lastError: String?
  let temperatureLabel = NSTextField(labelWithString: "—")
  let fanLabel = NSTextField(labelWithString: "—")
  let modeLabel = NSTextField(labelWithString: "—")
  let autoButton = NSButton(checkboxWithTitle: "Automatic cooling", target: nil, action: nil)
  var buttons: [NSButton] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    instanceLock = open(
      folder.appendingPathComponent("menu.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW,
      S_IRUSR | S_IWUSR)
    guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
      NSApp.terminate(nil)
      return
    }
    NSApp.setActivationPolicy(.accessory)
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = BrandIcon.menuBarImage()
    item.button?.imagePosition = .imageLeading
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
      self.refresh()
      self.pollPad()
    }
    if CommandLine.arguments.contains("--dashboard") { showDashboard() }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showDashboard()
    return true
  }

  var automaticEnabled: Bool {
    FileManager.default.fileExists(
      atPath: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/co.enviouslabs.enviouscooler.plist").path)
  }

  func active() -> Bool {
    guard reading["mode"] as? String == "automatic", let pid = reading["pid"] as? Int32, pid > 1,
      kill(pid, 0) == 0, let timestamp = reading["updated_at"] as? String,
      let date = ISO8601DateFormatter().date(from: timestamp)
    else { return false }
    return stateIsFresh(reading)
      || (reading["status"] as? String == "sleeping" && Date().timeIntervalSince(date) >= -2)
  }
  // Manual modes have no controller reporting temperature, so read the sensors here.
  func chipTemperature() -> Double? {
    do {
      if thermals == nil { thermals = try Thermals() }
      return try thermals!.chipTemperature().celsius
    } catch {
      thermals = nil
      return nil
    }
  }
  // The last acknowledged manual preset; automatic cooling selects none.
  var selectedRPM: Int? {
    !active() && reading["mode"] as? String == "manual" && changedOnPad == nil
      && manualCondition != .padOff ? reading["commanded_rpm"] as? Int : nil
  }
  func rpmText(_ rpm: Int) -> String {
    NumberFormatter.localizedString(from: rpm as NSNumber, number: .decimal) + " RPM"
  }
  // Manual mode has no controller, so ask the pad what it reports.
  func pollPad() {
    guard !busy, !brightnessBusy, !pollPending, !automaticEnabled, !active(),
      reading["mode"] as? String == "manual", let resources = Bundle.main.resourceURL
    else { return }
    pollPending = true
    let started = generation
    usbQueue.async {
      let text = try? self.process(resources.appendingPathComponent("enviouscooler"), ["fan-state"])
      let state = text.flatMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
      DispatchQueue.main.async {
        self.pollPending = false
        guard started == self.generation else { return }
        let reported = state?["reported_rpm"] as? Int
        self.manualCondition = self.manualWatch.observe(reported, now: monotonicNow())
        self.manualReported = PadWatch.plausible(reported)
        if case .changedOnPad(let rpm) = self.manualCondition { self.changedOnPad = rpm }
        if !self.brightnessBusy, let percent = state?["brightness_percent"] as? Double,
          percent.isFinite, (0...100).contains(percent)
        {
          self.brightnessValue = Int(percent.rounded())
        }
        self.refresh()
      }
    }
  }
  func refresh() {
    reading =
      (try? LightingFiles.read(folder.appendingPathComponent("state.json")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [
        "_invalid_state": true
      ]
    let isAuto = active()
    let temp = isAuto ? reading["temperature_celsius"] as? Double : chipTemperature()
    let rpm =
      reading["mode"] as? String == "automatic" && !isAuto ? nil : reading["commanded_rpm"] as? Int
    temperatureLabel.stringValue = temp.map { String(format: "%.1f °C", $0) } ?? "Unavailable"
    let status = reading["status"] as? String
    let manual = !isAuto && reading["mode"] as? String == "manual"
    // A new acknowledged preset clears an earlier change made on the pad.
    if manual, let commanded = reading["commanded_rpm"] as? Int,
      let stamp = reading["updated_at"] as? String, "\(stamp) \(commanded)" != manualCommandStamp
    {
      manualCommandStamp = "\(stamp) \(commanded)"
      manualWatch.reset()
      manualWatch.acknowledged(commanded, now: monotonicNow())
      manualCondition = .unknown
      manualReported = nil
      changedOnPad = nil
    }
    let reported = isAuto ? reading["reported_rpm"] as? Int : (manual ? manualReported : nil)
    let padOff = isAuto ? status == "pad_off" : manual && manualCondition == .padOff
    let changed = manual && !padOff ? changedOnPad.map { manualReported ?? $0 } : nil
    if padOff {
      fanLabel.stringValue = "0 RPM, pad is off"
    } else if let changed {
      fanLabel.stringValue = "\(rpmText(changed)), changed on the pad"
    } else if let rpm {
      fanLabel.stringValue =
        "\(rpmText(rpm)) set · "
        + (reported.map { "pad reports \(rpmText($0))" } ?? "pad speed unavailable")
    } else {
      fanLabel.stringValue = "Unknown"
    }
    overrideNote = nil
    if isAuto, let stamp = reading["pad_override_at"] as? String,
      let date = ISO8601DateFormatter().date(from: stamp), Date().timeIntervalSince(date) < 60
    {
      overrideNote = "Fan speed changed on the pad. EnviousCooler set it back."
    }
    let autoLabel =
      status == "sleeping"
      ? "Sleeping"
      : (status == "degraded"
        ? (reading["reason"] as? String == "temperature_unavailable"
          ? "Temperature unavailable" : "Fan control unavailable") : "Automatic")
    modeLabel.stringValue =
      reading["_invalid_state"] as? Bool == true
      ? "Status unavailable"
      : busy
        ? "Updating…"
        : padOff
          ? "Pad is off. Press the power button on the pad."
        : (isAuto
          ? autoLabel
          : (reading["mode"] as? String == "automatic" ? "Controller not responding" : "Manual"))
    autoButton.state = automaticEnabled ? .on : .off
    autoButton.isEnabled = !busy && !brightnessBusy
    let manualRPM = selectedRPM
    for button in buttons {
      button.isEnabled = !busy && !brightnessBusy
      button.state = manualRPM == button.tag ? .on : .off
    }
    if !brightnessBusy, isAuto, let percent = reading["brightness_percent"] as? Double,
      percent.isFinite, (0...100).contains(percent),
      let stamp = reading["updated_at"] as? String,
      let date = ISO8601DateFormatter().date(from: stamp),
      brightnessInvalidAfter.map({ date > $0 }) ?? true
    {
      brightnessValue = Int(percent.rounded())
      brightnessInvalidAfter = nil
    }
    if isAuto && !brightnessBusy && reading["brightness_percent"] is NSNull {
      brightnessValue = nil
      brightnessLabel.stringValue = "—"
    }
    if let brightnessValue, !brightnessBusy {
      brightnessSlider.doubleValue = Double(brightnessValue)
      brightnessLabel.stringValue = "\(brightnessValue)%"
    }
    brightnessSlider.isEnabled =
      !busy && !brightnessBusy && brightnessValue != nil && (!automaticEnabled || isAuto)
    item.button?.title = temp.map { String(format: " %.0f°", $0) } ?? ""
    item.button?.toolTip = "EnviousCooler • \(modeLabel.stringValue) • \(fanLabel.stringValue)"
    if !menuOpen { buildMenu() }
  }
  func menuWillOpen(_ menu: NSMenu) {
    menuOpen = true
    refresh()
    buildMenu()
  }
  func menuDidClose(_ menu: NSMenu) { menuOpen = false }
  func add(_ title: String, action: Selector? = nil, tag: Int = 0) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
    menuItem.target = self
    menuItem.tag = tag
    menuItem.isEnabled = action != nil && !busy && !brightnessBusy
    item.menu?.addItem(menuItem)
    return menuItem
  }
  func buildMenu() {
    item.menu?.removeAllItems()
    _ = add("EnviousCooler")
    _ = add("Temperature: \(temperatureLabel.stringValue)")
    _ = add("Fan: \(fanLabel.stringValue)")
    _ = add(modeLabel.stringValue)
    if let overrideNote { _ = add(overrideNote) }
    if let error = lastError { _ = add("Last error: \(error.prefix(80))") }
    item.menu?.addItem(.separator())
    let automatic = add("Automatic cooling", action: #selector(toggleAutomatic))
    automatic.state = automaticEnabled ? .on : .off
    let manualRPM = selectedRPM
    for (title, rpm) in [
      ("Quiet · 800 RPM", 800), ("Balanced · 1,500 RPM", 1500), ("Maximum · 3,200 RPM", 3200),
      ("Fan off", 0),
    ] {
      add(title, action: #selector(preset(_:)), tag: rpm).state = manualRPM == rpm ? .on : .off
    }
    item.menu?.addItem(.separator())
    _ = add("Open dashboard…", action: #selector(showDashboard))
    _ = add("Quit menu-bar app", action: #selector(quit))
  }

  func process(_ executable: URL, _ arguments: [String]) throws -> String {
    let task = Process()
    task.executableURL = executable
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
    defer { timeout.cancel() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard task.terminationStatus == 0 else {
      throw NSError(
        domain: "CoolingPad", code: Int(task.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: text])
    }
    return text
  }
  func perform(auto: Bool? = nil, rpm: Int? = nil) {
    guard !busy && !brightnessBusy else { return }
    busy = true
    refresh()
    generation += 1
    usbQueue.async {
      do {
        guard let resources = Bundle.main.resourceURL,
          let python = Bundle.main.object(forInfoDictionaryKey: "PythonExecutable") as? String
        else { throw NSError(domain: "CoolingPad", code: 1) }
        let manager = resources.appendingPathComponent("auto-mode.py").path
        _ = try self.process(URL(fileURLWithPath: python), [manager, auto == true ? "on" : "off"])
        if let rpm {
          let text = try self.process(
            resources.appendingPathComponent("enviouscooler"), ["fan", rpm == 0 ? "off" : String(rpm)])
          guard
            let receipt = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            receipt["device_acknowledged"] as? Bool == true
          else {
            throw NSError(
              domain: "CoolingPad", code: 2,
              userInfo: [NSLocalizedDescriptionKey: "Fan setting was not acknowledged."])
          }
          let state: [String: Any] = [
            "mode": "manual", "status": "manual", "commanded_rpm": rpm,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
          ]
          try JSONSerialization.data(withJSONObject: state).write(
            to: self.folder.appendingPathComponent("state.json"), options: .atomic)
        }
        DispatchQueue.main.async {
          self.busy = false
          self.lastError = nil
          // Every acknowledged preset restarts tracking, even within the same second.
          if rpm != nil { self.manualCommandStamp = nil }
          self.refresh()
        }
      } catch {
        DispatchQueue.main.async {
          self.busy = false
          self.lastError = error.localizedDescription
          self.refresh()
          let alert = NSAlert()
          alert.messageText = "Cooling pad could not update"
          alert.informativeText = error.localizedDescription
          NSApp.activate(ignoringOtherApps: true)
          alert.runModal()
        }
      }
    }
  }
  func lighting(_ percent: Int? = nil) {
    guard !busy && !brightnessBusy else { return }
    guard !automaticEnabled || active() else { return }
    brightnessBusy = true
    let automatic = active()
    refresh()
    generation += 1
    usbQueue.async {
      do {
        let receipt: [String: Any]
        if automatic {
          // The running fan controller owns USB. Ask it to handle the
          // lighting operation without stopping or changing fan mode.
          let request = LightingRequest(percent: percent)
          try LightingFiles.prepare()
          let requestURL = LightingFiles.request(request.id)
          let responseURL = LightingFiles.response(request.id)
          defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
          }
          try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
          let deadline = monotonicNow() + 8
          var matched: [String: Any]?
          while monotonicNow() < deadline {
            if let data = try? LightingFiles.read(responseURL),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["id"] as? String == request.id.uuidString
            {
              matched = response
              break
            }
            Thread.sleep(forTimeInterval: 0.05)  // bounded receipt wait; elapsed time is not success
          }
          guard let matched else {
            throw NSError(
              domain: "CoolingPad", code: 3,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Brightness is unconfirmed. The pad may be disconnected or asleep."
              ])
          }
          receipt = matched
        } else {
          guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "CoolingPad", code: 1)
          }
          let helper = resources.appendingPathComponent("enviouscooler")
          if let percent { _ = try self.process(helper, ["brightness", String(percent)]) }
          let text = try self.process(helper, ["brightness", "get"])
          guard
            let response = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
          else { throw NSError(domain: "CoolingPad", code: 2) }
          receipt = response
        }
        if let error = receipt["error"] as? String {
          throw NSError(domain: "CoolingPad", code: 4, userInfo: [NSLocalizedDescriptionKey: error])
        }
        guard receipt["device_acknowledged"] as? Bool == true,
          let value = receipt["brightness_percent"] as? Double, value.isFinite,
          (0...100).contains(value)
        else {
          throw NSError(
            domain: "CoolingPad", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Brightness could not be verified."])
        }
        DispatchQueue.main.async {
          self.brightnessValue = Int(value.rounded())
          self.brightnessBusy = false
          self.brightnessInvalidAfter = nil
          self.lastError = nil
          self.refresh()
        }
      } catch {
        DispatchQueue.main.async {
          self.brightnessBusy = false
          self.brightnessValue = nil
          self.brightnessInvalidAfter = Date()
          self.brightnessLabel.stringValue = "Unavailable"
          self.lastError = error.localizedDescription
          self.refresh()
          let alert = NSAlert()
          alert.messageText = "Brightness could not update"
          alert.informativeText = error.localizedDescription
          NSApp.activate(ignoringOtherApps: true)
          alert.runModal()
        }
      }
    }
  }
  @objc func brightnessChanged() {
    let percent = Int(brightnessSlider.doubleValue.rounded())
    brightnessLabel.stringValue = "\(percent)%"
    lighting(percent)
  }
  @objc func toggleAutomatic() { perform(auto: !automaticEnabled) }
  @objc func preset(_ sender: AnyObject) {
    if let item = sender as? NSMenuItem { perform(rpm: item.tag) }
    if let button = sender as? NSButton { perform(rpm: button.tag) }
  }
  @objc func quit() { NSApp.terminate(nil) }
  @objc func showDashboard() {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      refresh()
      lighting()
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 390, height: 370),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "EnviousCooler"
    window.isReleasedWhenClosed = false
    let heading = NSTextField(labelWithString: "Cooling, quietly.")
    heading.font = .systemFont(ofSize: 24, weight: .semibold)
    let caption = NSTextField(
      labelWithString: "Smooth fan control using your Mac’s chip temperature.")
    caption.font = .systemFont(ofSize: 12)
    caption.textColor = .secondaryLabelColor
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.addArrangedSubview(heading)
    stack.addArrangedSubview(caption)
    for (name, value) in [
      ("Temperature", temperatureLabel), ("Fan target", fanLabel), ("Mode", modeLabel),
    ] {
      let label = NSTextField(labelWithString: name)
      label.textColor = .secondaryLabelColor
      label.widthAnchor.constraint(equalToConstant: 95).isActive = true
      value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
      let row = NSStackView(views: [label, value])
      row.orientation = .horizontal
      row.spacing = 12
      stack.addArrangedSubview(row)
    }
    autoButton.target = self
    autoButton.action = #selector(toggleAutomatic)
    stack.addArrangedSubview(autoButton)
    let presets = NSStackView()
    presets.orientation = .horizontal
    presets.spacing = 8
    for (title, rpm) in [("Quiet", 800), ("Balanced", 1500), ("Maximum", 3200)] {
      let button = NSButton(title: title, target: self, action: #selector(preset(_:)))
      button.bezelStyle = .rounded
      button.setButtonType(.pushOnPushOff)
      button.tag = rpm
      buttons.append(button)
      presets.addArrangedSubview(button)
    }
    stack.addArrangedSubview(presets)
    brightnessSlider.target = self
    brightnessSlider.action = #selector(brightnessChanged)
    brightnessSlider.isContinuous = false
    brightnessSlider.setAccessibilityLabel("RGB brightness")
    brightnessSlider.widthAnchor.constraint(equalToConstant: 178).isActive = true
    let brightnessTitle = NSTextField(labelWithString: "RGB brightness")
    brightnessTitle.textColor = .secondaryLabelColor
    brightnessLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    brightnessLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
    let brightnessRow = NSStackView(views: [brightnessTitle, brightnessSlider, brightnessLabel])
    brightnessRow.orientation = .horizontal
    brightnessRow.spacing = 10
    stack.addArrangedSubview(brightnessRow)
    let note = NSTextField(
      wrappingLabelWithString:
        "Manual presets pause automatic cooling. Closing this window keeps cooling active.")
    note.font = .systemFont(ofSize: 11)
    note.textColor = .secondaryLabelColor
    stack.addArrangedSubview(note)
    let content = window.contentView!
    content.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
    ])
    self.window = window
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    refresh()
    lighting()
  }
}

@main
enum MenuApplication {
  static func main() {
    let app = NSApplication.shared
    let delegate = CoolingApp()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
