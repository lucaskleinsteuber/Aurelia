import Foundation
import Security

/// Wakes a sleeping server through the home router, for everyone who sets it up on their Apple TV.
///
/// A tvOS app may broadcast on the home network only with Apple's multicast entitlement; without
/// it, the app's own magic packet reaches the server only shortly after the server fell asleep
/// (see `TVWakeOnLan`). The router is always on and can send the packet itself. The first
/// supported router is the FRITZ!Box, asked over its TR-064 interface
/// (`X_AVM-DE_WakeOnLANByMACAddress`); the request uses HTTP digest authentication, so the
/// password itself never travels over the network. Other routers can be added beside it.
enum TVRouterWake {
  struct Account: Codable, Equatable, Sendable {
    var host: String
    var username: String
    var password: String
  }

  enum Failure: Error, Equatable, Sendable {
    case invalidAddress
    case unreachable
    case wrongCredentials
    case notPermitted
    case unknownDevice
    case unexpected(Int)

    var message: String {
      switch self {
      case .invalidAddress: "Enter the FRITZ!Box address, such as fritz.box or 192.168.178.1."
      case .unreachable:
        "The FRITZ!Box didn’t answer. Check the address and that “Allow access for applications” is on in Home Network › Network › Network Settings."
      case .wrongCredentials: "The FRITZ!Box user name or password is wrong."
      case .notPermitted:
        "This FRITZ!Box user may not wake devices. Give it the right to change FRITZ!Box settings."
      case .unknownDevice:
        "The FRITZ!Box doesn’t know the server yet. Turn the server on once while it is on this network."
      case .unexpected(let code): "The FRITZ!Box refused the request (error \(code))."
      }
    }
  }

  static let defaultHost = "fritz.box"
  static let port = 49000
  static let hostsService = "urn:dslforum-org:service:Hosts:1"
  static let controlPath = "/upnp/control/hosts"

  /// A plain host name or IPv4 address; a pasted "http://fritz.box/" is accepted too.
  static func normalizedHost(_ text: String) -> String? {
    var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for prefix in ["http://", "https://"] where host.hasPrefix(prefix) {
      host.removeFirst(prefix.count)
    }
    while host.hasSuffix("/") { host.removeLast() }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
    guard !host.isEmpty, host.count <= 253, host.unicodeScalars.allSatisfy(allowed.contains),
      !host.hasPrefix("."), !host.hasPrefix("-")
    else { return nil }
    return host
  }

  /// The form the FRITZ!Box expects: "AA:BB:CC:DD:EE:FF".
  static func macArgument(_ address: [UInt8]) -> String {
    address.map { String(format: "%02X", $0) }.joined(separator: ":")
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }

  static func envelope(action: String, arguments: [(String, String)]) -> String {
    let values = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
    return """
      <?xml version="1.0" encoding="utf-8"?>\
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
      s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
      <s:Body><u:\(action) xmlns:u="\(hostsService)">\(values)</u:\(action)></s:Body></s:Envelope>
      """
  }

