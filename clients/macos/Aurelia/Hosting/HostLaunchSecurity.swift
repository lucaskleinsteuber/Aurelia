import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

// Release preflight uses the real app/helper/API, but never the personal Keychain,
// operating-mode preferences or a previously registered background service.
// Both the executable and synthetic data must belong to the same private test run.
enum NativePreflightIsolation {
  static var isRequested: Bool {
    ProcessInfo.processInfo.environment["AURELIA_PREFLIGHT_TEST"] == "1"
  }
  static var isActive: Bool {
    let environment = ProcessInfo.processInfo.environment
    guard environment["AURELIA_PREFLIGHT_TEST"] == "1", let data = environment["AURELIA_DATA_DIR"]
    else { return false }
    return accepts(bundleURL: Bundle.main.bundleURL, dataDirectory: URL(fileURLWithPath: data))
  }

  static func accepts(bundleURL: URL, dataDirectory: URL) -> Bool {
    let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    let runPath = canonicalTemporaryPath(bundle.deletingLastPathComponent().path)
    guard runPath.hasPrefix("/private/tmp/Aurelia/"), bundle.lastPathComponent == "Aurelia.app"
    else { return false }
    // URL equality also compares the directory slash. In the app sandbox the
    // filesystem cannot always infer it, so compare canonical paths instead.
    // Do not resolve the expected Data path: a symlink escaping this run must fail.
    return canonicalTemporaryPath(dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path)
      == runPath + "/Data"
  }

  private static func canonicalTemporaryPath(_ path: String) -> String {
    // /tmp is macOS's alias of /private/tmp. Foundation may retain that alias
    // when resolving a path from inside the app sandbox.
    path.hasPrefix("/tmp/") ? "/private" + path : path
  }
}

