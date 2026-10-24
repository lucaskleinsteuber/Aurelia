import Darwin
import Foundation

/// Where to open Aurelia in a web browser. The server serves the browser app itself, so this is
/// the server's own HTTPS address as other devices at home reach it.
struct BrowserAddress: Equatable, Sendable {
  let url: URL
  /// The server's home-network access is off: only a browser on this Mac reaches it.
  let thisMacOnly: Bool

  /// - Parameters:
  ///   - serverURL: the address this Mac uses for the server.
  ///   - lanAccessEnabled, lanPort: the home-network access of a server running on this Mac.
  static func resolve(
    serverURL: URL, lanAccessEnabled: Bool?, lanPort: Int?,
    localIPv4: () -> String? = BrowserAddress.privateIPv4
  ) -> BrowserAddress? {
    guard let host = serverURL.host, !host.isEmpty else { return nil }
    var parts = URLComponents()
    if !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
      parts.scheme = "https"
      parts.host = host
      parts.port = serverURL.port
      return parts.url.map { BrowserAddress(url: $0, thisMacOnly: false) }
    }
    if lanAccessEnabled == true, let address = localIPv4() {
      parts.scheme = "https"
      parts.host = address
      parts.port = lanPort ?? 43_111
      return parts.url.map { BrowserAddress(url: $0, thisMacOnly: false) }
    }
    parts.scheme = serverURL.scheme
    parts.host = host
    parts.port = serverURL.port
    return parts.url.map { BrowserAddress(url: $0, thisMacOnly: true) }
  }

  /// This Mac's address in the home network (10/8, 172.16/12 or 192.168/16), Wi-Fi or Ethernet
  /// first.
  static func privateIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    var candidates: [(name: String, address: String)] = []
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(entry.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
        let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
      else { continue }
      let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
      }
      guard isPrivate(value) else { continue }
      let text = "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
      candidates.append((String(cString: entry.pointee.ifa_name), text))
    }
    return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
  }

  static func isPrivate(_ address: UInt32) -> Bool {
    address >> 24 == 10 || address >> 20 == 0xAC1 || address >> 16 == 0xC0A8
  }
}
