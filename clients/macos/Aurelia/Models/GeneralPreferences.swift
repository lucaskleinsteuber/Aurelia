import Foundation

enum PosterSizePreference: String, CaseIterable, Identifiable, Sendable {
  case compact
  case standard
  case large

  var id: String { rawValue }

  var label: String {
    switch self {
    case .compact: "Compact"
    case .standard: "Standard"
    case .large: "Large"
    }
  }

  var width: CGFloat {
    switch self {
    case .compact: 140
    case .standard: 180
    case .large: 220
    }
  }
}

enum StartScreenPreference: String, CaseIterable, Identifiable, Sendable {
  case movies
  case series
  case continueWatching
  case watchlist
  case recentlyAdded

  var id: String { rawValue }

  var label: String {
    switch self {
    case .movies: "Movies"
    case .series: "TV Shows"
    case .continueWatching: "Continue Watching"
    case .watchlist: "Watchlist"
    case .recentlyAdded: "Recently Added"
    }
  }
}

enum SubtitleSizePreference: String, CaseIterable, Identifiable, Sendable {
  case small
  case medium
  case large

  var id: String { rawValue }

  var label: String {
    switch self {
    case .small: "Small"
    case .medium: "Medium"
    case .large: "Large"
    }
  }

  var pointSize: CGFloat {
    switch self {
    case .small: 18
    case .medium: 24
    case .large: 32
    }
  }
}

enum SubtitleBackgroundPreference: String, CaseIterable, Identifiable, Sendable {
  case transparent
  case semiTransparent
  case solid

  var id: String { rawValue }

  var label: String {
    switch self {
    case .transparent: "Transparent"
    case .semiTransparent: "Semi-Transparent"
    case .solid: "Solid Black"
    }
  }
}

enum LibraryRescanInterval: String, CaseIterable, Identifiable, Sendable {
  case manual = "manual"
  case fifteenMinutes = "15m"
  case oneHour = "1h"
  case sixHours = "6h"
  case oneDay = "24h"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .manual: "Manual Only"
    case .fifteenMinutes: "Every 15 Minutes"
    case .oneHour: "Every Hour"
    case .sixHours: "Every 6 Hours"
    case .oneDay: "Every 24 Hours"
    }
  }
}

enum GeneralPreferenceKeys {
  static let defaultStartScreen = "AureliaDefaultStartScreen"
  static let posterSize = "AureliaPosterSize"
  static let showWatchedInRows = "AureliaShowWatchedInRows"
  static let reduceHeroMotion = "AureliaReduceHeroMotion"
  static let showMoviesInSidebar = "AureliaShowMoviesInSidebar"
  static let showSeriesInSidebar = "AureliaShowSeriesInSidebar"
  static let showWatchlistInSidebar = "AureliaShowWatchlistInSidebar"
  static let showCollectionsInSidebar = "AureliaShowCollectionsInSidebar"
  static let hideOfflineTitles = "AureliaHideOfflineTitles"
  static let rescanInterval = "AureliaRescanInterval"
}
