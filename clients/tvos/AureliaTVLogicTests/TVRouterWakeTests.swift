import Foundation
import Testing

@Suite("TV router wake")
struct TVRouterWakeTests {
  /// Answers from a script and records every request; no network is used.
  final class ScriptedTransport: TVRouterWakeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<(Int, String), URLError>]
    private(set) var requests: [(URLRequest, String, String)] = []
    init(_ answers: [Result<(Int, String), URLError>]) { self.answers = answers }

    func send(_ request: URLRequest, username: String, password: String) async throws -> (
      Data, Int
    ) {
      let answer = lock.withLock {
        requests.append((request, username, password))
        return answers.isEmpty ? .success((200, "")) : answers.removeFirst()
      }
      let (status, body) = try answer.get()
      return (Data(body.utf8), status)
    }
  }

  private static func fault(_ code: Int) -> String {
    "<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>\(code)</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
  }

  private let account = TVRouterWake.Account(
    host: "fritz.box", username: "synthetic-user", password: "synthetic-secret")
  private let card: [UInt8] = [0x02, 0x00, 0x5e, 0x10, 0x00, 0x01]

  @Test func acceptsPlainHostsAndPastedAddresses() {
    #expect(TVRouterWake.normalizedHost(" Fritz.Box ") == "fritz.box")
    #expect(TVRouterWake.normalizedHost("http://192.168.178.1/") == "192.168.178.1")
    #expect(TVRouterWake.normalizedHost("") == nil)
    #expect(TVRouterWake.normalizedHost("fritz.box/path") == nil)
    #expect(TVRouterWake.normalizedHost("fritz box") == nil)
    #expect(TVRouterWake.normalizedHost("evil.box@other") == nil)
  }

  @Test func wakeRequestTargetsTheHostsServiceWithTheCard() async throws {
    let transport = ScriptedTransport([.success((200, ""))])
    let failure = await TVRouterWake.wake(cards: [card], account: account, transport: transport)
    #expect(failure == nil)
    let (request, user, password) = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "http://fritz.box:49000/upnp/control/hosts")
    #expect(request.httpMethod == "POST")
    #expect(
      request.value(forHTTPHeaderField: "SOAPAction")
        == "urn:dslforum-org:service:Hosts:1#X_AVM-DE_WakeOnLANByMACAddress")
    let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(body.contains("<NewMACAddress>02:00:5E:10:00:01</NewMACAddress>"))
    #expect(body.contains("<u:X_AVM-DE_WakeOnLANByMACAddress xmlns:u=\"urn:dslforum-org:service:Hosts:1\">"))
    #expect(user == "synthetic-user" && password == "synthetic-secret")
    // The password goes only to the digest answer, never into the request itself.
    #expect(!body.contains("synthetic-secret"))
    #expect(request.allHTTPHeaderFields?.values.contains { $0.contains("synthetic-secret") } != true)
  }

  @Test func mapsRouterAnswersToClearFailures() async {
    let cases: [(Result<(Int, String), URLError>, TVRouterWake.Failure)] = [
      (.success((401, "")), .wrongCredentials),
      (.success((500, Self.fault(606))), .notPermitted),
      (.success((500, Self.fault(714))), .unknownDevice),
      (.success((500, Self.fault(820))), .unexpected(820)),
      (.success((503, "")), .unexpected(503)),
      (.failure(URLError(.timedOut)), .unreachable),
    ]
    for (answer, expected) in cases {
      let failure = await TVRouterWake.wake(
        cards: [card], account: account, transport: ScriptedTransport([answer]))
      #expect(failure == expected)
    }
  }

  @Test func triesTheNextCardOnlyWhenTheFirstIsUnknown() async {
    let second: [UInt8] = [0x02, 0x00, 0x5e, 0x10, 0x00, 0x02]
    let unknownThenAccepted = ScriptedTransport([
      .success((500, Self.fault(714))), .success((200, "")),
    ])
    #expect(
      await TVRouterWake.wake(
        cards: [card, second], account: account, transport: unknownThenAccepted) == nil)
    #expect(unknownThenAccepted.requests.count == 2)

    let wrongPassword = ScriptedTransport([.success((401, ""))])
    #expect(
      await TVRouterWake.wake(cards: [card, second], account: account, transport: wrongPassword)
        == .wrongCredentials)
    #expect(wrongPassword.requests.count == 1)
  }

  @Test func checkUsesAHarmlessQuery() async throws {
    let transport = ScriptedTransport([.success((200, ""))])
    #expect(await TVRouterWake.check(account: account, transport: transport) == nil)
    let request = try #require(transport.requests.first?.0)
    #expect(
      request.value(forHTTPHeaderField: "SOAPAction")
        == "urn:dslforum-org:service:Hosts:1#GetHostNumberOfEntries")
  }

  @Test func escapesValuesInTheEnvelope() {
    let body = TVRouterWake.envelope(action: "Probe", arguments: [("Value", "<a&'\">")])
    #expect(body.contains("<Value>&lt;a&amp;&apos;&quot;&gt;</Value>"))
  }

  @Test func invalidAddressSendsNothing() async {
    let transport = ScriptedTransport([])
    var broken = account
    broken.host = "not a host"
    #expect(
      await TVRouterWake.wake(cards: [card], account: broken, transport: transport)
        == .invalidAddress)
    #expect(transport.requests.isEmpty)
  }

  @Test func memoryStoreKeepsAndForgetsTheSignIn() throws {
    let store = TVRouterWakeMemoryStore()
    #expect(store.load() == nil)
    try store.save(account)
    #expect(store.load() == account)
    store.delete()
    #expect(store.load() == nil)
  }
}