@_silgen_name("AureliaOpenPipe")
func aureliaOpenPipe(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32

struct HostLaunchDescription: Codable, Equatable {
  let version: Int
  let parentProcessID: Int32
  let rendezvousPath: String
  let secretPipePath: String
  let dataDirectory: String?
  let logDirectory: String?
  let serverName: String
  let lanPort: Int
}

struct ValidatedHostLaunchPaths: Equatable {
  let rendezvousURL: URL
  let pipeURL: URL
}

struct HostPreflightBackgroundDescription: Codable {
  let version: Int
  let controlSecret: String
  let dataDirectory: String
  let logDirectory: String
}

struct ValidatedHostPreflightBackground {
  let secret: String
  let dataDirectory: URL
  let logDirectory: URL
  let rendezvousURL: URL
}

enum HostPreflightBackgroundSecurity {
  static func enclosingApplication(helperBundleURL: URL) -> URL? {
    let helper = helperBundleURL.standardizedFileURL.resolvingSymlinksInPath()
    let application = helper.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let expected = application.appendingPathComponent("Contents/Helpers/Aurelia Server Host.app")
    guard helper.path == expected.path,
      NativePreflightIsolation.accepts(
        bundleURL: application,
        dataDirectory: application.deletingLastPathComponent().appendingPathComponent("Data"))
    else { return nil }
    return application
  }

  static func load(
    environment: [String: String], helperBundleURL: URL
  ) throws -> ValidatedHostPreflightBackground {
    guard environment["AURELIA_PREFLIGHT_TEST"] == "1",
      environment["AURELIA_SERVER_EXECUTABLE"] == nil,
      let application = enclosingApplication(helperBundleURL: helperBundleURL),
      let configurationPath = environment["AURELIA_HOST_PREFLIGHT_CONFIG"]
    else { throw HostLaunchSecurityError.invalidDescription }
    let root = application.deletingLastPathComponent()
    let bootstrap = root.appendingPathComponent("Host", isDirectory: true)
    let configuration = URL(fileURLWithPath: configurationPath).standardizedFileURL
    guard configuration.path == bootstrap.appendingPathComponent("preflight.json").path else {
      throw HostLaunchSecurityError.invalidPathLocation
    }
    try HostLaunchSecurity.validateBootstrapDirectory(at: root)
    try HostLaunchSecurity.validateBootstrapDirectory(at: bootstrap)
    try HostLaunchSecurity.validateConfigurationFile(
      at: configuration.path, bootstrapDirectory: bootstrap)
    let values = try configuration.resourceValues(forKeys: [.fileSizeKey])
    guard (values.fileSize ?? 0) <= 65_536 else {
      throw HostLaunchSecurityError.invalidDescription
    }
    let description = try JSONDecoder().decode(
      HostPreflightBackgroundDescription.self, from: Data(contentsOf: configuration))
    let data = URL(fileURLWithPath: description.dataDirectory, isDirectory: true)
      .standardizedFileURL
    let logs = URL(fileURLWithPath: description.logDirectory, isDirectory: true)
      .standardizedFileURL
    guard description.version == 1, description.controlSecret.count == 64,
      description.controlSecret.allSatisfy(\.isHexDigit),
      NativePreflightIsolation.accepts(bundleURL: application, dataDirectory: data),
      logs.path == root.appendingPathComponent("Logs").path
    else { throw HostLaunchSecurityError.invalidDescription }
    try HostLaunchSecurity.validateBootstrapDirectory(at: data)
    try HostLaunchSecurity.validateBootstrapDirectory(at: logs)
    return ValidatedHostPreflightBackground(
      secret: description.controlSecret, dataDirectory: data, logDirectory: logs,
      rendezvousURL: bootstrap.appendingPathComponent("background-rendezvous.json"))
  }
}

enum HostBootstrapLocation {
  static let appGroupIdentifier = AppEdition.appGroup

  static func directory(fileManager: FileManager = .default) throws -> URL {
    guard
      let container = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    else {
      throw HostLaunchSecurityError.invalidPathLocation
    }

    let directory = container.appendingPathComponent(
      "Library/Caches/Aurelia/Host", isDirectory: true
    ).standardizedFileURL
    var metadata = stat()
    let alreadyPrepared =
      lstat(directory.path, &metadata) == 0
      && (metadata.st_mode & S_IFMT) == S_IFDIR
      && metadata.st_uid == getuid()
      && (metadata.st_mode & 0o777) == 0o700
    if !alreadyPrepared {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try fileManager.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    return directory
  }
}

enum HostLaunchSecurityError: Error, Equatable {
  case invalidDescription
  case invalidPathLocation
  case invalidSecretPipe
}

enum HostLaunchSecurity {
  static func validateBootstrapDirectory(at url: URL, owner: uid_t = getuid()) throws {
    var metadata = stat()
    let path = url.standardizedFileURL.path
    guard path.hasPrefix("/"), lstat(path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == owner,
      metadata.st_mode & 0o777 == 0o700
    else { throw HostLaunchSecurityError.invalidPathLocation }
  }

  static func validateConfigurationFile(
    at path: String,
    bootstrapDirectory: URL,
    owner: uid_t = getuid()
  ) throws {
    var metadata = stat()
    let configurationURL = URL(fileURLWithPath: path).standardizedFileURL
    let expectedDirectory = bootstrapDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard path.hasPrefix("/"), path.hasSuffix(".json"),
      configurationURL.deletingLastPathComponent().resolvingSymlinksInPath() == expectedDirectory,
      lstat(path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == owner,
      metadata.st_mode & 0o777 == 0o600
    else { throw HostLaunchSecurityError.invalidDescription }
  }

  static func acceptsApplication(
    processIdentifier: Int32,
    executableURL: URL?,
    isTerminated: Bool,
    expectedExecutableURL: URL
  ) -> Bool {
    guard processIdentifier > 1, !isTerminated, let executableURL else { return false }
    return executableURL.standardizedFileURL.resolvingSymlinksInPath().path
      == expectedExecutableURL.standardizedFileURL.resolvingSymlinksInPath().path
  }

  static func validate(
    _ description: HostLaunchDescription,
    expectedParentProcessID: Int32,
    bootstrapDirectory: URL
  ) throws -> ValidatedHostLaunchPaths {
    guard description.version == 1,
      expectedParentProcessID > 1,
      description.parentProcessID == expectedParentProcessID,
      description.lanPort >= 1_024, description.lanPort <= 65_535,
      description.dataDirectory?.hasPrefix("/") != false,
      description.logDirectory?.hasPrefix("/") != false,
      !description.serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw HostLaunchSecurityError.invalidDescription }

    let expectedDirectory = bootstrapDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let rendezvousURL = URL(fileURLWithPath: description.rendezvousPath).standardizedFileURL
    let pipeURL = URL(fileURLWithPath: description.secretPipePath).standardizedFileURL
    guard description.rendezvousPath.hasPrefix("/"),
      description.secretPipePath.hasPrefix("/"),
      description.secretPipePath.hasSuffix(".pipe"),
      rendezvousURL.deletingLastPathComponent().resolvingSymlinksInPath() == expectedDirectory,
      pipeURL.deletingLastPathComponent().resolvingSymlinksInPath() == expectedDirectory
    else { throw HostLaunchSecurityError.invalidPathLocation }

    return ValidatedHostLaunchPaths(rendezvousURL: rendezvousURL, pipeURL: pipeURL)
  }

  static func readSecretPipe(at path: String, owner: uid_t = getuid()) throws -> String {
    guard path.hasPrefix("/"), path.hasSuffix(".pipe"), path.utf8.count <= 1_024 else {
      throw HostLaunchSecurityError.invalidSecretPipe
    }
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFIFO,
      metadata.st_uid == owner,
      metadata.st_mode & 0o777 == 0o600
    else {
      throw HostLaunchSecurityError.invalidSecretPipe
    }
    let descriptor = path.withCString { aureliaOpenPipe($0, O_RDONLY | O_NONBLOCK) }
    guard descriptor >= 0 else { throw HostLaunchSecurityError.invalidSecretPipe }
    defer {
      close(descriptor)
      unlink(path)
    }
    var bytes = [UInt8](repeating: 0, count: 128)
    let count = read(descriptor, &bytes, bytes.count)
    defer {
      for index in bytes.indices { bytes[index] = 0 }
    }
    guard count >= 43, count <= 128,
      let secret = String(bytes: bytes.prefix(count), encoding: .utf8)
    else { throw HostLaunchSecurityError.invalidSecretPipe }
    return secret
  }

  /// Removes orphaned per-launch handoff files (`launch-<pid>.json`, `launch-<pid>.pipe`) whose
  /// owning process is no longer running, plus abandoned per-launch `<uuid>.json` rendezvous files
  /// older than `staleRendezvousAge`, while preserving active and persistent background-service files.
  static func pruneStaleHandoffFiles(
    in directory: URL,
    currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
    now: Date = Date(),
    staleRendezvousAge: TimeInterval = 3_600,
    owner: uid_t = getuid(),
    processIsAlive: (Int32) -> Bool = { pid in
      pid > 0 && (kill(pid, 0) == 0 || errno != ESRCH)
    }
  ) {
    let fileManager = FileManager.default
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
    else { return }
    for entry in entries {
      let name = entry.lastPathComponent
      var metadata = stat()
      guard lstat(entry.path, &metadata) == 0, metadata.st_uid == owner else { continue }
      let fileType = metadata.st_mode & S_IFMT
      if name.hasPrefix("launch-") {
        if name.hasSuffix(".json"), fileType == S_IFREG,
          let pid = Int32(name.dropFirst("launch-".count).dropLast(".json".count)),
          pid != currentProcessID, !processIsAlive(pid)
        {
          try? fileManager.removeItem(at: entry)
        } else if name.hasSuffix(".pipe"), fileType == S_IFIFO,
          let pid = Int32(name.dropFirst("launch-".count).dropLast(".pipe".count)),
          pid != currentProcessID, !processIsAlive(pid)
        {
          unlink(entry.path)
        }
      } else if name.hasSuffix(".json"), fileType == S_IFREG,
        UUID(uuidString: String(name.dropLast(".json".count))) != nil
      {
        let modified =
          (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate
          ?? Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec))
        if now.timeIntervalSince(modified) >= staleRendezvousAge {
          try? fileManager.removeItem(at: entry)
        }
      }
    }
  }
}

/// Mutual HMAC-SHA256 authentication for the local helper control channel so the shared secret
/// is never transmitted in plaintext over loopback TCP, and responses from rogue listeners are
/// rejected before decoding.
enum HostControlAuth {
  static let nonceHeader = "X-Aurelia-Host-Nonce"
  static let timestampHeader = "X-Aurelia-Host-Timestamp"
  static let signatureHeader = "X-Aurelia-Host-Signature"
  static let proofHeader = "X-Aurelia-Host-Proof"
  static let maximumSkewSeconds: Int64 = 60

  static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var difference: UInt8 = left.count == right.count ? 0 : 1
    let count = min(left.count, right.count)
    for index in 0..<count {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }

  static func makeNonce() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw HostLaunchSecurityError.invalidSecretPipe
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func requestSignature(
    secret: String,
    method: String,
    action: String,
    nonce: String,
    timestamp: Int64,
    body: Data
  ) -> String {
    let payload = "\(method)\n\(action)\n\(nonce)\n\(timestamp)\n\(sha256Hex(body))"
    return hmacHex(secret: secret, message: payload)
  }

  static func responseProof(
    secret: String,
    nonce: String,
    status: Int,
    body: Data
  ) -> String {
    let payload = "response\n\(nonce)\n\(status)\n\(sha256Hex(body))"
    return hmacHex(secret: secret, message: payload)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func hmacHex(secret: String, message: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return mac.map { String(format: "%02x", $0) }.joined()
  }
}

struct HostControlNonceReplayGuard: Sendable {
  private var seen: [String: Int64] = [:]
  private let maximumEntries = 512

  mutating func accept(nonce: String, timestamp: Int64, now: Int64) -> Bool {
    guard (16...64).contains(nonce.count),
      nonce.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-" || $0 == "_") }),
      abs(now - timestamp) <= HostControlAuth.maximumSkewSeconds
    else { return false }

    let expiryCutoff = now - HostControlAuth.maximumSkewSeconds
    seen = seen.filter { $0.value >= expiryCutoff }
    guard seen[nonce] == nil else { return false }
    if seen.count >= maximumEntries {
      let oldest = seen.sorted { $0.value < $1.value }.prefix(seen.count - maximumEntries + 1)
      for entry in oldest { seen.removeValue(forKey: entry.key) }
    }
    seen[nonce] = timestamp
    return true
  }
}

struct HostStartupErrorRecord: Codable, Equatable, Sendable {
  static let fileName = "startup-error.json"
  let category: String
  let message: String
  let recordedAt: Date

  static func write(category: String, message: String, in directory: URL) {
    let url = directory.appendingPathComponent(fileName)
    let record = HostStartupErrorRecord(category: category, message: message, recordedAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(record) else { return }
    try? data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static func readRecent(from directory: URL, maxAge: TimeInterval = 30) -> HostStartupErrorRecord?
  {
    let url = directory.appendingPathComponent(fileName)
    guard
      (try? HostLaunchSecurity.validateConfigurationFile(
        at: url.path, bootstrapDirectory: directory)) != nil,
      let data = try? Data(contentsOf: url)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let record = try? decoder.decode(HostStartupErrorRecord.self, from: data),
      abs(Date().timeIntervalSince(record.recordedAt)) <= maxAge
    else { return nil }
    return record
  }

  static func clear(in directory: URL) {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
  }
}
