import Darwin
import Foundation

// Apple's private read-only sensor API, also used by padctl and macmon.
// Resolve symbols at runtime so an OS change produces an error, not a crash.
final class Thermals {
  typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
  typealias Match = @convention(c) (CFTypeRef, CFDictionary) -> Void
  typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
  typealias Property = @convention(c) (UnsafeRawPointer, CFString) -> Unmanaged<CFTypeRef>?
  typealias Event = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
  typealias Value = @convention(c) (CFTypeRef, UInt32) -> Double
  typealias Timestamp = @convention(c) (CFTypeRef) -> UInt64
  var client: CFTypeRef?
  let library: UnsafeMutableRawPointer
  let services: Services
  let property: Property
  let event: Event
  let value: Value
  let timestamp: Timestamp

  init() throws {
    guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
      throw PadError("Mac temperature API unavailable.")
    }
    func symbol<T>(_ name: String, _: T.Type) throws -> T {
      guard let pointer = dlsym(lib, name) else {
        throw PadError("Missing temperature API: \(name).")
      }
      return unsafeBitCast(pointer, to: T.self)
    }
    do {
      let create = try symbol("IOHIDEventSystemClientCreate", Create.self)
      let match = try symbol("IOHIDEventSystemClientSetMatching", Match.self)
      services = try symbol("IOHIDEventSystemClientCopyServices", Services.self)
      property = try symbol("IOHIDServiceClientCopyProperty", Property.self)
      event = try symbol("IOHIDServiceClientCopyEvent", Event.self)
      value = try symbol("IOHIDEventGetFloatValue", Value.self)
      timestamp = try symbol("IOHIDEventGetTimeStamp", Timestamp.self)
      guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else {
        throw PadError("Cannot open Mac temperature sensors.")
      }
      client = c
      match(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
      library = lib
    } catch {
      dlclose(lib)
      throw error
    }
  }
  deinit {
    client = nil
    dlclose(library)
  }

  // Keep IOKit loaded for the lifetime of the CF objects it created.
  func readings() throws -> [[String: Any]] {
    guard let client, let array = services(client)?.takeRetainedValue() else {
      throw PadError("Mac temperature sensors unavailable.")
    }
    var result: [[String: Any]] = []
    for i in 0..<CFArrayGetCount(array) {
      guard let service = CFArrayGetValueAtIndex(array, i),
        let name = property(service, "Product" as CFString)?.takeRetainedValue() as? String,
        let reading = event(service, 15, 0, 0)?.takeRetainedValue()
      else { continue }
      let degrees = value(reading, 15 << 16)
      let stamp = timestamp(reading)
      let now = mach_absolute_time()
      var timebase = mach_timebase_info_data_t()
      mach_timebase_info(&timebase)
      let age =
        stamp <= now
        ? Double(now - stamp) * Double(timebase.numer) / Double(timebase.denom) / 1e9 : -1
      guard degrees.isFinite, degrees > 0, degrees <= 125, stamp != 0, age >= 0, age <= 10 else {
        continue
      }
      let kind: String
      if name.contains("MTR Temp Sensor") && (name.hasPrefix("pACC") || name.hasPrefix("eACC")) {
        kind = "cpu"
      } else if name.hasPrefix("gACC") && name.contains("Temp") {
        kind = "gpu"
      } else if name.hasPrefix("PMU tdie") {
        kind = "soc_die"
      } else {
        kind = "other"
      }
      result.append(["name": name, "celsius": degrees, "kind": kind, "age_seconds": age])
    }
    guard !result.isEmpty else { throw PadError("No valid Mac temperature readings.") }
    return result.sorted { ($0["name"] as! String) < ($1["name"] as! String) }
  }
}
