import Darwin
import Foundation

/// Tries to wake a sleeping server from this Apple TV with a Wake-on-LAN "magic packet".
///
/// tvOS apps may not broadcast on the home network without an entitlement that needs a paid
/// developer account, so the packet goes straight to the server's last IPv4 addresses instead.
/// That reaches the server only while this Apple TV still knows which network card the address
/// belongs to, which is likely shortly after the server fell asleep. The subnet broadcast is
/// tried as well; tvOS refuses it unless the app may broadcast.
enum TVWakeOnLan {
  static let defaultsKey = "AureliaTVWakeOnLan"

  struct Target: Codable, Equatable {
    var hardwareAddresses: [String] = []
    var ipv4Hosts: [String] = []
  }

  /// Remembers what a server reported and where it answered, keyed by its identity.
  static func remember(
    serverID: UUID, info: TVServerInfo?, hosts: [String], defaults: UserDefaults = .standard
  ) {
    var all = load(defaults)
    var target = all[serverID.uuidString] ?? Target()
    let reported = (info?.wakeOnLanAddresses ?? []).compactMap(hardwareAddress).map(format)
    if !reported.isEmpty { target.hardwareAddresses = reported }
    let numeric = hosts.filter(isIPv4)
    if !numeric.isEmpty {
      // The newest addresses first, at most four.
      target.ipv4Hosts = Array(
        (numeric + target.ipv4Hosts.filter { !numeric.contains($0) }).prefix(4))
    }
    guard all[serverID.uuidString] != target else { return }
    all[serverID.uuidString] = target
    if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: defaultsKey) }
  }

  /// Forgets a server this device no longer connects to.
  static func forget(serverID: UUID, defaults: UserDefaults = .standard) {
    var all = load(defaults)
    guard all.removeValue(forKey: serverID.uuidString) != nil else { return }
    if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: defaultsKey) }
  }

  static func target(for serverID: UUID, defaults: UserDefaults = .standard) -> Target? {
    load(defaults)[serverID.uuidString]
  }

  /// Six bytes from "02:00:5e:10:00:01" (or with dashes); anything else is rejected.
  static func hardwareAddress(_ text: String) -> [UInt8]? {
    let parts = text.split(whereSeparator: { $0 == ":" || $0 == "-" })
    guard parts.count == 6 else { return nil }
    let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
    return bytes.count == 6 && bytes.contains(where: { $0 != 0 }) ? bytes : nil
  }

  static func format(_ address: [UInt8]) -> String {
    address.map { String(format: "%02x", $0) }.joined(separator: ":")
  }

  /// Six 0xFF bytes followed by the hardware address sixteen times.
  static func magicPacket(_ address: [UInt8]) -> [UInt8] {
    [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in address }
  }

  static func isIPv4(_ host: String) -> Bool {
    var parsed = in_addr()
    return inet_pton(AF_INET, host, &parsed) == 1
  }

  /// The /24 broadcast address next to a host, such as 192.168.1.255 for 192.168.1.20.
  static func subnetBroadcast(of host: String) -> String? {
    let parts = host.split(separator: ".")
    guard isIPv4(host), parts.count == 4 else { return nil }
    return parts.prefix(3).joined(separator: ".") + ".255"
  }

  /// Sends the packet for every remembered card to the server's remembered addresses. Does
  /// nothing for a server that never reported a card.
  static func wake(serverID: UUID, defaults: UserDefaults = .standard) {
    guard let target = target(for: serverID, defaults: defaults) else { return }
    let cards = target.hardwareAddresses.compactMap(hardwareAddress)
    guard !cards.isEmpty, !target.ipv4Hosts.isEmpty else { return }
    let destinations = Array(
      Set(target.ipv4Hosts + target.ipv4Hosts.compactMap(subnetBroadcast)))
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var enabled: Int32 = 1
    setsockopt(
      descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
    for card in cards {
      let packet = magicPacket(card)
      for host in destinations {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { continue }
        for port: UInt16 in [9, 7] {
          var destination = sockaddr_in()
          destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
          destination.sin_family = sa_family_t(AF_INET)
          destination.sin_port = port.bigEndian
          destination.sin_addr = address
          _ = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
              $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(
                  descriptor, bytes.baseAddress, bytes.count, 0, $0,
                  socklen_t(MemoryLayout<sockaddr_in>.size))
              }
            }
          }
        }
      }
    }
  }

  private static func load(_ defaults: UserDefaults) -> [String: Target] {
    guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
    return (try? JSONDecoder().decode([String: Target].self, from: data)) ?? [:]
  }
}
