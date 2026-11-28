import Foundation

enum WishState: String, Codable, CaseIterable, Sendable {
  case open
  case fulfilled
  case declined
}

struct WishSupportPerson: Codable, Equatable, Identifiable, Sendable {
  let userId: UUID
  let name: String

  var id: UUID { userId }
}

struct WishFulfillmentSuggestion: Codable, Equatable, Identifiable, Sendable {
  let mediaId: UUID
  let title: String
  let year: Int?
  let kind: MediaKind

  var id: UUID { mediaId }
}

struct WishSummary: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let userId: UUID
  let userName: String
  let kind: MediaKind
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
  let state: WishState
  let resolvedByUserId: UUID?
  let resolvedByUserName: String?
  let resolutionNote: String?
  let fulfilledMediaItemId: UUID?
  let createdAt: String
  let resolvedAt: String?
  let seenByWisherAt: String?
  let canSupport: Bool
  let supportedByCaller: Bool
  let supporters: [WishSupportPerson]
  let suggestions: [WishFulfillmentSuggestion]

  var createdDate: Date? { ServerDate.parse(createdAt) }
  var resolvedDate: Date? { resolvedAt.flatMap(ServerDate.parse) }
}

struct WishListResponse: Codable, Equatable, Sendable {
  let wishes: [WishSummary]
  let openCount: Int
  let newlyFulfilledCount: Int
  let providerEnabled: Bool
}

struct WishSummaryResponse: Codable, Equatable, Sendable {
  let openCount: Int
  let newlyFulfilledCount: Int
}

struct WishSearchHit: Codable, Equatable, Identifiable, Sendable {
  let provider: String
  let providerMediaId: String
  let kind: MediaKind
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

struct WishSearchResponse: Codable, Equatable, Sendable {
  let results: [WishSearchHit]
  let providerEnabled: Bool
}

struct CreateWishRequest: Encodable, Sendable {
  let kind: MediaKind
  let title: String
  let year: Int?
  let provider: String?
  let providerMediaId: String?
  let overview: String?
  let posterPath: String?
  let note: String?
}

struct CreateWishResponse: Codable, Equatable, Sendable {
  let wish: WishSummary
  let mergedIntoExistingSupport: Bool
}

struct WishAlreadyInLibraryProblem: Codable, Equatable, Sendable {
  let code: String
  let message: String
  let mediaId: UUID
  let title: String
  let kind: MediaKind
}

enum CreateWishOutcome: Equatable, Sendable {
  case created(CreateWishResponse)
  case alreadyInLibrary(WishAlreadyInLibraryProblem)
}

struct SetWishSupportRequest: Encodable, Sendable {
  let supported: Bool
}

struct UpdateWishStateRequest: Encodable, Sendable {
  let state: WishState
  let resolutionNote: String?
  let fulfilledMediaItemId: UUID?
}

struct SleepTimerEndedResponse: Codable, Equatable, Sendable {
  let powerMode: String
  let afterSleepTimer: Bool
  let minutes: Int
}

struct WishNotificationEvent: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case newWishes
    case wishFulfilled
  }

  let kind: Kind
  let title: String
  let body: String
}

enum WishPresentation {
  static func isAdministrator(_ user: UserSummary?) -> Bool {
    user?.role.canManageLibraries == true
  }

  static func badgeCount(summary: WishSummaryResponse?, isAdmin: Bool) -> Int {
    guard let summary else { return 0 }
    let fulfilled = max(0, summary.newlyFulfilledCount)
    let open = max(0, summary.openCount)
    return isAdmin ? open + fulfilled : fulfilled
  }

  static func notificationEvent(
    previous: WishSummaryResponse?,
    current: WishSummaryResponse,
    isAdmin: Bool,
    latestWish: WishSummary? = nil
  ) -> WishNotificationEvent? {
    guard let previous else { return nil }
    if current.newlyFulfilledCount > previous.newlyFulfilledCount {
      let added = current.newlyFulfilledCount - previous.newlyFulfilledCount
      if added == 1, let wish = latestWish {
        return WishNotificationEvent(
          kind: .wishFulfilled,
          title: "Your wish is here",
          body: "\(wish.title) is now in the library.")
      }
      return WishNotificationEvent(
        kind: .wishFulfilled,
        title: "Your wish is here",
        body: added == 1
          ? "One of your wished titles is now in the library."
          : "\(added) of your wished titles are now in the library.")
    }
    if isAdmin && current.openCount > previous.openCount {
      let added = current.openCount - previous.openCount
      if added == 1, let wish = latestWish {
        return WishNotificationEvent(
          kind: .newWishes,
          title: "New wish: \(wish.title)",
          body: "From \(wish.userName).")
      }
      return WishNotificationEvent(
        kind: .newWishes,
        title: "New family wish",
        body: added == 1
          ? "Someone added a new wish to the list."
          : "\(added) new wishes were added to the list.")
    }
    return nil
  }

  static func kindLabel(_ kind: MediaKind) -> String {
    kind == .series ? "TV Series" : "Movie"
  }

  static func stateLabel(_ state: WishState) -> String {
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
    if let api = error as? APIClientError {
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
