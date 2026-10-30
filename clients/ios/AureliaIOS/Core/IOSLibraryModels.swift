import Foundation

public enum IOSNavigationSection: String, CaseIterable, Identifiable, Sendable {
  case home = "Home"
  case library = "Library"
  case search = "Search"
  case settings = "Settings"

  public var id: String { rawValue }

  public var systemImage: String {
    switch self {
    case .home: return "house.fill"
    case .library: return "play.rectangle.on.rectangle.fill"
    case .search: return "magnifyingglass"
    case .settings: return "gearshape.fill"
    }
  }
}

public enum IOSLibraryTab: String, CaseIterable, Identifiable, Sendable {
  case movies = "Movies"
  case shows = "TV Shows"
  case franchises = "Franchises"
  case collections = "Collections"

  public var id: String { rawValue }
}

public enum IOSSortOrder: String, CaseIterable, Identifiable, Sendable {
  case recentlyAdded = "Recently Added"
  case title = "Title"
  case releaseYear = "Release Year"
  case rating = "Rating"

  public var id: String { rawValue }
}

public enum IOSFilterWatched: String, CaseIterable, Identifiable, Sendable {
  case all = "All"
  case unwatched = "Unwatched"
  case watched = "Watched"

  public var id: String { rawValue }
}
