import Darwin
import Foundation
import IOKit.hid

protocol FeatureTransport {
  var connected: Bool { get }
  func send(_ bytes: [UInt8]) throws
  func read() throws -> [UInt8]
}
extension FeatureTransport { var connected: Bool { true } }

private final class USBOperation {
  var result: IOReturn?
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 90)
  let length = UnsafeMutablePointer<CFIndex>.allocate(capacity: 1)
  init(bytes: [UInt8]?) {
    buffer.initialize(repeating: 0, count: 90)
    length.initialize(to: 90)
    if let bytes { for (i, byte) in bytes.enumerated() { buffer[i] = byte } }
  }
  deinit {
    buffer.deinitialize(count: 90)
    buffer.deallocate()
    length.deinitialize(count: 1)
    length.deallocate()
  }
}

final class USBTransport: FeatureTransport {
  private var removed = false
  var connected: Bool { !removed }
  let manager: IOHIDManager
  let device: IOHIDDevice
  private let lockFD: Int32

  init() throws {
    // Serialize this helper's reads/writes, including the query response buffer.
    let lockPath = NSTemporaryDirectory() + "envious-razer-pad-\(getuid()).lock"
    let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw PadError("Cannot open device lock.") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw PadError("Another cooling-pad command is running. Try again shortly.")
    }
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(
      m, [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x0f43] as CFDictionary)
    // Discovery doesn't open the media-key interface.
    let devices = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
    let controls = devices.filter {
      (IOHIDDeviceGetProperty($0, kIOHIDMaxFeatureReportSizeKey as CFString) as? NSNumber)?.intValue
        == 90
    }
    guard controls.count == 1, let d = controls.first else {
      flock(fd, LOCK_UN)
      close(fd)
      throw PadError(
        controls.isEmpty
          ? "Cooling pad not found. Check its USB connection."
          : "Multiple pads connected. Connect just one for this helper.")
    }
    let result = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    guard result == kIOReturnSuccess else {
      flock(fd, LOCK_UN)
      close(fd)
      throw PadError(
        String(format: "Cannot open cooling pad (0x%08x).", UInt32(bitPattern: result)))
    }
    manager = m
    device = d
    lockFD = fd
    IOHIDDeviceRegisterRemovalCallback(
      d,
      { context, _, _ in
        guard let context else { return }
        Unmanaged<USBTransport>.fromOpaque(context).takeUnretainedValue().removed = true
      }, Unmanaged.passUnretained(self).toOpaque())
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
  }

  deinit {
    IOHIDDeviceUnscheduleFromRunLoop(
      device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    flock(lockFD, LOCK_UN)
    close(lockFD)
  }

  private func operation(bytes: [UInt8]?) throws -> [UInt8] {
    let operation = USBOperation(bytes: bytes)
    let context = Unmanaged.passRetained(operation).toOpaque()
    let callback: IOHIDReportCallback = { context, result, _, _, _, _, _ in
      guard let context else { return }
      Unmanaged<USBOperation>.fromOpaque(context).takeRetainedValue().result = result
    }
    let sent: IOReturn
    if bytes != nil {
      sent = IOHIDDeviceSetReportWithCallback(
        device, kIOHIDReportTypeFeature, 0,
        operation.buffer, 90, 1000, callback, context)
    } else {
      sent = IOHIDDeviceGetReportWithCallback(
        device, kIOHIDReportTypeFeature, 0,
        operation.buffer, operation.length, 1000, callback, context)
    }
    guard sent == kIOReturnSuccess else {
      if operation.result == nil {
        _ = Unmanaged<USBOperation>.fromOpaque(context).takeRetainedValue()
      }
      throw PadError("USB operation failed; setting is unconfirmed.")
    }
    _ = waitForUSBCompletion(deadline: monotonicNow() + 2, completed: { operation.result != nil })
    // A missing OS callback must not leave a running controller wedged, nor
    // release a buffer that the driver may still reference. Exit the helper;
    // macOS owns cancellation and launchd restarts the automatic controller.
    guard let result = operation.result else {
      FileHandle.standardError.write(
        Data("{\"error\":\"USB deadline exceeded; setting is unconfirmed.\"}\n".utf8))
      exit(70)
    }
    guard result == kIOReturnSuccess else {
      throw PadError("USB completion failed; setting is unconfirmed.")
    }
    guard (0...90).contains(operation.length.pointee) else {
      throw PadError("Invalid USB response length.")
    }
    return Array(UnsafeBufferPointer(start: operation.buffer, count: operation.length.pointee))
  }
  func send(_ bytes: [UInt8]) throws {
    guard bytes.count == 90 else { throw PadError("Invalid outgoing report length.") }
    _ = try operation(bytes: bytes)
  }
  func read() throws -> [UInt8] { try operation(bytes: nil) }
}

final class Pad {
  let transport: any FeatureTransport
  let settle: () -> Void
  private var exchanging = false
  init(
    transport: (any FeatureTransport)? = nil,
    settle: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.15) }
  ) throws {
    self.transport = try transport ?? USBTransport()
    self.settle = settle
  }
  func exchange(_ packet: Packet) throws -> [UInt8] {
    try validateConnection()
    guard !exchanging else { throw PadError("Another USB exchange is in progress.") }
    exchanging = true
    defer { exchanging = false }
    try transport.send(packet.bytes)
    for _ in 0..<4 {
      settle()
      let response = try transport.read()
      if try validateResponse(response, to: packet) { return response }
    }
    throw PadError("Cooling pad remained busy; setting is unconfirmed.")
  }

  func validateConnection() throws {
    guard transport.connected else { throw PadError("Cooling pad disconnected.") }
  }

  func brightness() throws -> UInt8 {
    let r = try exchange(Packet(cls: 0x0f, cmd: 0x84, size: 3, args: [1, 0]))
    guard r[5] >= 3 else { throw PadError("Brightness response has no value.") }
    return r[10]
  }

  // The pad's own report of its fan speed. It follows the pad's buttons, so it
  // reveals a power-button off (0) or a fan-button change. Not a verified tachometer.
  func reportedRPM() throws -> Int? {
    let r = try exchange(Packet(tid: 2, cls: 0x0d, cmd: 0x81, size: 3, args: [1, 5]))
    return decodeReportedRPM(r)
  }

  func status() throws -> [String: Any] {
    let fw = try exchange(Packet(cls: 0, cmd: 0x81, size: 2, args: []))
    guard fw[5] >= 2 else { throw PadError("Firmware response has no version.") }
    let serial = try exchange(Packet(cls: 0, cmd: 0x82, size: 22, args: []))
    guard serial[5] >= 22 else { throw PadError("Serial response is incomplete.") }
    let brightness = try brightness()
    let state = ProcessInfo.processInfo.thermalState.rawValue
    let labels = ["normal", "warm", "hot", "critical"]
    return [
      "connected": true, "firmware": "\(fw[8]).\(fw[9])",
      "serial": String(bytes: serial[8..<30].prefix(while: { $0 != 0 }), encoding: .ascii)
        ?? "unreadable",
      "brightness_percent": Double(brightness) * 100 / 255,
      "mac_thermal_pressure": labels.indices.contains(state) ? labels[state] : "unknown",
      "measured_rpm": NSNull(), "temperature_celsius": NSNull(),
      "note":
        "Fan RPM and temperatures are not measured by this helper. Information queries overwrite the last device response.",
    ]
  }
}
