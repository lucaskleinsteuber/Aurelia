import SwiftUI

struct TVBrowseDestination: View {
  @StateObject private var listing: TVLibraryListing
  init(section: TVBrowseSection) {
    _listing = StateObject(wrappedValue: TVLibraryListing(section: section))
  }
  var body: some View { TVLibraryGrid(listing: listing, title: listing.section.title) }
}

private struct TVBrowseLoadKey: Equatable {
  let query: TVBrowseQuery
  let search: String
  let session: UUID?
  let revision: UUID
}

struct TVLibraryGrid: View {
  @EnvironmentObject private var model: TVAppModel
  @ObservedObject var listing: TVLibraryListing
  let title: String
  @State private var search = ""
  @State private var query = TVBrowseQuery()
  @State private var filters = false
  @State private var restoredScope: String?
  @State private var lastKey: TVBrowseLoadKey?
  @State private var scrollAnchor: UUID?
  @StateObject private var actions = TVLibraryActions()
  @FocusState private var focusedItem: UUID?
  private var querySummary: String {
    var labels = [query.summary]
    if listing.section.fixedKind == nil, let kind = query.kind {
      labels.insert(kind == .movie ? "Movies" : "TV Shows", at: 0)
    }
    if let sort = query.sort {
      labels.append("\(sort.title) · \(query.descending ? "Descending" : "Ascending")")
    }
    return labels.filter { !$0.isEmpty }.joined(separator: " · ")
  }
  private var key: TVBrowseLoadKey {
    TVBrowseLoadKey(
      query: query, search: search, session: model.session?.sessionId,
      revision: model.libraryRefresh)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 30) {
        HStack(spacing: 24) {
          HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.system(size: 56, weight: .bold))
            if !listing.items.isEmpty {
              Text("\(listing.total)").font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tertiary)
            }
          }
          Spacer()
          // Beside Filter & Sort in the header's focus section, so Left reaches it; below the
          // header no Up or Down press could land on it.
          if !querySummary.isEmpty {
            Button("Clear Filters") { query = listing.section.defaultQuery }
              .buttonStyle(TVButtonStyle()).accessibilityIdentifier("browse-clear")
          }
          Button {
            filters = true
          } label: {
            Label("Filter & Sort", systemImage: "line.3.horizontal.decrease")
          }
          .buttonStyle(TVButtonStyle()).accessibilityIdentifier("browse-filters")
        }
        // Its own section, so Up from any title reaches Filter & Sort even when no title sits
        // below it (a row with fewer than six titles, or a short search result).
        .focusSection()
        if listing.section == .search {
          TextField("Search Library", text: $search).submitLabel(.search)
            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
              "library-search")
        }
        if !querySummary.isEmpty {
          Text(querySummary).font(.system(size: 22)).foregroundStyle(.secondary)
        }
        if listing.items.isEmpty && !listing.loading && listing.error == nil {
          Text(search.isEmpty ? "No titles match this view." : "No matching titles.")
            .foregroundStyle(.secondary)
        }
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 6), spacing: 56
        ) {
          ForEach(listing.items) { original in
            let item = model.overlay(original)
            NavigationLink {
              TVDetailView(
                id: item.detailID, initial: item,
                selectedEpisodeID: listing.section == .search && item.kind == .episode
                  ? item.id : nil)
            } label: {
              TVPosterLabel(item: item)
            }
            .buttonStyle(.borderless).focused(
              $focusedItem, equals: item.id
            ).id(item.id).accessibilityIdentifier("catalog-\(item.id)")
            .contextMenu {
              TVMediaContextActions(
                item: item, actions: actions, continuation: listing.section == .continueWatching)
            }
            .onAppear { if original.id == listing.items.last?.id { loadNext() } }
          }
        }.scrollTargetLayout()
          // Coming from the tab bar or the header always starts at the first title.
          .defaultFocus($focusedItem, listing.items.first?.id, priority: .userInitiated)
          .focusSection()
        if listing.loading {
          ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("browse-loading")
        }
        if let error = listing.error {
          TVErrorText(message: error)
          Button("Try Again") { loadNext() }.buttonStyle(TVButtonStyle())
        }
      }.padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 40)
    }.scrollPosition(id: $scrollAnchor, anchor: .top).background(TVDesign.canvas.ignoresSafeArea())
      .onAppear { restore() }
      .task(id: key) {
        let request = key
        if let previous = lastKey, previous != request, previous.query == request.query,
          previous.search == request.search, previous.session == request.session
        {
          // Only the library revision changed: update the shown titles in place. Nobody asked
          // for it, so the reload doesn't count as using the server.
          lastKey = request
          if let api = model.client {
            await TVAPIClient.withBackgroundRequests {
              await listing.refresh(api: api, onFailure: model.handleSessionFailure)
            }
          }
          return
        }
        if lastKey != request {
          // Configuring an unchanged query keeps titles that Home already preloaded.
          listing.configure(query: query, search: search, profileID: model.session?.user.id)
          lastKey = request
          save()
          if !search.isEmpty {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          }
        }
        guard !Task.isCancelled, listing.items.isEmpty, let api = model.client else { return }
        await listing.loadNext(api: api, onFailure: model.handleSessionFailure)
      }
      .fullScreenCover(isPresented: $filters) {
        TVBrowseFilters(query: $query, section: listing.section)
      }
      .modifier(TVLibraryActionPresentation(actions: actions))
  }
  private func restore() {
    guard let connection = model.connection, let session = model.session else { return }
    let scope = "\(connection.serverID):\(session.user.id)"
    guard scope != restoredScope else { return }
    restoredScope = scope
    query = model.environment.browsePreferences.load(
      serverID: connection.serverID, profileID: session.user.id, section: listing.section)
    search = ""
  }
  private func save() {
    guard let connection = model.connection, let session = model.session else { return }
    model.environment.browsePreferences.save(
      query, serverID: connection.serverID, profileID: session.user.id, section: listing.section)
  }
  private func loadNext() {
    guard let api = model.client else { return }
    Task { await listing.loadNext(api: api, onFailure: model.handleSessionFailure) }
  }
}

