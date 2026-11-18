import Foundation

enum TVWishState: String, Codable, CaseIterable, Sendable {
  case open
  case fulfilled
  case declined
}

struct TVWishSupportPerson: Codable, Equatable, Identifiable, Sendable {
  let userId: UUID
  let name: String

  var id: UUID { userId }
}

struct TVWishFulfillmentSuggestion: Codable, Equatable, Identifiable, Sendable {
  let mediaId: UUID
  let title: String
  let year: Int?
  let kind: TVMediaKind

  var id: UUID { mediaId }
}

struct TVWishSummary: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let userId: UUID
  let userName: String
  let kind: TVMediaKind
  let provider: String?
  let providerMediaId: String?
  let title: String
  let year: Int?
  let overview: String?
  let posterPath: String?
  let posterUrl: String?
  let ageRating: String?
  let minimumAge: Int?
  let note: String?
  let state: TVWishState
  let resolvedByUserId: UUID?
  let resolvedByUserName: String?
  let resolutionNote: String?
  let fulfilledMediaItemId: UUID?
  let createdAt: String
  let resolvedAt: String?
  let seenByWisherAt: String?
  let canSupport: Bool
  let supportedByCaller: Bool
  let supporters: [TVWishSupportPerson]
  let suggestions: [TVWishFulfillmentSuggestion]

  var createdDate: Date? { TVServerDate.parse(createdAt) }
  var resolvedDate: Date? { resolvedAt.flatMap(TVServerDate.parse) }
}

struct TVWishListResponse: Codable, Equatable, Sendable {
  let wishes: [TVWishSummary]
  let openCount: Int
  let newlyFulfilledCount: Int
  let providerEnabled: Bool
}

struct TVWishSummaryResponse: Codable, Equatable, Sendable {
  let openCount: Int
  let newlyFulfilledCount: Int
}

struct TVWishSearchHit: Codable, Equatable, Identifiable, Sendable {
  let provider: String
  let providerMediaId: String
  let kind: TVMediaKind
  let title: String
  let year: Int?
  let overview: String?
  let posterPath: String?
  let posterUrl: String?
  let alreadyInLibrary: Bool
  let existingMediaId: UUID?
  let alreadyWished: Bool
  let existingWishId: UUID?
  let supportedByCaller: Bool

  var id: String { "\(provider):\(providerMediaId):\(kind.rawValue)" }
}

struct TVWishSearchResponse: Codable, Equatable, Sendable {
  let results: [TVWishSearchHit]
  let providerEnabled: Bool
}

struct TVCreateWishRequest: Encodable, Sendable {
  let kind: TVMediaKind
  let title: String
  let year: Int?
  let provider: String?
  let providerMediaId: String?
  let overview: String?
  let posterPath: String?
  let note: String?
}

struct TVCreateWishResponse: Codable, Equatable, Sendable {
  let wish: TVWishSummary
  let mergedIntoExistingSupport: Bool
}

struct TVWishAlreadyInLibraryProblem: Codable, Equatable, Sendable {
  let code: String
  let message: String
  let mediaId: UUID
  let title: String
  let kind: TVMediaKind
}

enum TVCreateWishOutcome: Equatable, Sendable {
  case created(TVCreateWishResponse)
  case alreadyInLibrary(TVWishAlreadyInLibraryProblem)
}

struct TVSetWishSupportRequest: Encodable, Sendable {
  let supported: Bool
}

struct TVUpdateWishStateRequest: Encodable, Sendable {
  let state: TVWishState
  let resolutionNote: String?
  let fulfilledMediaItemId: UUID?
}

struct TVSleepTimerEndedResponse: Codable, Equatable, Sendable {
  let powerMode: String
  let afterSleepTimer: Bool
  let minutes: Int
}

struct TVWishNotificationEvent: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case newWishes
    case wishFulfilled
  }

  let kind: Kind
  let title: String
  let body: String
}

enum TVWishPreferenceKeys {
  static let wishNotificationsEnabled = "aurelia.ios.wishes.notificationsEnabled"
  static let wishNotificationsPrompted = "aurelia.ios.wishes.notificationsPrompted"
}

enum TVWishPresentation {
  static let pageSize = 30

  static func isAdministrator(_ user: TVUser?) -> Bool {
    guard let role = user?.role.lowercased() else { return false }
    return role == "owner" || role == "admin"
  }

  static func badgeCount(summary: TVWishSummaryResponse?, isAdmin: Bool) -> Int {
    guard let summary else { return 0 }
    let fulfilled = max(0, summary.newlyFulfilledCount)
    let open = max(0, summary.openCount)
    return isAdmin ? open + fulfilled : fulfilled
  }

