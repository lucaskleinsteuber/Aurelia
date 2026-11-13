import Foundation

enum IOSWishState: String, Codable, CaseIterable, Sendable {
  case open
  case fulfilled
  case declined
}

struct IOSWishSupportPerson: Codable, Equatable, Identifiable, Sendable {
  let userId: UUID
  let name: String

  var id: UUID { userId }
}

struct IOSWishFulfillmentSuggestion: Codable, Equatable, Identifiable, Sendable {
  let mediaId: UUID
  let title: String
  let year: Int?
  let kind: IOSMediaKind

  var id: UUID { mediaId }
}

struct IOSWishSummary: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let userId: UUID
  let userName: String
  let kind: IOSMediaKind
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
  let state: IOSWishState
  let resolvedByUserId: UUID?
  let resolvedByUserName: String?
  let resolutionNote: String?
  let fulfilledMediaItemId: UUID?
  let createdAt: String
  let resolvedAt: String?
  let seenByWisherAt: String?
  let canSupport: Bool
  let supportedByCaller: Bool
  let supporters: [IOSWishSupportPerson]
  let suggestions: [IOSWishFulfillmentSuggestion]

  var createdDate: Date? { IOSServerDate.parse(createdAt) }
  var resolvedDate: Date? { resolvedAt.flatMap(IOSServerDate.parse) }
}

struct IOSWishListResponse: Codable, Equatable, Sendable {
  let wishes: [IOSWishSummary]
  let openCount: Int
  let newlyFulfilledCount: Int
  let providerEnabled: Bool
}

struct IOSWishSummaryResponse: Codable, Equatable, Sendable {
  let openCount: Int
  let newlyFulfilledCount: Int
}

struct IOSWishSearchHit: Codable, Equatable, Identifiable, Sendable {
  let provider: String
  let providerMediaId: String
  let kind: IOSMediaKind
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

struct IOSWishSearchResponse: Codable, Equatable, Sendable {
  let results: [IOSWishSearchHit]
  let providerEnabled: Bool
}

struct IOSCreateWishRequest: Encodable, Sendable {
  let kind: IOSMediaKind
  let title: String
  let year: Int?
  let provider: String?
  let providerMediaId: String?
  let overview: String?
  let posterPath: String?
  let note: String?
}

struct IOSCreateWishResponse: Codable, Equatable, Sendable {
  let wish: IOSWishSummary
  let mergedIntoExistingSupport: Bool
}

struct IOSWishAlreadyInLibraryProblem: Codable, Equatable, Sendable {
  let code: String
  let message: String
  let mediaId: UUID
  let title: String
  let kind: IOSMediaKind
}

enum IOSCreateWishOutcome: Equatable, Sendable {
  case created(IOSCreateWishResponse)
  case alreadyInLibrary(IOSWishAlreadyInLibraryProblem)
}

struct IOSSetWishSupportRequest: Encodable, Sendable {
  let supported: Bool
}

struct IOSUpdateWishStateRequest: Encodable, Sendable {
  let state: IOSWishState
  let resolutionNote: String?
  let fulfilledMediaItemId: UUID?
}

struct IOSSleepTimerEndedResponse: Codable, Equatable, Sendable {
  let powerMode: String
  let afterSleepTimer: Bool
  let minutes: Int
}

struct IOSWishNotificationEvent: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case newWishes
    case wishFulfilled
  }

  let kind: Kind
  let title: String
  let body: String
}

enum IOSWishPreferenceKeys {
  static let wishNotificationsEnabled = "aurelia.ios.wishes.notificationsEnabled"
  static let wishNotificationsPrompted = "aurelia.ios.wishes.notificationsPrompted"
}

enum IOSWishPresentation {
  static let pageSize = 30

  static func isAdministrator(_ user: IOSUser?) -> Bool {
    guard let role = user?.role.lowercased() else { return false }
    return role == "owner" || role == "admin"
  }

  static func badgeCount(summary: IOSWishSummaryResponse?, isAdmin: Bool) -> Int {
    guard let summary else { return 0 }
    let fulfilled = max(0, summary.newlyFulfilledCount)
    let open = max(0, summary.openCount)
    return isAdmin ? open + fulfilled : fulfilled
  }

  static func notificationEvent(
    previous: IOSWishSummaryResponse?,
    current: IOSWishSummaryResponse,
    isAdmin: Bool,
    latestWish: IOSWishSummary? = nil
  ) -> IOSWishNotificationEvent? {
    guard let previous else { return nil }
    if current.newlyFulfilledCount > previous.newlyFulfilledCount {
      let added = current.newlyFulfilledCount - previous.newlyFulfilledCount
      if added == 1, let wish = latestWish {
        return IOSWishNotificationEvent(
          kind: .wishFulfilled,
          title: "Your wish is here",
          body: "\(wish.title) is now in the library.")
      }
      return IOSWishNotificationEvent(
        kind: .wishFulfilled,
        title: "Your wish is here",
        body: added == 1
          ? "One of your wished titles is now in the library."
          : "\(added) of your wished titles are now in the library.")
    }
    if isAdmin && current.openCount > previous.openCount {
      let added = current.openCount - previous.openCount
      if added == 1, let wish = latestWish {
        return IOSWishNotificationEvent(
          kind: .newWishes,
          title: "New wish: \(wish.title)",
          body: "From \(wish.userName).")
      }
      return IOSWishNotificationEvent(
        kind: .newWishes,
        title: "New family wish",
        body: added == 1
          ? "Someone added a new wish to the list."
          : "\(added) new wishes were added to the list.")
    }
    return nil
  }

  static func kindLabel(_ kind: IOSMediaKind) -> String {
    kind == .series ? "TV Series" : "Movie"
  }

  static func stateLabel(_ state: IOSWishState) -> String {
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
    if let api = error as? IOSCoreError {
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

extension IOSScreenTimeText {
  static func goodNight(sleepTimerStatus: IOSSleepTimerEndedResponse?, name: String) -> (
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
