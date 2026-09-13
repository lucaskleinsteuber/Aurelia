import AppKit
import Darwin
import Foundation

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

enum HostBootstrapLocation {
  static let appGroupIdentifier = "B5N7JVK37J.com.lucas.aureliahome.host"

  static func directory(fileManager: FileManager = .default) throws -> URL {
    guard
      let container = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    else {
      throw HostLaunchSecurityError.invalidPathLocation
    }

    let directory = container.appendingPathComponent(
      "Library/Caches/AureliaHome/Host", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    return directory.standardizedFileURL
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
}
