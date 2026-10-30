import Combine
import Darwin
import Foundation
@preconcurrency import Network

struct IOSDiscoveredServer: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let serverID: UUID?
  let baseURL: URL
  var alternativeURLs: [URL] = []

  var addresses: [URL] {
    Array(Set([baseURL] + alternativeURLs)).sorted { $0.absoluteString < $1.absoluteString }
  }
}

struct IOSBonjourService: Hashable, Sendable {
  let name: String
  let type: String
  let domain: String
  let displayName: String
  let serverID: UUID?
  var key: String { "\(name)|\(type)|\(domain)" }

  func resolved(host: String?, port: Int, numericHosts: [String]) -> IOSDiscoveredServer? {
    guard (1...65_535).contains(port) else { return nil }
    let hosts = (host.map { [$0] } ?? []) + numericHosts.sorted()
    let addresses = hosts.compactMap { host -> URL? in
      guard !host.isEmpty else { return nil }
      var components = URLComponents()
      components.scheme = "https"
      components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
      components.port = port
      guard let url = components.url, IOSServerAddress.isValid(url) else { return nil }
      return url
    }
    guard let primary = addresses.first else { return nil }
    return IOSDiscoveredServer(
      id: serverID?.uuidString.lowercased() ?? key, name: displayName,
      serverID: serverID, baseURL: primary, alternativeURLs: Array(Set(addresses.dropFirst())))
  }
}

@MainActor
final class IOSBonjourBrowser: ObservableObject {
  @Published private(set) var servers: [IOSDiscoveredServer] = []
  @Published private(set) var errorMessage: String?
  private var browsers: [String: NWBrowser] = [:]
  private var services: [String: Set<IOSBonjourService>] = [:]
  private var resolvers: [String: IOSBonjourResolver] = [:]
  private var resolved: [String: IOSDiscoveredServer] = [:]
  private var retries: [String: Task<Void, Never>] = [:]
  private var generation = UUID()

  func start() {
    guard browsers.isEmpty else { return }
    errorMessage = nil
    // Every server this client supports advertises this type; iOS lets an app browse only the
    // types its Info.plist declares.
    browse(type: "_aurelia._tcp", attempt: 0)
  }

  func stop() {
    generation = UUID()
    for task in retries.values { task.cancel() }
    retries = [:]
    for browser in browsers.values { browser.cancel() }
    browsers = [:]
    for resolver in resolvers.values { resolver.stop() }
    resolvers = [:]
    services = [:]
    resolved = [:]
    servers = []
  }

  private func browse(type: String, attempt: Int) {
    let operation = generation
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: .tcp)
    browser.stateUpdateHandler = { [weak self] state in
      guard case .failed = state else { return }
      Task { @MainActor in
        guard let self, self.generation == operation else { return }
        self.errorMessage = "Server discovery is unavailable. Enter the server address to connect."
        self.browsers.removeValue(forKey: type)?.cancel()
        guard attempt < 4 else { return }
        self.retries[type] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(Self.retryDelay(attempt: attempt))) } catch {
            return
          }
          guard let self, self.generation == operation else { return }
          self.browse(type: type, attempt: attempt + 1)
        }
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let descriptions = Set(results.compactMap(Self.description))
      Task { @MainActor in
        guard let self, self.generation == operation else { return }
        self.errorMessage = nil
        self.services[type] = descriptions
        self.updateResolvers()
      }
    }
    browsers[type] = browser
    browser.start(queue: DispatchQueue(label: "com.lucas.aurelia.ios.discovery.\(type)"))
  }

  private func updateResolvers() {
    let current = Set(services.values.flatMap { $0 })
    let keys = Set(current.map(\.key))
    for key in Array(resolvers.keys) where !keys.contains(key) {
      resolvers.removeValue(forKey: key)?.stop()
      resolved.removeValue(forKey: key)
    }
    let operation = generation
    for service in current.sorted(by: { $0.key < $1.key }).prefix(128)
    where resolvers[service.key] == nil {
      let resolver = IOSBonjourResolver(description: service) { [weak self] result in
        guard let self, self.generation == operation, self.resolvers[service.key] != nil else {
          return
        }
        self.resolved[service.key] = result
        self.servers = Self.merged(Array(self.resolved.values))
      }
      resolvers[service.key] = resolver
      resolver.start()
    }
    servers = Self.merged(Array(resolved.values))
  }

  nonisolated static func merged(_ entries: [IOSDiscoveredServer]) -> [IOSDiscoveredServer] {
    Dictionary(grouping: entries, by: \.id).compactMap { _, duplicates in
      guard
        let first = duplicates.sorted(by: { $0.baseURL.absoluteString < $1.baseURL.absoluteString })
          .first
      else {
        return nil
      }
      let alternatives = Array(Set(duplicates.flatMap(\.addresses)).subtracting([first.baseURL]))
        .sorted { $0.absoluteString < $1.absoluteString }
      return IOSDiscoveredServer(
        id: first.id, name: first.name, serverID: first.serverID,
        baseURL: first.baseURL, alternativeURLs: alternatives)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  nonisolated static func retryDelay(attempt: Int) -> TimeInterval {
    [3.0, 6, 12, 30][min(max(attempt, 0), 3)]
  }

  nonisolated private static func description(_ result: NWBrowser.Result) -> IOSBonjourService? {
    guard case .service(let name, let type, let domain, _) = result.endpoint,
      case .bonjour(let record) = result.metadata, record.dictionary["tls"] == "1"
    else { return nil }
    return IOSBonjourService(
      name: name, type: type, domain: domain,
      displayName: record.dictionary["name"] ?? name,
      serverID: record.dictionary["id"].flatMap(UUID.init(uuidString:)))
  }
}

@MainActor
private final class IOSBonjourResolver: NSObject, @preconcurrency NetServiceDelegate {
  private let descriptionValue: IOSBonjourService
  private let service: NetService
  private let completion: (IOSDiscoveredServer?) -> Void
  private var stopped = false
  private var attempt = 0
  private var retry: Task<Void, Never>?

  init(description: IOSBonjourService, completion: @escaping (IOSDiscoveredServer?) -> Void) {
    descriptionValue = description
    self.completion = completion
    service = NetService(domain: description.domain, type: description.type, name: description.name)
    super.init()
    service.delegate = self
  }
  func start() { service.resolve(withTimeout: 5) }
  func stop() {
    stopped = true
    retry?.cancel()
    service.stop()
    service.delegate = nil
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard !stopped else { return }
    let numericHosts = (sender.addresses ?? []).compactMap { address -> String? in
      address.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress, bytes.count >= MemoryLayout<sockaddr>.size else {
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
            socket, socklen_t(bytes.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            == 0
        else {
          return nil
        }
        return String(
          decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      }
    }
    completion(
      descriptionValue.resolved(
        host: sender.hostName, port: sender.port, numericHosts: numericHosts))
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    guard !stopped, attempt < 3 else { return }
    let delay = IOSBonjourBrowser.retryDelay(attempt: attempt)
    attempt += 1
    retry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self, !self.stopped else { return }
      self.start()
    }
  }
}
