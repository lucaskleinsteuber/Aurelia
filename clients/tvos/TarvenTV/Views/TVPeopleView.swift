import SwiftUI

/// People ("people-v1"): everyone TMDB identified in the library's credits, those in the most
/// titles first, with a search by the TV keyboard or dictation.
struct TVPeopleView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var query = ""
  @State private var people: [TVPersonSummary] = []
  @State private var total = 0
  @State private var loading = false
  @State private var error: String?
  private let columns = Array(repeating: GridItem(.fixed(220), spacing: 48), count: 6)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 34) {
        TextField("Search People", text: $query)
          .frame(width: 900)
          .padding(.horizontal, TVDesign.pagePadding)
          .accessibilityIdentifier("people-search")
        if let error { TVErrorText(message: error).padding(.horizontal, TVDesign.pagePadding) }
        if people.isEmpty, !loading, error == nil {
          ContentUnavailableView(
            query.isEmpty ? "No People Yet" : "No One Found", systemImage: "person.2",
            description: Text(
              query.isEmpty
                ? "People appear once TMDB identified the cast and crew of the library."
                : "Try another name."))
        }
        LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
          ForEach(people) { person in
            NavigationLink {
              TVPersonDetailView(name: person.name, personKey: person.personKey)
            } label: {
              VStack(spacing: 12) {
                TVArtworkView(artwork: person.profile, width: 320, symbol: "person.fill")
                  .frame(width: 170, height: 170).clipShape(Circle())
                Text(person.name).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                Text(TVPeoplePresentation.role(person)).font(.system(size: 18))
                  .foregroundStyle(.secondary).lineLimit(1)
              }
              .frame(width: 220)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("people-\(person.personKey)")
            .onAppear {
              if person.id == people.last?.id, people.count < total { Task { await more() } }
            }
          }
        }
        .padding(.horizontal, TVDesign.pagePadding)
        if loading { ProgressView().frame(maxWidth: .infinity) }
      }
      .padding(.vertical, 40)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
    .task(id: query) {
      // A short pause while the name is still being typed or spoken.
      if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
      guard !Task.isCancelled else { return }
      await reload()
    }
  }

  private func reload() async {
    people = []
    total = 0
    await more()
  }

  private func more() async {
    guard let client = model.client, !loading else { return }
    loading = true
    defer { loading = false }
    do {
      let page = try await client.people(
        query: query, offset: people.count, limit: TVPeoplePresentation.pageSize)
      let known = Set(people.map(\.id))
      people += page.items.filter { !known.contains($0.id) }
      total = page.total
      error = nil
    } catch {
      if !(error is CancellationError) { self.error = error.localizedDescription }
    }
  }
}
