import Darwin
import Foundation

/// Why the title plays in Apple's player for a while instead of VLC: VLC can't hand its picture to
/// Picture in Picture or send it to an AirPlay screen, Apple's player can, from the server's HLS
/// stream (its live conversion, adaptive-streaming-v1).
enum IOSSystemPlaybackReason: Equatable, Sendable {
  case pictureInPicture
  case airPlay
}

/// Hand-over between VLC and Apple's player. Only the position and whether it played travel; the
/// HLS stream carries the file's default sound and no subtitles.
enum IOSSystemPlaybackPhase: Equatable, Sendable {
  case vlc
  /// Apple's player is opening the HLS stream at the position VLC was at.
  case starting(IOSSystemPlaybackReason, position: Int64, playing: Bool)
  case system(IOSSystemPlaybackReason)

  var reason: IOSSystemPlaybackReason? {
    switch self {
    case .vlc: nil
    case .starting(let reason, _, _), .system(let reason): reason
    }
  }

  /// The app may go to the background without closing the player.
  var continuesInBackground: Bool { self != .vlc }
}

enum IOSSystemPlayback {
  /// The HLS master below the relay's stream address, also when VLC already plays HLS.
  static func hlsURL(for stream: URL) -> URL {
    if stream.path.hasSuffix("/hls/master.m3u8") { return stream }
    return stream.appendingPathComponent("hls").appendingPathComponent("master.m3u8")
  }

  /// Where VLC goes on after Apple's player: its position, a little back so nothing is missed,
  /// never past the end.
  static func returnPosition(_ position: Int64, duration: Int64) -> Int64 {
    let back = max(0, position - 1_000)
    return duration > 0 ? min(back, max(0, duration - 1_000)) : back
  }

  /// Whether an output route is an AirPlay screen or speaker: the port type AVFoundation reports.
  static func isAirPlay(portTypes: [String]) -> Bool { portTypes.contains("AirPlay") }

  /// This device's IPv4 address on Wi-Fi or Ethernet, for the AirPlay receiver to fetch from.
  /// Cellular and link-local addresses never count.
  static func networkAddress(
    interfaces: [(name: String, address: String)] = currentInterfaces()
  ) -> String? {
    let preferred = ["en0", "en1", "en2", "bridge100"]
    let usable = interfaces.filter { entry in
      entry.name.hasPrefix("en") && !entry.address.hasPrefix("169.254.")
        && !entry.address.hasPrefix("127.")
    }
    for name in preferred {
      if let match = usable.first(where: { $0.name == name }) { return match.address }
    }
    return usable.first?.address
  }

  static func currentInterfaces() -> [(name: String, address: String)] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let first else { return [] }
    defer { freeifaddrs(first) }
    var found: [(name: String, address: String)] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      let flags = Int32(entry.pointee.ifa_flags)
      guard let socket = entry.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
        flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      let name = String(cString: entry.pointee.ifa_name)
      found.append((name, String(decoding: bytes, as: UTF8.self)))
    }
    return found
  }
}
