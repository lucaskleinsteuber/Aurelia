import Darwin
import Foundation

public enum IOSWakeOnLan {
  public static let defaultsKey = "AureliaIOSWakeOnLan"

  public struct Target: Codable, Equatable, Sendable {
    public var hardwareAddresses: [String] = []
    public var ipv4Hosts: [String] = []

    public init(hardwareAddresses: [String] = [], ipv4Hosts: [String] = []) {
      self.hardwareAddresses = hardwareAddresses
      self.ipv4Hosts = ipv4Hosts
    }
  }

  public static func remember(
    serverID: UUID,
    info: IOSServerInfo?,
    hosts: [String],
    defaults: UserDefaults = .standard
  ) {
    var all = load(defaults)
    var target = all[serverID.uuidString] ?? Target()
    let reported = (info?.wakeOnLanAddresses ?? []).compactMap(hardwareAddress).map(format)
    if !reported.isEmpty { target.hardwareAddresses = reported }
    let numeric = hosts.filter(isIPv4)
    if !numeric.isEmpty {
      target.ipv4Hosts = Array(
        (numeric + target.ipv4Hosts.filter { !numeric.contains($0) }).prefix(4)
      )
    }
    guard all[serverID.uuidString] != target else { return }
    all[serverID.uuidString] = target
    if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: defaultsKey) }
  }

  public static func target(for serverID: UUID, defaults: UserDefaults = .standard) -> Target? {
    load(defaults)[serverID.uuidString]
  }

  public static func hardwareAddress(_ text: String) -> [UInt8]? {
    let parts = text.split(whereSeparator: { $0 == ":" || $0 == "-" })
    guard parts.count == 6 else { return nil }
    let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
    return bytes.count == 6 && bytes.contains(where: { $0 != 0 }) ? bytes : nil
  }

  public static func format(_ address: [UInt8]) -> String {
    address.map { String(format: "%02x", $0) }.joined(separator: ":")
  }

  public static func magicPacket(_ address: [UInt8]) -> [UInt8] {
    [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in address }
  }

  public static func isIPv4(_ host: String) -> Bool {
    var parsed = in_addr()
    return inet_pton(AF_INET, host, &parsed) == 1
  }

  public static func wake(serverID: UUID, defaults: UserDefaults = .standard) {
    guard let target = target(for: serverID, defaults: defaults) else { return }
    let rawAddresses = target.hardwareAddresses.compactMap(hardwareAddress)
    guard !rawAddresses.isEmpty else { return }

    var targets = Set<in_addr_t>()
    targets.insert(INADDR_BROADCAST)
    for host in target.ipv4Hosts {
      var parsed = in_addr()
      if inet_pton(AF_INET, host, &parsed) == 1 { targets.insert(parsed.s_addr) }
    }

    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var enabled: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

    for address in rawAddresses {
      let packet = magicPacket(address)
      for host in targets {
        for port: UInt16 in [9, 7] {
          var destination = sockaddr_in()
          destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
          destination.sin_family = sa_family_t(AF_INET)
          destination.sin_port = port.bigEndian
          destination.sin_addr = in_addr(s_addr: host)
          _ = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
              $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(
                  descriptor, bytes.baseAddress, bytes.count, 0, $0,
                  socklen_t(MemoryLayout<sockaddr_in>.size)
                )
              }
            }
          }
        }
      }
    }
  }

  private static func load(_ defaults: UserDefaults) -> [String: Target] {
    guard let data = defaults.data(forKey: defaultsKey),
      let value = try? JSONDecoder().decode([String: Target].self, from: data)
    else { return [:] }
    return value
  }
}
