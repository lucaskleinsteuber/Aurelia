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
  case home
  case library
  case movies
  case series
  case continueWatching
  case collections
  case watchlist
  case recentlyAdded

  var id: String { rawValue }

  var label: String {
    switch self {
    case .home: "Home"
    case .library: "Library"
    case .movies: "Movies"
    case .series: "TV Shows"
    case .continueWatching: "Continue Watching"
    case .collections: "Collections"
    case .watchlist: "Watchlist"
    case .recentlyAdded: "Recently Added"
    }
  }
}

enum SidebarPreferences {
  static let defaultOrder: [LibraryDestination] = [
    .home,
    .library,
    .collections,
    .watchlist,
    .recentlyAdded,
    .tvShows,
    .movies,
    .history,
    .statistics,
  ]

  static func loadOrder() -> [LibraryDestination] {
    guard let saved = UserDefaults.standard.string(forKey: GeneralPreferenceKeys.sidebarItemOrder)
    else {
      return defaultOrder
    }
    let ids = saved.components(separatedBy: ",")
    var destinations: [LibraryDestination] = []
    for id in ids {
      if let dest = LibraryDestination(rawValue: id), !destinations.contains(dest) {
        destinations.append(dest)
      }
    }
    for dest in defaultOrder {
      if !destinations.contains(dest) {
        destinations.append(dest)
      }
    }
    return destinations
  }

  static func saveOrder(_ order: [LibraryDestination]) {
    let raw = order.map(\.rawValue).joined(separator: ",")
    UserDefaults.standard.set(raw, forKey: GeneralPreferenceKeys.sidebarItemOrder)
    bumpRevision()
  }

  static func isVisible(_ destination: LibraryDestination) -> Bool {
    let key = "AureliaSidebarShow_\(destination.rawValue)"
    if UserDefaults.standard.object(forKey: key) == nil {
      return true
    }
    return UserDefaults.standard.bool(forKey: key)
  }

  static func setVisible(_ destination: LibraryDestination, isVisible: Bool) {
    let key = "AureliaSidebarShow_\(destination.rawValue)"
    UserDefaults.standard.set(isVisible, forKey: key)
    bumpRevision()
  }

  static func resetToDefaults() {
    UserDefaults.standard.removeObject(forKey: GeneralPreferenceKeys.sidebarItemOrder)
    for dest in defaultOrder {
      UserDefaults.standard.removeObject(forKey: "AureliaSidebarShow_\(dest.rawValue)")
    }
    bumpRevision()
  }

  private static func bumpRevision() {
    let current = UserDefaults.standard.integer(
      forKey: GeneralPreferenceKeys.sidebarVisibilityRevision)
    UserDefaults.standard.set(current + 1, forKey: GeneralPreferenceKeys.sidebarVisibilityRevision)
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
  static let sidebarItemOrder = "AureliaSidebarItemOrder"
  static let sidebarVisibilityRevision = "AureliaSidebarVisibilityRevision"
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
