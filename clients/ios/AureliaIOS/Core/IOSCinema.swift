import Foundation

/// Aurelia's made-up cinema ads, copied from the Mac app. Nothing is sold; they are a joke before
/// the film.
enum IOSCinemaAd: String, CaseIterable, Sendable {
  case iceCream, popcorn, phones

  /// The ads are timed as 15-second scripts and played slower, so there is time to read them.
  static let pace = 1.4
  /// Every ad runs this long, in seconds.
  static let duration: Double = 15 * pace
}

/// A trailer in the library and the film it belongs to ("cinema-trailers-v1").
struct IOSCinemaTrailer: Codable, Equatable, Sendable {
  let trailer: IOSCatalogItem
  let title: IOSCatalogItem
}

struct IOSCinemaTrailersResponse: Codable, Sendable {
  let trailers: [IOSCinemaTrailer]
}

/// One part of cinema mode's pre-show, in the order of a cinema: ad, trailers, then the curtain.
enum IOSCinemaAct: Equatable, Sendable {
  case ad(IOSCinemaAd)
  case trailer(IOSCinemaTrailer)
  /// "Feature Presentation": the curtain opens for the film.
  case feature(title: String)
}

enum IOSCinemaPlan {
  static let feature = "cinema-trailers-v1"
  /// The title stands on the closed curtain at least this long while the film starts behind it.
  static let curtainEarliestOpening: Double = 3.3
  /// A film that hasn't started by then gets the curtain opened anyway.
  static let curtainLongestWait: Double = 10
  /// From the curtain starting to open until the film is all there is.
  static let curtainOpeningSeconds: Double = 4
  /// A trailer whose picture hasn't moved by then is left out.
  static let trailerStartSeconds: Double = 15
  /// Even a long trailer ends here.
  static let trailerLongestSeconds: Double = 300
  static let lastAdKey = "AureliaCinemaLastAd"

  /// Whether a title may get a pre-show: a film (not an episode), cinema mode on with ads or
  /// trailers, a server that lists trailers, and no one watching along.
  static func wanted(
    preferences: IOSPlaybackPreferences, isEpisode: Bool, capabilities: [String],
    watchingTogether: Bool
  ) -> Bool {
    preferences.cinemaMode && (preferences.cinemaAds || preferences.cinemaTrailers > 0)
      && !isEpisode && !watchingTogether && capabilities.contains(feature)
  }

  /// Whether the film starts from its beginning; a film picked up in the middle gets no pre-show.
  static func startsAtBeginning(
    startOver: Bool, progress: IOSPlaybackProgress?, automaticResume: Bool
  ) -> Bool {
    guard !startOver, automaticResume, let progress, !progress.isCompleted else { return true }
    return progress.positionMilliseconds <= 0
  }

  /// The ad, the trailers that aren't for the film itself, then the curtain.
  static func acts(ad: IOSCinemaAd?, trailers: [IOSCinemaTrailer], film: UUID, title: String)
    -> [IOSCinemaAct]
  {
    var acts = ad.map { [IOSCinemaAct.ad($0)] } ?? []
    acts += trailers.filter { $0.title.id != film && $0.trailer.parentId != film }
      .map(IOSCinemaAct.trailer)
    if !acts.isEmpty { acts.append(.feature(title: title)) }
    return acts
  }

  /// The ads take turns, so the same one never runs twice in a row.
  static func ad(after last: String?) -> IOSCinemaAd {
    let all = IOSCinemaAd.allCases
    guard let index = all.firstIndex(where: { $0.rawValue == last }) else { return all[0] }
    return all[(index + 1) % all.count]
  }
}
