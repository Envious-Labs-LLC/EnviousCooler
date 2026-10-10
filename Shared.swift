import Darwin
import Foundation

func monotonicNow() -> Double {
  var timebase = mach_timebase_info_data_t()
  mach_timebase_info(&timebase)
  return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

func shouldResumeAfterSleep(started: Double?, now: Double) -> Bool {
  guard let started, started.isFinite, now.isFinite else { return false }
  return now - started > 10
}

func waitForUSBCompletion(
  deadline: Double, completed: () -> Bool,
  now: () -> Double = monotonicNow,
  poll: () -> Void = { CFRunLoopRunInMode(.defaultMode, 0.01, true) }
) -> Bool {
  while !completed() && now() < deadline { poll() }
  return completed()
}

enum LightingOperation: String, Codable { case get, set }

struct LightingRequest: Codable {
  let id: UUID
  let operation: LightingOperation
  let percent: Int?
  let createdAt: Double

  init(percent: Int?) {
    id = UUID()
    operation = percent == nil ? .get : .set
    self.percent = percent
    createdAt = Date().timeIntervalSince1970
  }

  func validate(now: Double) throws {
    guard createdAt.isFinite, now.isFinite, now >= createdAt, now - createdAt < 6 else {
      throw PadError("Lighting request expired.")
    }
    switch operation {
    case .get:
      guard percent == nil else {
        throw PadError("Read request must not contain a brightness setting.")
      }
    case .set:
      guard let percent, (0...100).contains(percent) else {
        throw PadError("Brightness must be a whole percentage from 0 to 100.")
      }
    }
  }
}

enum LightingFiles {
  static let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/EnviousCooler/lighting")
  static func prepare() throws {
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }
  static func request(_ id: UUID) -> URL {
    folder.appendingPathComponent("\(id.uuidString).request.json")
  }
  static func response(_ id: UUID) -> URL {
    folder.appendingPathComponent("\(id.uuidString).response.json")
  }
  static func pending() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
    )
    .filter {
      $0.lastPathComponent.hasSuffix(".request.json")
        && UUID(uuidString: String($0.lastPathComponent.dropLast(13))) != nil
    }
    .sorted {
      let a =
        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let b =
        (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return a < b
    }
  }
  static func read(_ url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw PadError("Controller message is not a regular file.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 4097) ?? Data()
    guard data.count <= 4096 else { throw PadError("Oversized controller message.") }
    return data
  }
  static func cleanup(now: Date = Date()) {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    for url in urls where url.lastPathComponent.hasSuffix(".json") {
      let name = url.lastPathComponent
      let suffix = name.hasSuffix(".request.json") ? ".request.json" : ".response.json"
      guard name.hasSuffix(suffix), UUID(uuidString: String(name.dropLast(suffix.count))) != nil
      else { continue }
      guard
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
        now.timeIntervalSince(date) > 60
      else { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }
}

func stateIsFresh(_ state: [String: Any], now: Date = Date()) -> Bool {
  guard let text = state["updated_at"] as? String,
    let date = ISO8601DateFormatter().date(from: text)
  else { return false }
  let age = now.timeIntervalSince(date)
  return age >= -2 && age <= 10
}
