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

struct TVSleepTimerEndedResponse: Codable, Equatable, Sendable {
  let powerMode: String
  let afterSleepTimer: Bool
  let minutes: Int
}

enum TVWishPresentation {
  static let pageSize = 30

  static func kindLabel(_ kind: TVMediaKind) -> String {
    kind == .series ? "TV Series" : "Movie"
  }

  static func stateLabel(_ state: TVWishState) -> String {
    switch state {
    case .open: "Waiting"
    case .fulfilled: "In Library"
    case .declined: "Declined"
    }
  }

  static func describeError(_ error: Error) -> String {
    if let api = error as? TVCoreError {
      return api.errorDescription ?? "Couldn't load wishes. Try again."
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
