import Foundation
import IOKit.hid

// One-shot, read-only probe of this pad's two unexplained input reports.
// No writes, exclusive capture, keyboard-report reads or permission requests.
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x0f43] as CFDictionary)
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
var results: [[String: Any]] = []
var observedReports: [[String: Any]] = []
guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--listen",
      let listenSeconds = Double(CommandLine.arguments[2]), listenSeconds.isFinite,
      listenSeconds > 0, listenSeconds <= 60 else {
    fputs("Use inspect-input --listen SECONDS (1..60).\n", stderr)
    exit(1)
}
for device in devices where (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue == 16 {
    let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard opened == kIOReturnSuccess else {
        results.append(["open_status": String(format: "0x%08x", UInt32(bitPattern: opened)), "read": false])
        continue
    }
    let seconds = listenSeconds
    do {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
        buffer.initialize(repeating: 0, count: 16)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 16, { _, status, _, _, reportID, bytes, length in
            // Observe all non-keyboard reports from the cooling pad itself.
            guard (2...5).contains(reportID), length >= 0, length <= 16 else { return }
            let report = Array(UnsafeBufferPointer(start: bytes, count: length))
            let entry: [String: Any] = ["report_id": reportID, "status": String(format: "0x%08x", UInt32(bitPattern: status)),
                                       "hex": report.map { String(format: "%02x", $0) }.joined(),
                                       "time": ISO8601DateFormatter().string(from: Date())]
            if observedReports.count < 512 { observedReports.append(entry) }
        }, nil)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deinitialize(count: 16); buffer.deallocate()
        results.append(["listened_seconds": seconds, "input_reports": observedReports, "meaning": "Undecoded pad reports only; silence does not establish absence of a fault signal."])
        continue
    }

}
let data = try JSONSerialization.data(withJSONObject: ["read_only": true, "reports": results], options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
