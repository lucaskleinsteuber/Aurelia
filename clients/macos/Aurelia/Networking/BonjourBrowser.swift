import Darwin
import Foundation
@preconcurrency import Network

struct DiscoveredServer: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let serverId: UUID?
  let baseURL: URL
  var alternativeURLs: [URL] = []

  var addresses: [URL] {
    Array(Set([baseURL] + alternativeURLs)).sorted { $0.absoluteString < $1.absoluteString }
  }
}

/// TXT records are hints, never an authentication or trust decision.
struct BonjourServiceDescription: Hashable, Sendable {
  let name: String
  let type: String
  let domain: String
  let displayName: String
  let serverId: UUID?
  var key: String { "\(name)|\(type)|\(domain)" }

  func resolved(host: String?, port: Int, numericHosts: [String]) -> DiscoveredServer? {
    guard (1...65_535).contains(port) else { return nil }
    let hosts = (host.map { [$0] } ?? []) + numericHosts.sorted()
    let addresses = hosts.compactMap { host -> URL? in
      guard !host.isEmpty else { return nil }
      var components = URLComponents()
      components.scheme = "https"
      // URLComponents requires brackets for IPv6, including scoped link-local addresses.
      components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
      components.port = port
      return components.url
    }
    guard let first = addresses.first else { return nil }
    return DiscoveredServer(
      id: serverId?.uuidString.lowercased() ?? key, name: displayName,
      serverId: serverId, baseURL: first, alternativeURLs: Array(Set(addresses.dropFirst())))
  }
}

@MainActor
final class BonjourBrowser: ObservableObject {
  @Published private(set) var servers: [DiscoveredServer] = []
  @Published private(set) var errorMessage: String?

  private var browsers: [String: NWBrowser] = [:]
  private var resultsByType: [String: Set<BonjourServiceDescription>] = [:]
  private var resolvers: [String: BonjourServiceResolver] = [:]
  private var resolved: [String: DiscoveredServer] = [:]
  private var retryTasks: [String: Task<Void, Never>] = [:]
  private var run = UUID()

  func start() {
    guard browsers.isEmpty else { return }
    errorMessage = nil
    for type in ["_aurelia._tcp", "_aurelia-home._tcp"] { startBrowser(type: type, attempt: 0) }
  }

  private func startBrowser(type: String, attempt: Int) {
    let generation = run
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: .tcp)
    browser.stateUpdateHandler = { [weak self] state in
      guard case .failed = state else { return }
      Task { @MainActor in
        guard let self, self.run == generation else { return }
        self.errorMessage = "Server discovery is temporarily unavailable. You can enter an address."
        self.browsers.removeValue(forKey: type)?.cancel()
        guard attempt < 4 else { return }
        self.retryTasks[type] = Task { [weak self] in
          do {
            try await Task.sleep(for: .seconds(ServerReconnectPolicy.delay(attempt: attempt)))
          } catch { return }
          guard let self, self.run == generation else { return }
          self.startBrowser(type: type, attempt: attempt + 1)
        }
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let descriptions = Set(results.compactMap(Self.description(from:)))
      Task { @MainActor in
        guard let self, self.run == generation else { return }
        self.errorMessage = nil
        self.resultsByType[type] = descriptions
        self.updateResolvers(generation: generation)
      }
    }
    browsers[type] = browser
    browser.start(queue: DispatchQueue(label: "com.lucas.aurelia.media.bonjour.\(type)"))
  }

  private func updateResolvers(generation: UUID) {
    let services = Set(resultsByType.values.flatMap { $0 })
    let keys = Set(services.map(\.key))
    for key in Array(resolvers.keys) where !keys.contains(key) {
      resolvers.removeValue(forKey: key)?.stop()
      resolved.removeValue(forKey: key)
    }
    for service in services.sorted(by: { $0.key < $1.key }).prefix(128) {
      guard resolvers[service.key] == nil else { continue }
      let resolver = BonjourServiceResolver(description: service) { [weak self] result in
        guard let self, self.run == generation, self.resolvers[service.key] != nil else { return }
        self.resolved[service.key] = result
        self.publishServers()
      }
      resolvers[service.key] = resolver
      resolver.start()
    }
    publishServers()
  }

  private func publishServers() {
    servers = Self.merged(Array(resolved.values))
  }

  static func merged(_ results: [DiscoveredServer]) -> [DiscoveredServer] {
    Dictionary(grouping: results, by: \.id).compactMap { _, duplicates in
      guard
        let first = duplicates.sorted(by: { $0.baseURL.absoluteString < $1.baseURL.absoluteString })
          .first
      else {
        return nil
      }
      let addresses = duplicates.flatMap(\.addresses)
      return DiscoveredServer(
        id: first.id, name: first.name, serverId: first.serverId, baseURL: first.baseURL,
        alternativeURLs: Array(Set(addresses).subtracting([first.baseURL])).sorted {
          $0.absoluteString < $1.absoluteString
        })
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func stop() {
    run = UUID()
    for task in retryTasks.values { task.cancel() }
    retryTasks = [:]
    for browser in browsers.values { browser.cancel() }
    browsers = [:]
    for resolver in resolvers.values { resolver.stop() }
    resolvers = [:]
    resultsByType = [:]
    resolved = [:]
    servers = []
  }

  nonisolated private static func description(from result: NWBrowser.Result)
    -> BonjourServiceDescription?
  {
    guard case .service(let name, let type, let domain, _) = result.endpoint,
      case .bonjour(let record) = result.metadata, record.dictionary["tls"] == "1"
    else { return nil }
    return BonjourServiceDescription(
      name: name, type: type, domain: domain, displayName: record.dictionary["name"] ?? name,
      serverId: record.dictionary["id"].flatMap(UUID.init(uuidString:)))
  }
}

@MainActor
private final class BonjourServiceResolver: NSObject, @preconcurrency NetServiceDelegate {
  private let serviceDescription: BonjourServiceDescription
  private let service: NetService
  private let completion: (DiscoveredServer?) -> Void
  private var stopped = false
  private var retryTask: Task<Void, Never>?
  private var attempts = 0

  init(description: BonjourServiceDescription, completion: @escaping (DiscoveredServer?) -> Void) {
    self.serviceDescription = description
    self.completion = completion
    service = NetService(domain: description.domain, type: description.type, name: description.name)
    super.init()
    service.delegate = self
  }

  func start() { service.resolve(withTimeout: 5) }
  func stop() {
    stopped = true
    retryTask?.cancel()
    service.stop()
    service.delegate = nil
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard !stopped else { return }
    let hosts = (sender.addresses ?? []).compactMap { address -> String? in
      address.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress, buffer.count >= MemoryLayout<sockaddr>.size else {
          return nil
        }
        let socket = base.assumingMemoryBound(to: sockaddr.self)
        guard
          socket.pointee.sa_family == sa_family_t(AF_INET)
            || socket.pointee.sa_family == sa_family_t(AF_INET6)
        else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard
          getnameinfo(
            socket, socklen_t(buffer.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            == 0
        else { return nil }
        return String(
          decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      }
    }
    completion(
      serviceDescription.resolved(host: sender.hostName, port: sender.port, numericHosts: hosts))
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    guard !stopped, attempts < 3 else { return }
    let attempt = attempts
    attempts += 1
    retryTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(ServerReconnectPolicy.delay(attempt: attempt)))
      } catch { return }
      guard let self, !self.stopped else { return }
      self.start()
    }
  }
}
