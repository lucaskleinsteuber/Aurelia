import SwiftUI

struct IOSBrowseDestination: View {
  @StateObject private var listing: IOSLibraryListing
  init(section: IOSBrowseSection) {
    _listing = StateObject(wrappedValue: IOSLibraryListing(section: section))
  }
  var body: some View { IOSLibraryGrid(listing: listing, title: listing.section.title) }
}

private struct IOSBrowseLoadKey: Equatable {
  let query: IOSBrowseQuery
  let search: String
  let session: UUID?
  let revision: UUID
}

struct IOSLibraryGrid: View {
  @EnvironmentObject private var model: IOSAppModel
  @ObservedObject var listing: IOSLibraryListing
  let title: String
  @State private var search = ""
  @State private var query = IOSBrowseQuery()
  @State private var filters = false
  @State private var restoredScope: String?
  @State private var lastKey: IOSBrowseLoadKey?
  @State private var scrollAnchor: UUID?
  /// The search text the server has answered; "No Results" waits for it, so typing "br" on the
  /// way to "Breaking Bad" never says that nothing was found.
  @State private var answeredSearch: String?
  @StateObject private var actions = IOSLibraryActions()
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
  private var key: IOSBrowseLoadKey {
    IOSBrowseLoadKey(
      query: query, search: search, session: model.session?.sessionId,
      revision: model.libraryRefresh)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if !querySummary.isEmpty {
          HStack(spacing: 10) {
            Text(querySummary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 8)
            Button("Clear") { query = listing.section.defaultQuery }
              .font(.footnote.weight(.semibold)).accessibilityIdentifier("browse-clear")
          }
        }
        if listing.items.isEmpty && !listing.loading && listing.error == nil
          && IOSSearchPresentation.showsEmptyResult(
            isSearch: listing.section == .search, search: search, answered: answeredSearch)
        {
          ContentUnavailableView(
            search.isEmpty ? "No Titles" : "No Results",
            systemImage: search.isEmpty ? "film" : "magnifyingglass",
            description: Text(
              search.isEmpty ? "No titles match this view." : "No titles match “\(search)”.")
          ).padding(.top, 40)
        }
        LazyVGrid(columns: IOSDesign.gridColumns, spacing: 20) {
          ForEach(listing.items) { original in
            let item = model.overlay(original)
            NavigationLink {
              IOSDetailView(
                id: item.detailID, initial: item,
                selectedEpisodeID: listing.section == .search && item.kind == .episode
                  ? item.id : nil)
            } label: {
              IOSPosterLabel(item: item)
            }
            .buttonStyle(IOSContentButtonStyle())
            .id(item.id).accessibilityIdentifier("catalog-\(item.id)")
            .contextMenu {
              IOSMediaContextActions(
                item: item, actions: actions, continuation: listing.section == .continueWatching)
            }
            .onAppear { if original.id == listing.items.last?.id { loadNext() } }
          }
        }.scrollTargetLayout()

        if listing.loading {
          ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            .accessibilityIdentifier("browse-loading")
        }
        if let error = listing.error {
          IOSErrorText(message: error)
          Button("Try Again") { loadNext() }.buttonStyle(IOSButtonStyle())
        }
      }.padding(.horizontal, IOSDesign.margin).padding(.vertical, 8)
    }
    .scrollPosition(id: $scrollAnchor, anchor: .top)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle(title)
    .modifier(IOSSearchField(enabled: listing.section == .search, text: $search))
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          filters = true
        } label: {
          Image(
            systemName: query == listing.section.defaultQuery
              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter & Sort").accessibilityIdentifier("browse-filters")
      }
    }
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
        if !Task.isCancelled { answeredSearch = request.search }
      }
      .sheet(isPresented: $filters) { IOSBrowseFilters(query: $query, section: listing.section) }
      .modifier(IOSLibraryActionPresentation(actions: actions))
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

private struct IOSBrowseFilters: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var query: IOSBrowseQuery
  let section: IOSBrowseSection
  var body: some View {
    NavigationStack {
      Form {
        if section.fixedKind == nil {
          Picker("Media", selection: $query.kind) {
            Text("All").tag(IOSMediaKind?.none)
            Text("Movies").tag(IOSMediaKind?.some(.movie))
            Text("TV Shows").tag(IOSMediaKind?.some(.series))
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
          ForEach(IOSWatchFilter.allCases, id: \.self) { Text($0.title).tag($0) }
        }.disabled(section == .continueWatching)
        Picker("Sort", selection: $query.sort) {
          Text("Default").tag(IOSBrowseSort?.none)
          ForEach(IOSBrowseSort.allCases, id: \.self) {
            Text($0.title).tag(IOSBrowseSort?.some($0))
          }
        }
        Toggle("Descending", isOn: $query.descending).disabled(query.sort == nil)
        Section {
          Button("Reset Filters & Sort", role: .destructive) { query = section.defaultQuery }
        }
      }
      .navigationTitle("Filter & Sort")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            query = section.constrain(query)
            dismiss()
          }.accessibilityIdentifier("filters-done")
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
  private func year(_ path: WritableKeyPath<IOSBrowseQuery, Int?>) -> Binding<String> {
    Binding(
      get: { query[keyPath: path].map(String.init) ?? "" },
      set: {
        query[keyPath: path] = $0.isEmpty ? nil : Int(String($0.filter(\.isNumber).prefix(4)))
      })
  }
}

/// The Search tab's field in the navigation bar; other lists have none.
private struct IOSSearchField: ViewModifier {
  let enabled: Bool
  @Binding var text: String
  func body(content: Content) -> some View {
    if enabled {
      content.searchable(
        text: $text, placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Movies and TV Shows"
      )
      .textInputAutocapitalization(.never).autocorrectionDisabled()
    } else {
      content
    }
  }
}

