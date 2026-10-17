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
          Button {
            filters = true
          } label: {
            Label("Filter & Sort", systemImage: "line.3.horizontal.decrease")
          }
          .buttonStyle(TVButtonStyle()).accessibilityIdentifier("browse-filters")
        }
        if listing.section == .search {
          TextField("Search Library", text: $search).submitLabel(.search)
            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
              "library-search")
        }
        if !querySummary.isEmpty {
          HStack {
            Text(querySummary).font(.system(size: 22)).foregroundStyle(.secondary)
            Button("Clear Filters") { query = listing.section.defaultQuery }.buttonStyle(
              TVButtonStyle()
            ).accessibilityIdentifier("browse-clear")
          }
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
          // Only the library revision changed: update the shown titles in place.
          lastKey = request
          if let api = model.client {
            await listing.refresh(api: api, onFailure: model.handleSessionFailure)
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
      .sheet(isPresented: $filters) { TVBrowseFilters(query: $query, section: listing.section) }
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

private struct TVBrowseFilters: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var query: TVBrowseQuery
  let section: TVBrowseSection
  var body: some View {
    NavigationStack {
      Form {
        if section.fixedKind == nil {
          Picker("Media", selection: $query.kind) {
            Text("All").tag(TVMediaKind?.none)
            Text("Movies").tag(TVMediaKind?.some(.movie))
            Text("TV Shows").tag(TVMediaKind?.some(.series))
          }
        }
        Toggle("Favorites Only", isOn: $query.favoritesOnly).disabled(section == .favorites)
          .accessibilityIdentifier("filter-favorites")
        TextField(
          "Genre",
          text: Binding(get: { query.genre ?? "" }, set: { query.genre = $0.isEmpty ? nil : $0 })
        ).accessibilityIdentifier("filter-genre")
        TextField("Year From", text: year(\.yearFrom)).keyboardType(.numberPad)
          .accessibilityIdentifier("filter-year-from")
        TextField("Year To", text: year(\.yearTo)).keyboardType(.numberPad).accessibilityIdentifier(
          "filter-year-to")
        Picker("Watch Status", selection: $query.watchState) {
          ForEach(TVWatchFilter.allCases, id: \.self) { Text($0.title).tag($0) }
        }.disabled(section == .continueWatching)
        Picker("Sort", selection: $query.sort) {
          Text("Default").tag(TVBrowseSort?.none)
          ForEach(TVBrowseSort.allCases, id: \.self) { Text($0.title).tag(TVBrowseSort?.some($0)) }
        }
        Toggle("Descending", isOn: $query.descending).disabled(query.sort == nil)
        Button("Reset Filters & Sort") { query = section.defaultQuery }
        Button("Done") {
          query = section.constrain(query)
          dismiss()
        }.accessibilityIdentifier("filters-done")
      }.navigationTitle("Filter & Sort").background(TVDesign.canvas)
    }
  }
  private func year(_ path: WritableKeyPath<TVBrowseQuery, Int?>) -> Binding<String> {
    Binding(
      get: { query[keyPath: path].map(String.init) ?? "" },
      set: {
        query[keyPath: path] = $0.isEmpty ? nil : Int(String($0.filter(\.isNumber).prefix(4)))
      })
  }
}
