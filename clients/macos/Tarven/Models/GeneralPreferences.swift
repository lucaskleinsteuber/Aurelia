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
  /// The page that was open when Tarven closed; Home the first time. This was the behavior
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
    .people,
    .wishes,
    .recentlyAdded,
    .tvShows,
    .movies,
    .history,
    .statistics,
    .downloads,
  ]

  private static let legacyVisibilityKeys: [(key: String, destination: LibraryDestination)] = [
    ("TarvenShowMoviesInSidebar", .movies),
    ("TarvenShowSeriesInSidebar", .tvShows),
    ("TarvenShowWatchlistInSidebar", .watchlist),
    ("TarvenShowCollectionsInSidebar", .collections),
  ]

  static func loadOrder(defaults: UserDefaults = .standard) -> [LibraryDestination] {
    migrateLegacyVisibilityIfNeeded(defaults: defaults)
    guard let saved = defaults.string(forKey: GeneralPreferenceKeys.sidebarItemOrder)
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

  static func saveOrder(_ order: [LibraryDestination], defaults: UserDefaults = .standard) {
    let raw = order.map(\.rawValue).joined(separator: ",")
    defaults.set(raw, forKey: GeneralPreferenceKeys.sidebarItemOrder)
    bumpRevision(defaults: defaults)
  }

  /// History and Statistics live in Settings › Activity; they join the sidebar only when
  /// someone turns them on in the sidebar settings.
  static let hiddenByDefault: Set<LibraryDestination> = [.history, .statistics]

  /// Migrates the pre-modular sidebar visibility switches once so hidden sections stay hidden.
  static func migrateLegacyVisibilityIfNeeded(defaults: UserDefaults = .standard) {
    var migrated = false
    for entry in legacyVisibilityKeys {
      guard defaults.object(forKey: entry.key) != nil else { continue }
      let modernKey = "TarvenSidebarShow_\(entry.destination.rawValue)"
      if defaults.object(forKey: modernKey) == nil {
        defaults.set(defaults.bool(forKey: entry.key), forKey: modernKey)
      }
      defaults.removeObject(forKey: entry.key)
      migrated = true
    }
    if migrated {
      bumpRevision(defaults: defaults)
    }
  }

  static func isVisible(_ destination: LibraryDestination, defaults: UserDefaults = .standard)
    -> Bool
  {
    migrateLegacyVisibilityIfNeeded(defaults: defaults)
    let key = "TarvenSidebarShow_\(destination.rawValue)"
    if defaults.object(forKey: key) == nil {
      return !hiddenByDefault.contains(destination)
    }
    return defaults.bool(forKey: key)
  }

  static func setVisible(
    _ destination: LibraryDestination, isVisible: Bool, defaults: UserDefaults = .standard
  ) {
    migrateLegacyVisibilityIfNeeded(defaults: defaults)
    let key = "TarvenSidebarShow_\(destination.rawValue)"
    defaults.set(isVisible, forKey: key)
    bumpRevision(defaults: defaults)
  }

  static func resetToDefaults(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: GeneralPreferenceKeys.sidebarItemOrder)
    for dest in defaultOrder {
      defaults.removeObject(forKey: "TarvenSidebarShow_\(dest.rawValue)")
    }
    for entry in legacyVisibilityKeys {
      defaults.removeObject(forKey: entry.key)
    }
    bumpRevision(defaults: defaults)
  }

  private static func bumpRevision(defaults: UserDefaults = .standard) {
    let current = defaults.integer(
      forKey: GeneralPreferenceKeys.sidebarVisibilityRevision)
    defaults.set(current + 1, forKey: GeneralPreferenceKeys.sidebarVisibilityRevision)
  }
}

enum GeneralPreferenceKeys {
  static let defaultStartScreen = "TarvenDefaultStartScreen"
  static let sidebarItemOrder = "TarvenSidebarItemOrder"
  static let sidebarVisibilityRevision = "TarvenSidebarVisibilityRevision"
  static let sidebarWidth = "TarvenSidebarWidth"
  static let posterSize = "TarvenPosterSize"
  static let showWatchedInRows = "TarvenShowWatchedInRows"
  static let reduceHeroMotion = "TarvenReduceHeroMotion"
  static let hideOfflineTitles = "TarvenHideOfflineTitles"
  static let wishNotificationsEnabled = "TarvenWishNotificationsEnabled"
  static let wishNotificationsPrompted = "TarvenWishNotificationsPrompted"
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
