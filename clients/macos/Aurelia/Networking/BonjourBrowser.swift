import Foundation
@preconcurrency import Network

struct DiscoveredServer: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let serverId: UUID?
  let baseURL: URL
}

@MainActor
final class BonjourBrowser: ObservableObject {
  @Published private(set) var servers: [DiscoveredServer] = []
  @Published private(set) var errorMessage: String?

  private var browsers: [String: NWBrowser] = [:]
  private var resultsByType: [String: [DiscoveredServer]] = [:]

  func start() {
    guard browsers.isEmpty else { return }
    for type in ["_aurelia._tcp", "_aurelia-home._tcp"] {
      startBrowser(type: type)
    }
  }

  private func startBrowser(type: String) {
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: type, domain: "local."),
      using: .tcp)
    browser.stateUpdateHandler = { [weak self] state in
      guard case .failed(let error) = state else { return }
      Task { @MainActor in
        self?.errorMessage = "Server discovery failed: \(error.localizedDescription)"
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let discovered = results.compactMap(Self.server(from:))
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      Task { @MainActor in
        guard let self else { return }
        self.resultsByType[type] = discovered
        var seen = Set<String>()
        self.servers = self.resultsByType.values.flatMap { $0 }
          .filter { seen.insert($0.id).inserted }
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      }
    }
    browsers[type] = browser
    browser.start(queue: DispatchQueue(label: "com.lucas.aurelia.media.bonjour.\(type)"))
  }

  func stop() {
    browsers.values.forEach { $0.cancel() }
    browsers = [:]
    resultsByType = [:]
    servers = []
  }

  nonisolated private static func server(from result: NWBrowser.Result) -> DiscoveredServer? {
    guard case .service(let name, _, _, _) = result.endpoint,
      case .bonjour(let record) = result.metadata
    else {
      return nil
    }
    let properties = record.dictionary
    guard properties["tls"] == "1",
      let portText = properties["port"],
      let port = Int(portText),
      (1...65_535).contains(port)
    else {
      return nil
    }
    let host = sanitizeHostLabel(name) + ".local"
    guard let baseURL = URL(string: "https://\(host):\(port)") else {
      return nil
    }
    return DiscoveredServer(
      id: properties["id"] ?? "\(name)-\(port)",
      name: properties["name"] ?? name,
      serverId: properties["id"].flatMap(UUID.init(uuidString:)),
      baseURL: baseURL)
  }

  nonisolated static func sanitizeHostLabel(_ name: String) -> String {
    var result = ""
    var lastWasHyphen = false
    for scalar in name.unicodeScalars {
      let isASCIIAlphaNumeric =
        scalar.isASCII
        && (CharacterSet.alphanumerics.contains(scalar))
      if isASCIIAlphaNumeric {
        result.unicodeScalars.append(scalar)
        lastWasHyphen = false
      } else if !lastWasHyphen && !result.isEmpty {
        result.append("-")
        lastWasHyphen = true
      }
    }
    if result.last == "-" {
      result.removeLast()
    }
    return result.isEmpty ? "device" : result
  }
}
