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

  private var browser: NWBrowser?

  func start() {
    guard browser == nil else { return }
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: "_aurelia-home._tcp", domain: "local."),
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
        self?.servers = discovered
      }
    }
    self.browser = browser
    browser.start(queue: DispatchQueue(label: "com.lucas.aureliahome.bonjour"))
  }

  func stop() {
    browser?.cancel()
    browser = nil
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
