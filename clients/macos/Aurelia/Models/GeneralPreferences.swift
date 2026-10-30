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
  /// The page that was open when Aurelia closed; Home the first time. This was the behavior
  /// before the setting existed and stays the default.
  case lastScreen
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
    case .lastScreen: "Where I Left Off"
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
}

/// What Settings › General changes in the library: rows, grids and poster size.
enum LibraryDisplayPreferences {
  static func posterSize(_ defaults: UserDefaults = .standard) -> PosterSizePreference {
    defaults.string(forKey: GeneralPreferenceKeys.posterSize).flatMap(PosterSizePreference.init)
      ?? .standard
  }

  /// The titles a Home row or library grid shows. Rows can leave out watched titles; both can
  /// leave out titles whose file or drive is unavailable.
  static func visible(
    _ items: [CatalogItemSummary], keepWatched: Bool, defaults: UserDefaults = .standard
  ) -> [CatalogItemSummary] {
    let hideOffline = defaults.bool(forKey: GeneralPreferenceKeys.hideOfflineTitles)
    let showWatched =
      defaults.object(forKey: GeneralPreferenceKeys.showWatchedInRows) as? Bool ?? true
    return items.filter { item in
      !(hideOffline && item.kind != .series && item.availability != .available)
        && (keepWatched || showWatched || item.watchState != .completed)
    }
  }

  static func reducesMotion(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: GeneralPreferenceKeys.reduceHeroMotion)
  }
}