  static func notificationEvent(
    previous: TVWishSummaryResponse?,
    current: TVWishSummaryResponse,
    isAdmin: Bool,
    latestWish: TVWishSummary? = nil
  ) -> TVWishNotificationEvent? {
    guard let previous else { return nil }
    if current.newlyFulfilledCount > previous.newlyFulfilledCount {
      let added = current.newlyFulfilledCount - previous.newlyFulfilledCount
      if added == 1, let wish = latestWish {
        return TVWishNotificationEvent(
          kind: .wishFulfilled,
          title: "Your wish is here",
          body: "\(wish.title) is now in the library.")
      }
      return TVWishNotificationEvent(
        kind: .wishFulfilled,
        title: "Your wish is here",
        body: added == 1
          ? "One of your wished titles is now in the library."
          : "\(added) of your wished titles are now in the library.")
    }
    if isAdmin && current.openCount > previous.openCount {
      let added = current.openCount - previous.openCount
      if added == 1, let wish = latestWish {
        return TVWishNotificationEvent(
          kind: .newWishes,
          title: "New wish: \(wish.title)",
          body: "From \(wish.userName).")
      }
      return TVWishNotificationEvent(
        kind: .newWishes,
        title: "New family wish",
        body: added == 1
          ? "Someone added a new wish to the list."
          : "\(added) new wishes were added to the list.")
    }
    return nil
  }

  static func kindLabel(_ kind: TVMediaKind) -> String {
    kind == .series ? "TV Series" : "Movie"
  }

  /// "Movie · 2021 · FSK 12", one text so the dots sit evenly between the parts.
  static func metaLine(_ wish: TVWishSummary) -> String {
    ([kindLabel(wish.kind)]
      + [wish.year.map(String.init), wish.ageRating].compactMap { $0 }
      .filter { !$0.isEmpty }).joined(separator: " · ")
  }

  static func stateLabel(_ state: TVWishState) -> String {
    switch state {
    case .open: "Waiting"
    case .fulfilled: "In Library"
    case .declined: "Declined"
    }
  }

  static func parseYear(_ input: String) -> (year: Int?, error: String?) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return (nil, nil) }
    guard trimmed.count == 4, trimmed.allSatisfy(\.isNumber), let value = Int(trimmed),
      (1888...2100).contains(value)
    else {
      return (nil, "Enter a four-digit year between 1888 and 2100, or leave it blank.")
    }
    return (value, nil)
  }

  static func describeError(_ error: Error) -> String {
    if let api = error as? TVCoreError {
      if api.problemCode == "wish_age_restricted" {
        return api.errorDescription ?? "This profile cannot wish for titles above its age limit."
      }
      if api.problemCode == "provider_disabled" {
        return "TMDB search is off on the server. Add your wish manually."
      }
      return api.errorDescription ?? "Couldn't update wishes. Try again."
    }
    if (error as? URLError) != nil {
      return "The server isn't answering."
    }
    return error.localizedDescription
  }
}

extension TVScreenTimeText {
  static func goodNight(sleepTimerStatus: TVSleepTimerEndedResponse?, name: String) -> (
    title: String, text: String
  ) {
    let who = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = who.isEmpty ? "Good night" : "Good night, \(who)"
    guard let status = sleepTimerStatus, status.afterSleepTimer else {
      return (title, "")
    }
    let minutes = max(0, status.minutes)
    let text: String
    switch status.powerMode.lowercased() {
    case "sleep":
      text =
        minutes > 0
        ? "The server goes to sleep in about \(minutes) minute\(minutes == 1 ? "" : "s")."
        : "The server goes to sleep soon."
    case "shutdown":
      text =
        minutes > 0
        ? "The server turns off in about \(minutes) minute\(minutes == 1 ? "" : "s")."
        : "The server turns off soon."
    default:
      text = ""
    }
    return (title, text)
  }
}

/// Wish or Me Too for a title the library doesn't have, from Known For or the wish search.
enum TVWishActions {
  enum Outcome: Equatable, Sendable {
    case wished(UUID?)
    /// The title is in the library already; the server says where.
    case inLibrary(String)
  }

  static func wish(_ hit: TVWishSearchHit, client: TVAPIClient) async throws -> Outcome {
    if hit.alreadyWished, let existing = hit.existingWishId {
      _ = try await client.setWishSupport(id: existing, supported: true)
      return .wished(existing)
    }
    switch try await client.createWish(
      TVCreateWishRequest(
        kind: hit.kind, title: hit.title, year: hit.year, provider: hit.provider,
        providerMediaId: hit.providerMediaId, overview: hit.overview, posterPath: hit.posterPath,
        note: nil))
    {
    case .created(let created): return .wished(created.wish.id)
    case .alreadyInLibrary(let problem): return .inLibrary(problem.message)
    }
  }

  /// "Wish", "Me Too" or "Wished" for a Known For card.
  static func label(_ hit: TVWishSearchHit) -> String {
    if hit.alreadyWished && hit.supportedByCaller { return "Wished" }
    return hit.alreadyWished ? "Me Too" : "Wish"
  }
}
