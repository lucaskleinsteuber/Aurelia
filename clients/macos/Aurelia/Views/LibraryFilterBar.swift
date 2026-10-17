import SwiftUI

/// Visible, one-click filters instead of nested menus: chips toggle directly, and the longer
/// choices (genre, year, sort order) open a small popover that stays put while the list updates.
struct LibraryFilterBar: View {
  let section: CatalogBrowseSection
  @Binding var query: CatalogBrowseQuery
  let genres: [String]
  let years: [Int]
  let isSearching: Bool
  let supportsWatchState: Bool
  @State private var showingGenres = false
  @State private var showingYears = false

  private var hasFilters: Bool { section.hasUserFilters(query) }

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        if section == .library {
          FilterChip(title: "All", selected: query.kind == nil) { query.kind = nil }
            .accessibilityIdentifier("library-filter-kind-all")
          FilterChip(title: "Movies", selected: query.kind == .movie) {
            query.kind = query.kind == .movie ? nil : .movie
          }
          .accessibilityIdentifier("library-filter-kind-movies")
          FilterChip(title: "TV Shows", selected: query.kind == .series) {
            query.kind = query.kind == .series ? nil : .series
          }
          .accessibilityIdentifier("library-filter-kind-shows")
          divider
        }
        FilterChip(title: "Favorites", symbol: "star.fill", selected: query.favoritesOnly) {
          query.favoritesOnly.toggle()
        }
        .accessibilityIdentifier("library-filter-favorites")
        if supportsWatchState {
          ForEach(CatalogWatchFilter.allCases.filter { $0 != .all }, id: \.self) { state in
            FilterChip(title: state.title, selected: query.watchState == state) {
              query.watchState = query.watchState == state ? .all : state
            }
            .accessibilityIdentifier("library-filter-watch-\(state.rawValue)")
          }
        }
        divider
        FilterChip(
          title: query.genre ?? "Genre", selected: query.genre != nil, opensPopover: true
        ) { showingGenres = true }
        .popover(isPresented: $showingGenres, arrowEdge: .bottom) { genrePopover }
        .disabled(genres.isEmpty)
        .accessibilityIdentifier("library-filter-genre")
        FilterChip(title: yearTitle, selected: yearSelected, opensPopover: true) {
          showingYears = true
        }
        .popover(isPresented: $showingYears, arrowEdge: .bottom) { yearPopover }
        .disabled(years.isEmpty)
        .accessibilityIdentifier("library-filter-year")
        if hasFilters {
          Button("Clear") { query.clearFilters(preserving: section.fixedKind) }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .transition(.opacity)
            .accessibilityLabel("Clear Filters")
            .accessibilityIdentifier("library-clear-filters")
        }
      }
      .padding(.vertical, 2)
      .animation(.smooth(duration: 0.2), value: hasFilters)
    }
    .scrollIndicators(.never)
    .scrollClipDisabled()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-filters")
  }

  private var divider: some View {
    Rectangle().fill(AureliaDesign.hairline).frame(width: 1, height: 18).padding(.horizontal, 2)
  }

  private var yearSelected: Bool { query.yearFrom != nil || query.yearTo != nil }

  private var yearTitle: String {
    switch (query.yearFrom, query.yearTo) {
    case (let from?, let to?): from == to ? String(from) : "\(from)–\(to)"
    case (let from?, nil): "From \(from)"
    case (nil, let to?): "Through \(to)"
    default: "Year"
    }
  }

  private var genrePopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Genre").font(.headline)
      ScrollView {
        FlowLayout(spacing: 8) {
          FilterChip(title: "All Genres", selected: query.genre == nil) {
            query.genre = nil
            showingGenres = false
          }
          ForEach(genres, id: \.self) { genre in
            FilterChip(title: genre, selected: query.genre == genre) {
              query.genre = query.genre == genre ? nil : genre
              showingGenres = false
            }
            .accessibilityIdentifier("library-genre-\(genre)")
          }
        }
        .padding(2)
      }
      .frame(maxHeight: 320)
    }
    .padding(18)
    .frame(width: 380)
  }

  private var yearPopover: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Release Year").font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("From").foregroundStyle(.secondary)
          Picker("From", selection: fromYear) {
            Text("Any Year").tag(Optional<Int>.none)
            ForEach(years, id: \.self) { Text(String($0)).tag(Optional($0)) }
          }
          .labelsHidden()
          .accessibilityIdentifier("library-year-from")
        }
        GridRow {
          Text("To").foregroundStyle(.secondary)
          Picker("To", selection: toYear) {
            Text("Any Year").tag(Optional<Int>.none)
            ForEach(years, id: \.self) { Text(String($0)).tag(Optional($0)) }
          }
          .labelsHidden()
          .accessibilityIdentifier("library-year-to")
        }
      }
      if yearSelected {
        Button("Any Year") {
          query.yearFrom = nil
          query.yearTo = nil
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
      }
    }
    .padding(18)
    .frame(width: 260)
  }

  private var fromYear: Binding<Int?> {
    Binding(
      get: { query.yearFrom },
      set: { value in
        query.yearFrom = value
        if let value, let to = query.yearTo, value > to { query.yearTo = value }
      })
  }

  private var toYear: Binding<Int?> {
    Binding(
      get: { query.yearTo },
      set: { value in
        query.yearTo = value
        if let value, let from = query.yearFrom, value < from { query.yearFrom = value }
      })
  }
}