  static func request(host: String, action: String, arguments: [(String, String)] = [])
    -> URLRequest?
  {
    guard let host = normalizedHost(host),
      let url = URL(string: "http://\(host):\(port)\(controlPath)")
    else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 6)
    request.httpMethod = "POST"
    request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
    request.setValue("\(hostsService)#\(action)", forHTTPHeaderField: "SOAPAction")
    request.httpBody = Data(envelope(action: action, arguments: arguments).utf8)
    return request
  }

  /// The UPnP error code of a SOAP fault, if the answer carries one.
  static func faultCode(in data: Data) -> Int? {
    guard let text = String(data: data, encoding: .utf8),
      let start = text.range(of: "<errorCode>"),
      let end = text.range(of: "</errorCode>", range: start.upperBound..<text.endIndex)
    else { return nil }
    return Int(text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces))
  }

  static func outcome(status: Int, data: Data) -> Failure? {
    if (200..<300).contains(status) { return nil }
    if status == 401 { return .wrongCredentials }
    switch faultCode(in: data) {
    case 606?: return .notPermitted
    case 714?, 402?: return .unknownDevice
    case let code?: return .unexpected(code)
    case nil: return .unexpected(status)
    }
  }

  /// Asks the FRITZ!Box to wake every given network card. Succeeds when it accepted one of them.
  static func wake(
    cards: [[UInt8]], account: Account, transport: any TVRouterWakeTransport
  ) async -> Failure? {
    guard normalizedHost(account.host) != nil else { return .invalidAddress }
    var last: Failure = .unknownDevice
    for card in cards {
      guard
        let request = request(
          host: account.host, action: "X_AVM-DE_WakeOnLANByMACAddress",
          arguments: [("NewMACAddress", macArgument(card))])
      else { return .invalidAddress }
      do {
        let (data, status) = try await transport.send(
          request, username: account.username, password: account.password)
        guard let failure = outcome(status: status, data: data) else { return nil }
        // Wrong credentials or rights are the same for every card.
        if failure == .wrongCredentials || failure == .notPermitted { return failure }
        last = failure
      } catch {
        return .unreachable
      }
    }
    return last
  }

  /// Checks the address and the sign-in without waking anything.
  static func check(account: Account, transport: any TVRouterWakeTransport) async -> Failure? {
    guard let request = request(host: account.host, action: "GetHostNumberOfEntries") else {
      return .invalidAddress
    }
    do {
      let (data, status) = try await transport.send(
        request, username: account.username, password: account.password)
      return outcome(status: status, data: data)
    } catch {
      return .unreachable
    }
  }
}

protocol TVRouterWakeTransport: Sendable {
  /// Sends the request, answering a digest challenge with the given user. Returns the body and
  /// the HTTP status.
  func send(_ request: URLRequest, username: String, password: String) async throws -> (Data, Int)
}

struct TVRouterWakeURLSessionTransport: TVRouterWakeTransport {
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 6
    configuration.timeoutIntervalForResource = 10
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    return URLSession(configuration: configuration)
  }()

  func send(_ request: URLRequest, username: String, password: String) async throws -> (Data, Int)
  {
    let (data, response) = try await session.data(
      for: request, delegate: DigestAnswer(username: username, password: password))
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  /// Answers only a digest challenge, and only once, so a wrong password ends in a 401 and the
  /// password is never sent as plain text.
  private final class DigestAnswer: NSObject, URLSessionTaskDelegate, Sendable {
    let username: String
    let password: String
    init(username: String, password: String) {
      self.username = username
      self.password = password
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
      guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest,
        challenge.previousFailureCount == 0
      else { return (.rejectProtectionSpace, nil) }
      return (.useCredential, URLCredential(user: username, password: password, persistence: .none))
    }
  }
}

/// Where the FRITZ!Box sign-in is kept.
protocol TVRouterWakeStore: Sendable {
  func load() -> TVRouterWake.Account?
  func save(_ account: TVRouterWake.Account) throws
  func delete()
}

/// The Keychain of this Apple TV only, never synchronized.
struct TVRouterWakeKeychainStore: TVRouterWakeStore {
  private static let service = "com.lucas.aurelia.tvos.router-wake"
  private static let account = "wake"

  func load() -> TVRouterWake.Account? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(TVRouterWake.Account.self, from: data)
  }

  func save(_ account: TVRouterWake.Account) throws {
    let data = try JSONEncoder().encode(account)
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var query = baseQuery
      for (key, value) in update { query[key] = value }
      status = SecItemAdd(query as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw NSError(
        domain: NSOSStatusErrorDomain, code: Int(status),
        userInfo: [
          NSLocalizedDescriptionKey: "The FRITZ!Box sign-in could not be saved securely."
        ])
    }
  }

  func delete() { SecItemDelete(baseQuery as CFDictionary) }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account, kSecAttrSynchronizable as String: false,
    ]
  }
}

/// Keeps the sign-in in memory only, for tests and UI test scenarios.
final class TVRouterWakeMemoryStore: TVRouterWakeStore, @unchecked Sendable {
  private let lock = NSLock()
  private var account: TVRouterWake.Account?
  init(_ account: TVRouterWake.Account? = nil) { self.account = account }
  func load() -> TVRouterWake.Account? { lock.withLock { account } }
  func save(_ account: TVRouterWake.Account) throws { lock.withLock { self.account = account } }
  func delete() { lock.withLock { account = nil } }
}