/// Filter & Sort as a full page in the row style of Playback Settings. The system form in a
/// sheet drew the focused row unreadable on tvOS 26 and let rows slide under its title.
private struct TVBrowseFilters: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var query: TVBrowseQuery
  let section: TVBrowseSection
  var body: some View {
    HStack(alignment: .top, spacing: 90) {
      VStack(spacing: 26) {
        Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.system(size: 150))
          .symbolRenderingMode(.hierarchical).foregroundStyle(.white.opacity(0.85))
        Text("Filter & Sort").font(.system(size: 48, weight: .bold))
        Text("Select a row to change it. Menu or Done returns to the titles.")
          .font(.system(size: 24)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }.frame(width: 560).padding(.top, 140)
      ScrollView {
        VStack(spacing: 14) {
          if section.fixedKind == nil {
            row("Media", value: mediaTitle, id: "filter-media") {
              query.kind = Self.next(after: query.kind, in: [nil, .movie, .series])
            }
          }
          if section != .favorites {
            row(
              "Favorites Only", value: query.favoritesOnly ? "On" : "Off", id: "filter-favorites"
            ) { query.favoritesOnly.toggle() }
          }
          field(
            "Genre", prompt: "Any",
            text: Binding(
              get: { query.genre ?? "" }, set: { query.genre = $0.isEmpty ? nil : $0 }),
            id: "filter-genre", numbers: false)
          field("Year From", prompt: "Any", text: year(\.yearFrom), id: "filter-year-from")
          field("Year To", prompt: "Any", text: year(\.yearTo), id: "filter-year-to")
          if section != .continueWatching {
            row("Watch Status", value: query.watchState.title, id: "filter-watch-status") {
              query.watchState = Self.next(after: query.watchState, in: TVWatchFilter.allCases)
            }
          }
          Spacer().frame(height: 18)
          row("Sort", value: query.sort?.title ?? "Default", id: "filter-sort") {
            query.sort = Self.next(after: query.sort, in: [nil] + TVBrowseSort.allCases.map { $0 })
          }
          if query.sort != nil {
            row("Descending", value: query.descending ? "On" : "Off", id: "filter-descending") {
              query.descending.toggle()
            }
          }
          Spacer().frame(height: 18)
          row("Reset Filters & Sort", value: nil, id: "filter-reset") {
            query = section.defaultQuery
          }
          row("Done", value: nil, id: "filters-done") { dismiss() }
        }.padding(.vertical, 30).padding(.horizontal, 20)
      }.frame(maxWidth: .infinity).focusSection()
    }.padding(.horizontal, TVDesign.pagePadding).padding(.top, 20)
      .background(TVDesign.canvas.ignoresSafeArea())
      // However the page closes, the query keeps only what this section allows.
      .onDisappear { query = section.constrain(query) }
  }

  private var mediaTitle: String {
    switch query.kind {
    case .movie: "Movies"
    case .series: "TV Shows"
    default: "All"
    }
  }

  private func row(_ title: String, value: String?, id: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 20) {
        Text(title)
        Spacer(minLength: 20)
        if let value { Text(value).opacity(0.7).monospacedDigit() }
      }.padding(.horizontal, 30).frame(maxWidth: .infinity, minHeight: 72)
    }
    .buttonStyle(TVButtonStyle(kind: .row)).accessibilityIdentifier(id)
    .accessibilityValue(value ?? "")
  }

  private func field(
    _ title: String, prompt: String, text: Binding<String>, id: String, numbers: Bool = true
  ) -> some View {
    HStack(spacing: 20) {
      Text(title).frame(width: 220, alignment: .leading).padding(.leading, 30)
      TextField(prompt, text: text).keyboardType(numbers ? .numberPad : .default)
        .accessibilityLabel(title).accessibilityIdentifier(id)
    }.frame(maxWidth: .infinity, minHeight: 72)
  }

  private static func next<Value: Equatable>(after current: Value, in values: [Value]) -> Value {
    guard let index = values.firstIndex(of: current) else { return values[0] }
    return values[(index + 1) % values.count]
  }

  private func year(_ path: WritableKeyPath<TVBrowseQuery, Int?>) -> Binding<String> {
    Binding(
      get: { query[keyPath: path].map(String.init) ?? "" },
      set: {
        query[keyPath: path] = $0.isEmpty ? nil : Int(String($0.filter(\.isNumber).prefix(4)))
      })
  }
}
