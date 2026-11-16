import SwiftUI

/// People ("people-v1"): everyone TMDB identified in the library's credits, those in the most
/// titles first, with a search like Wishes'. A person opens the same page as from Cast & Crew.
struct PeoplePage: View {
  @EnvironmentObject private var model: AppModel
  let onSelectPerson: (PersonSelection) -> Void
  /// Cmd-F on this page focuses the people search instead of switching to the library.
  var findRequestID: UUID?

  @State private var query = ""
  @State private var people: [PersonSummary] = []
  @State private var total = 0
  @State private var hasLoaded = false
  @State private var isLoading = false
  @State private var isLoadingMore = false
  @State private var errorMessage: String?
  /// Counts searches; an answer for an older search is dropped.
  @State private var generation = 0
  @FocusState private var searchFocused: Bool

  private static let pageSize = 60

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
          AureliaSectionHeading(title: "People", count: hasLoaded ? total : nil)
          Spacer()
        }
        searchField
        content
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.top, 22)
      .padding(.bottom, 48)
    }
    .scrollClipDisabled()
    .aureliaOverlayScrollbars()
    .task(id: query) {
      // Typing waits a moment before asking; the list shown stays until the answer replaces it.
      if hasLoaded { try? await Task.sleep(for: .milliseconds(220)) }
      guard !Task.isCancelled else { return }
      await load(reset: true)
    }
    .task(id: findRequestID) {
      guard findRequestID != nil else { return }
      searchFocused = false
      await Task.yield()
      guard !Task.isCancelled else { return }
      searchFocused = true
    }
    .accessibilityIdentifier("people-page")
  }

  private var searchField: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Find a Person", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .accessibilityIdentifier("people-search-field")
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear Search")
      }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: 420, minHeight: 34)
    .background(
      AureliaDesign.raisedSurface,
      in: RoundedRectangle(cornerRadius: AureliaDesign.smallRadius, style: .continuous))
  }

  @ViewBuilder
  private var content: some View {
    if !hasLoaded && errorMessage == nil {
      AureliaDelayedProgress()
        .frame(maxWidth: .infinity, minHeight: 260)
        .accessibilityLabel("Loading People")
    } else if let errorMessage, people.isEmpty {
      ContentUnavailableView {
        Label("Couldn’t Load People", systemImage: "exclamationmark.triangle")
      } description: {
        Text(errorMessage)
      } actions: {
        Button("Try Again") { Task { await load(reset: true) } }
      }
      .frame(maxWidth: .infinity, minHeight: 260)
    } else if people.isEmpty {
      ContentUnavailableView(
        query.isEmpty ? "No People Yet" : "No One Found",
        systemImage: "person.2",
        description: Text(
          query.isEmpty
            ? "People appear here once TMDB has identified the titles in your library."
            : "No one in your library matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”."
        )
      )
      .frame(maxWidth: .infinity, minHeight: 260)
    } else {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 132, maximum: 150), spacing: 18, alignment: .top)],
        alignment: .leading,
        spacing: 26
      ) {
        ForEach(people) { person in
          Button {
            onSelectPerson(person.selection)
          } label: {
            PeopleCard(person: person)
          }
          .buttonStyle(AureliaPressableButtonStyle())
          .accessibilityLabel("\(person.name), \(PeoplePresentation.role(person))")
          .accessibilityIdentifier("person-\(person.personKey)")
          .onAppear {
            if person.id == people.last?.id { Task { await load(reset: false) } }
          }
        }
      }
      .opacity(isLoading ? 0.6 : 1)
      if isLoadingMore {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
      } else if let errorMessage {
        ErrorBanner(
          message: errorMessage, retry: { Task { await load(reset: false) } }, inline: true)
      }
    }
  }

  private func load(reset: Bool) async {
    if !reset && (isLoadingMore || isLoading || people.count >= total) { return }
    generation += 1
    let request = generation
    let offset = reset ? 0 : people.count
    if reset { isLoading = true } else { isLoadingMore = true }
    defer {
      if request == generation {
        isLoading = false
        isLoadingMore = false
      }
    }
    do {
      let page = try await model.people(query: query, offset: offset, limit: Self.pageSize)
      guard request == generation, !Task.isCancelled else { return }
      if reset {
        people = page.items
      } else {
        let known = Set(people.map(\.id))
        people.append(contentsOf: page.items.filter { !known.contains($0.id) })
      }
      total = page.total
      errorMessage = nil
      hasLoaded = true
    } catch {
      if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
      {
        return
      }
      guard request == generation else { return }
      errorMessage = error.localizedDescription
      hasLoaded = true
    }
  }
}

