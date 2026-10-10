import Foundation
import IOKit.hid

// Discovery never changes fan/lighting settings or takes exclusive ownership.
// --query sends only the three documented information requests below.
let queryInformation = CommandLine.arguments.contains("--query")
func informationQuery(_ device: IOHIDDevice, name: String, commandClass: UInt8,
                      command: UInt8, size: UInt8, arguments: [UInt8]) -> [String: Any] {
    var packet = [UInt8](repeating: 0, count: 90)
    packet[1] = 0x1f
    packet[5] = size
    packet[6] = commandClass
    packet[7] = command
    for (index, byte) in arguments.enumerated() { packet[8 + index] = byte }
    packet[88] = packet[2...87].reduce(0, ^)
    // Native IOHID uses the 90-byte packet, with report ID supplied separately.
    let sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, packet, packet.count)
    var result: [String: Any] = ["name": name, "send_status": String(format: "0x%08x", UInt32(bitPattern: sent))]
    guard sent == kIOReturnSuccess else { return result }
    Thread.sleep(forTimeInterval: 0.15)
    var response = [UInt8](repeating: 0, count: 90)
    var length = response.count
    let read = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &response, &length)
    result["read_status"] = String(format: "0x%08x", UInt32(bitPattern: read))
    guard read == kIOReturnSuccess, length == 90 else {
        result["validated"] = false
        return result
    }
    result["response_hex"] = response.map { String(format: "%02x", $0) }.joined()
    let valid = response[0] == 2 && response[1] == packet[1]
        && response[6] == commandClass && response[7] == command
        && response[5] >= size && response[5] <= 80
        && response[88] == response[2...87].reduce(0, ^)
    result["validated"] = valid
    if valid {
        if name == "firmware" { result["value"] = "\(response[8]).\(response[9])" }
        if name == "serial" {
            let bytes = Array(response[8..<30].prefix(while: { $0 != 0 }))
            result["value"] = String(bytes: bytes, encoding: .ascii) ?? "unreadable"
        }
        if name == "brightness" { result["percent"] = Double(response[10]) * 100 / 255 }
    }
    return result
}
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x0F43] as CFDictionary)
let managerStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

var rows: [[String: Any]] = []
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
for device in devices {
    var row: [String: Any] = [:]
    for key in [kIOHIDProductKey, kIOHIDManufacturerKey, kIOHIDVendorIDKey,
                kIOHIDProductIDKey, kIOHIDVersionNumberKey, kIOHIDLocationIDKey,
                kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey,
                kIOHIDMaxFeatureReportSizeKey, kIOHIDMaxInputReportSizeKey,
                kIOHIDMaxOutputReportSizeKey] {
        if let value = IOHIDDeviceGetProperty(device, key as CFString) { row[key] = value }
    }
    if let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
        row["report_descriptor_hex"] = descriptor.map { String(format: "%02x", $0) }.joined()
    }
    let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
    if size == 90 {
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        row["open_status"] = String(format: "0x%08x", UInt32(bitPattern: opened))
        if opened == kIOReturnSuccess {
            var bytes = [UInt8](repeating: 0, count: size)
            var length = size
            let status = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &bytes, &length)
            row["get_feature_status"] = String(format: "0x%08x", UInt32(bitPattern: status))
            if status == kIOReturnSuccess && length >= 0 && length <= size {
                row["feature_report_length"] = length
                row["feature_report_hex"] = bytes.prefix(length).map { String(format: "%02x", $0) }.joined()
                row["interpretation"] = "Raw response only. No RPM or temperature inferred without a validated matching response."
            }
            if queryInformation {
                row["information_queries"] = [
                    informationQuery(device, name: "firmware", commandClass: 0, command: 0x81, size: 2, arguments: []),
                    informationQuery(device, name: "serial", commandClass: 0, command: 0x82, size: 22, arguments: []),
                    informationQuery(device, name: "brightness", commandClass: 0x0f, command: 0x84, size: 3, arguments: [1, 0])
                ]
            }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
    rows.append(row)
}
let result: [String: Any] = [
    "read_only": true,
    "information_queries_sent": queryInformation,
    "connected": !devices.isEmpty,
    "manager_status": String(format: "0x%08x", UInt32(bitPattern: managerStatus)),
    "interfaces": rows,
    "mac_thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
    "thermal_state_labels": ["nominal", "fair", "serious", "critical"]
]
let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: json, as: UTF8.self))
if managerStatus != kIOReturnSuccess || devices.isEmpty { exit(1) }
