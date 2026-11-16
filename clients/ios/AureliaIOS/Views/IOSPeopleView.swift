import SwiftUI

/// People ("people-v1"): everyone TMDB identified in the library's credits, those in the most
/// titles first, with a search. Opened from the Search tab; a person opens the same page as from
/// Cast & Crew.
struct IOSPeopleView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var search = ""
  @State private var people: [IOSPersonSummary] = []
  @State private var total = 0
  @State private var loaded = false
  @State private var loadingMore = false
  @State private var error: String?
  /// Counts searches; an answer for an older search is dropped.
  @State private var generation = 0

  private static let columns = [
    GridItem(.adaptive(minimum: IOSDesign.isPad ? 120 : 96), spacing: 12, alignment: .top)
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if !loaded && error == nil {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if let error, people.isEmpty {
          VStack(spacing: 12) {
            IOSErrorText(message: error)
            Button("Try Again") { Task { await load(reset: true) } }.buttonStyle(IOSButtonStyle())
          }
          .padding(.horizontal, IOSDesign.margin).padding(.top, 60)
        } else if people.isEmpty {
          ContentUnavailableView(
            search.isEmpty ? "No People Yet" : "No One Found",
            systemImage: "person.2",
            description: Text(
              search.isEmpty
                ? "People appear here once TMDB has identified the titles in your library."
                : "No one in your library matches “\(search.trimmingCharacters(in: .whitespacesAndNewlines))”.")
          )
          .padding(.top, 40)
        } else {
          LazyVGrid(columns: Self.columns, spacing: 20) {
            ForEach(people) { person in
              NavigationLink {
                IOSPersonDetailView(name: person.name, personKey: person.personKey)
              } label: {
                IOSPeopleCard(person: person)
              }
              .buttonStyle(IOSContentButtonStyle())
              .accessibilityIdentifier("people-\(person.personKey)")
              .onAppear {
                if person.id == people.last?.id { Task { await load(reset: false) } }
              }
            }
          }
          .padding(.horizontal, IOSDesign.margin)
          if loadingMore {
            ProgressView().frame(maxWidth: .infinity)
          } else if let error {
            IOSErrorText(message: error).padding(.horizontal, IOSDesign.margin)
          }
        }
      }
      .padding(.vertical, 12)
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("People")
    .searchable(text: $search, prompt: "Find a Person")
    .task(id: search) {
      // Typing waits a moment before asking; the people shown stay until the answer arrives.
      if loaded { try? await Task.sleep(for: .milliseconds(250)) }
      guard !Task.isCancelled else { return }
      await load(reset: true)
    }
    .refreshable { await load(reset: true) }
  }

  private func load(reset: Bool) async {
    guard let client = model.client else { return }
    if !reset && (loadingMore || people.count >= total) { return }
    generation += 1
    let request = generation
    if !reset { loadingMore = true }
    defer { if request == generation { loadingMore = false } }
    do {
      let page = try await client.people(
        query: search, offset: reset ? 0 : people.count, limit: IOSPeoplePresentation.pageSize)
      guard request == generation, !Task.isCancelled else { return }
      if reset {
        people = page.items
      } else {
        let known = Set(people.map(\.id))
        people.append(contentsOf: page.items.filter { !known.contains($0.id) })
      }
      total = page.total
      error = nil
      loaded = true
    } catch {
      if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
      guard request == generation else { return }
      self.error = error.localizedDescription
      loaded = true
    }
  }
}

private struct IOSPeopleCard: View {
  let person: IOSPersonSummary
  var body: some View {
    VStack(spacing: 6) {
      IOSArtworkView(artwork: person.profile, width: 320, symbol: "person.fill")
        .frame(width: 84, height: 84).clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.5))
      Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
      Text(IOSPeoplePresentation.role(person)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}