/// What a person's card says under the name.
enum PeoplePresentation {
  static func role(_ person: PersonSummary) -> String {
    let titles = "\(person.titleCount) \(person.titleCount == 1 ? "title" : "titles")"
    guard let department = person.department, !department.isEmpty, department != "Acting" else {
      return titles
    }
    return "\(department) · \(titles)"
  }

  /// "Born May 1, 1970 (age 56) in Invented Town", or both dates for someone who died. TMDB writes
  /// dates as YYYY-MM-DD; anything else is left out.
  static func life(_ about: PersonAbout?, today: Date = Date(), calendar: Calendar = .current)
    -> String?
  {
    guard let about else { return nil }
    let born = day(about.birthday)
    let died = day(about.deathday)
    let place = about.placeOfBirth?.trimmingCharacters(in: .whitespacesAndNewlines)
    let shownPlace = place?.isEmpty == false ? place : nil
    if let born, let died {
      let line = "\(format(born)) – \(format(died)) (aged \(age(from: born, to: died)))"
      return shownPlace.map { "\(line) · \($0)" } ?? line
    }
    if let born {
      let parts = calendar.dateComponents([.year, .month, .day], from: today)
      let now = DateComponents(year: parts.year, month: parts.month, day: parts.day)
      let line = "Born \(format(born)) (age \(age(from: born, to: now)))"
      return shownPlace.map { "\(line) in \($0)" } ?? line
    }
    if let died { return "Died \(format(died))" }
    return shownPlace.map { "Born in \($0)" }
  }

  private static func day(_ text: String?) -> DateComponents? {
    guard let text, text.count == 10 else { return nil }
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
      return nil
    }
    return DateComponents(year: parts[0], month: parts[1], day: parts[2])
  }

  private static func age(from born: DateComponents, to day: DateComponents) -> Int {
    guard let bornYear = born.year, let year = day.year else { return 0 }
    let beforeBirthday = (day.month ?? 0, day.day ?? 0) < (born.month ?? 0, born.day ?? 0)
    return max(0, year - bornYear - (beforeBirthday ? 1 : 0))
  }

  private static func format(_ components: DateComponents) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    guard let date = calendar.date(from: components) else { return "" }
    return date.formatted(
      Date.FormatStyle(date: .long, time: .omitted, timeZone: calendar.timeZone)
        .locale(Locale(identifier: "en_US")))
  }
}

private struct PeopleCard: View {
  let person: PersonSummary
  @State private var hovering = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 8) {
      AuthenticatedArtwork(artwork: person.profile, symbol: "person.fill")
        .frame(width: 112, height: 112)
        .clipShape(Circle())
        .overlay {
          Circle().stroke(.white.opacity(hovering ? 0.35 : 0.1), lineWidth: hovering ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.34 : 0), radius: 14, y: 8)
        .scaleEffect(hovering && !reduceMotion ? 1.04 : 1)
      Text(person.name).font(.callout.weight(.semibold)).lineLimit(1)
      Text(PeoplePresentation.role(person)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .animation(reduceMotion ? nil : AureliaDesign.responsiveSpring, value: hovering)
    .onHover { hovering = $0 }
  }
}
