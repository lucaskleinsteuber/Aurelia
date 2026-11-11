import AppKit
import Darwin
import Foundation

/// Wakes a sleeping server, such as a Linux server that goes to standby when nobody watches,
/// with a Wake-on-LAN "magic packet". The server reports the hardware addresses of its network
/// cards while it is awake; this Mac remembers them per server and broadcasts the packet on the
/// home network when the server stops answering.
enum WakeOnLan {
  static let defaultsKey = "AureliaWakeOnLanAddresses"

  /// Waking is for someone who wants to watch now: Aurelia is in front and the keyboard, mouse or
  /// trackpad was used within two minutes. Background sync on an unattended Mac, for example
  /// after a sleep timer ended at night, must not keep waking the server.
  @MainActor static var userIsPresent: Bool {
    guard NSApplication.shared.isActive, let anyInput = CGEventType(rawValue: ~0) else {
      return false
    }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
      < 120
  }

  static let hostingKey = "AureliaServerHosting"

  /// A server the Aurelia app hosts on a Mac ("macApp") or Linux PC ("linuxApp"), as it last said;
  /// nil for a server that runs on its own. Such a server is started by opening Aurelia there,
  /// never woken over the network.
  static func appHost(for serverId: UUID, defaults: UserDefaults = .standard) -> String? {
    let stored = defaults.dictionary(forKey: hostingKey) as? [String: String] ?? [:]
    return stored[serverId.uuidString].flatMap { $0 == "macApp" || $0 == "linuxApp" ? $0 : nil }
  }

  /// Remembers the wake addresses a server reported, keyed by its identity, and where it runs.
  static func remember(_ info: ServerInfoResponse, defaults: UserDefaults = .standard) {
    if let hosting = info.hosting {
      var kinds = defaults.dictionary(forKey: hostingKey) as? [String: String] ?? [:]
      if kinds[info.serverId.uuidString] != hosting {
        kinds[info.serverId.uuidString] = hosting
        defaults.set(kinds, forKey: hostingKey)
      }
      if hosting == "macApp" || hosting == "linuxApp" {
        // A desktop or laptop is started by its owner; old addresses must not wake it.
        var stored = defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        if stored.removeValue(forKey: info.serverId.uuidString) != nil { defaults.set(stored, forKey: defaultsKey) }
        return
      }
    }
    let addresses = (info.wakeOnLanAddresses ?? []).compactMap(hardwareAddress).map(format)
    guard !addresses.isEmpty else { return }
    var stored = defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
    guard stored[info.serverId.uuidString] != addresses else { return }
    stored[info.serverId.uuidString] = addresses
    defaults.set(stored, forKey: defaultsKey)
  }

  static func addresses(for serverId: UUID, defaults: UserDefaults = .standard) -> [[UInt8]] {
    let stored = defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
    return (stored[serverId.uuidString] ?? []).compactMap(hardwareAddress)
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

  /// Broadcasts the packet for every remembered address of the server on each local network,
  /// and sends it to the server's last IPv4 address too. Does nothing for a server that never
  /// reported an address.
  static func wake(serverId: UUID, lastKnown: URL?, defaults: UserDefaults = .standard) {
    let addresses = addresses(for: serverId, defaults: defaults)
    guard !addresses.isEmpty else { return }
    var targets = Set(broadcastAddresses())
    targets.insert(INADDR_BROADCAST)
    if let host = lastKnown?.host {
      var parsed = in_addr()
      if inet_pton(AF_INET, host, &parsed) == 1 { targets.insert(parsed.s_addr) }
    }
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var enabled: Int32 = 1
    setsockopt(
      descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
    for address in addresses {
      let packet = magicPacket(address)
      for target in targets {
        for port: UInt16 in [9, 7] {
          var destination = sockaddr_in()
          destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
          destination.sin_family = sa_family_t(AF_INET)
          destination.sin_port = port.bigEndian
          destination.sin_addr = in_addr(s_addr: target)
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

  /// The broadcast address of every IPv4 network this Mac is on, in network byte order.
  private static func broadcastAddresses() -> [in_addr_t] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    var result: [in_addr_t] = []
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(entry.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
        let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
        let broadcast = entry.pointee.ifa_dstaddr
      else { continue }
      broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        result.append($0.pointee.sin_addr.s_addr)
      }
    }
    return result
  }
}
