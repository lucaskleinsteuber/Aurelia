import Foundation
import Network

public struct IOSDiscoveredServer: Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let host: String
  public let port: Int

  public init(id: String, name: String, host: String, port: Int) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
  }
}

public final class IOSBonjourBrowser: @unchecked Sendable {
  public typealias DiscoveryHandler = @Sendable ([IOSDiscoveredServer]) -> Void

  private let queue = DispatchQueue(label: "com.lucas.aurelia.ios.bonjour")
  private var browser: NWBrowser?
  private var handler: DiscoveryHandler?
  private var discovered: [String: IOSDiscoveredServer] = [:]

  public init() {}

  public func start(handler: @escaping DiscoveryHandler) {
    self.handler = handler
    let descriptor = NWBrowser.Descriptor.bonjour(type: "_aurelia._tcp", domain: "local.")
    let parameters = NWParameters()
    parameters.includePeerToPeer = true

    let browser = NWBrowser(for: descriptor, using: parameters)
    self.browser = browser

    browser.browseResultsChangedHandler = { [weak self] results, changes in
      self?.handleResults(results)
    }

    browser.start(queue: queue)
  }

  public func stop() {
    browser?.cancel()
    browser = nil
    discovered.removeAll()
  }

  private func handleResults(_ results: Set<NWBrowser.Result>) {
    var newServers: [String: IOSDiscoveredServer] = [:]
    for result in results {
      if case .service(let name, _, _, _) = result.endpoint {
        let server = IOSDiscoveredServer(
          id: name,
          name: name,
          host: "\(name).local",
          port: 43111
        )
        newServers[name] = server
      }
    }
    self.discovered = newServers
    let list = Array(newServers.values)
    handler?(list)
  }
}