/// The sort control next to the search field; it opens a short list of orders.
struct LibrarySortButton: View {
  @Binding var query: CatalogBrowseQuery
  let isSearching: Bool
  @State private var showingSort = false

  var body: some View {
    FilterChip(
      title: sortTitle, symbol: "arrow.up.arrow.down", selected: false, opensPopover: true,
      height: 38
    ) { showingSort = true }
    .popover(isPresented: $showingSort, arrowEdge: .bottom) { sortPopover }
    .accessibilityLabel("Sort: \(sortTitle)")
    .accessibilityIdentifier("library-sort")
  }

  private var sortTitle: String {
    query.sort?.title ?? (isSearching ? "Relevance" : "Default")
  }

  private var sortPopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Sort By").font(.headline).padding(.bottom, 6)
      sortRow(isSearching ? "Relevance" : "Default", selected: query.sort == nil) {
        query.sort = nil
      }
      ForEach(CatalogBrowseSort.allCases, id: \.self) { sort in
        sortRow(sort.title, selected: query.sort == sort) { query.sort = sort }
      }
      Divider().padding(.vertical, 6)
      sortRow("Ascending", selected: query.sort != nil && !query.descending) {
        query.descending = false
      }
      .disabled(query.sort == nil)
      sortRow("Descending", selected: query.sort != nil && query.descending) {
        query.descending = true
      }
      .disabled(query.sort == nil)
    }
    .padding(14)
    .frame(width: 220)
  }

  private func sortRow(_ title: String, selected: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        if selected { Image(systemName: "checkmark").font(.callout.weight(.semibold)) }
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(PopoverRowButtonStyle())
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// A capsule toggle: white with dark text when selected, as in Apple's TV and Music apps.
struct FilterChip: View {
  let title: String
  var symbol: String?
  let selected: Bool
  var opensPopover = false
  var height: CGFloat = 32
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
        Text(title).lineLimit(1)
        if opensPopover {
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            .opacity(0.7)
        }
      }
      .font(.callout.weight(.medium))
      .foregroundStyle(selected ? Color.black : Color.primary)
      .padding(.horizontal, 14)
      .frame(height: height)
      .background {
        Capsule().fill(
          selected
            ? AnyShapeStyle(Color.white.opacity(0.94))
            : AnyShapeStyle(Color.white.opacity(hovering ? 0.14 : 0.08)))
      }
      .overlay {
        Capsule().strokeBorder(selected ? .clear : AureliaDesign.hairline, lineWidth: 1)
      }
      .contentShape(Capsule())
      .opacity(isEnabled ? 1 : 0.45)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.smooth(duration: 0.18), value: selected)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct PopoverRowButtonStyle: ButtonStyle {
  @State private var hovering = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(
            Color.accentColor.opacity(
              configuration.isPressed ? 0.5 : (hovering && isEnabled ? 0.3 : 0)))
      )
      .onHover { hovering = $0 }
  }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if needed > width, !current.indices.isEmpty {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
