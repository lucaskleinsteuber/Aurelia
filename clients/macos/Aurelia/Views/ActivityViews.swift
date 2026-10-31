import Charts
import SwiftUI

/// Settings › Activity: the profile's statistics and watch history, side by side in one tab.
struct SettingsActivityView: View {
  enum Page: String, CaseIterable, Identifiable {
    case statistics = "Statistics"
    case history = "History"
    var id: String { rawValue }
  }

  @AppStorage("AureliaSettingsActivityPage") private var page = Page.statistics

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Picker("Show", selection: $page) {
        ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 240)
      .accessibilityIdentifier("activity-page")
      switch page {
      case .statistics: ActivityStatisticsView()
      case .history: ActivityHistoryView()
      }
    }
  }
}

// MARK: - Statistics

/// Watch time, streaks, the last twelve weeks, favorites and a year in review. Every duration
/// reads in minutes, hours and days.
struct ActivityStatisticsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var stats: UserStatistics?
  @State private var loading = false
  @State private var error: String?
  @State private var selectedYear: Int?
  @State private var review: YearInReview?
  @State private var selectedWeek: String?

  /// Synthetic statistics can be passed in for rendering checks; a signed-in profile loads its own.
  init(stats: UserStatistics? = nil, review: YearInReview? = nil) {
    _stats = State(initialValue: stats)
    _review = State(initialValue: review)
    _selectedYear = State(initialValue: review?.year)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if loading && stats == nil {
        ProgressView("Loading statistics…")
          .frame(maxWidth: .infinity, minHeight: 160)
      } else if let error, stats == nil {
        AureliaSettingsSection(
          "Statistics Unavailable", symbol: "exclamationmark.triangle.fill", description: error
        ) {
          Button("Try Again") { Task { await load() } }
        }
      } else if let stats {
        if stats.totalHoursWatched <= 0 {
          empty
        } else {
          summary(stats)
          highlights(stats)
          if !stats.weeklyHours.isEmpty { weeks(WatchTime.lastWeeks(stats.weeklyHours)) }
          if let titles = stats.topTitles, !titles.isEmpty {
            ranking(
              "Most Watched", symbol: "star.fill",
              description: "Series count with all their episodes.", items: titles)
          }
          if let genres = stats.topGenres, !genres.isEmpty {
            ranking(
              "Favorite Genres", symbol: "film.stack",
              description: "By the time you spent with them.", items: genres)
          }
          if let years = stats.yearsAvailable, !years.isEmpty { yearInReview(years) }
        }
      }
    }
    .task(id: model.profile?.sessionId) { await load() }
    .accessibilityIdentifier("activity-statistics")
  }

  private var empty: some View {
    AureliaSettingsSection("Statistics", symbol: "chart.bar.xaxis") {
      VStack(spacing: 10) {
        Image(systemName: "chart.bar.xaxis").font(.system(size: 34)).foregroundStyle(.secondary)
        Text("No Viewing Activity Yet").font(.headline)
        Text("Watch a movie or an episode, and your watch time, streaks and favorites appear here.")
          .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: 380)
      }
      .frame(maxWidth: .infinity, minHeight: 140)
    }
  }

  private func summary(_ stats: UserStatistics) -> some View {
    AureliaSurface {
      HStack(alignment: .center, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Label("Total Watch Time", systemImage: "clock.fill")
            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
          Text(WatchTime.text(hours: stats.totalHoursWatched))
            .font(.system(size: 34, weight: .bold))
            .lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityIdentifier("activity-total-time")
        }
        Spacer(minLength: 12)
        VStack(alignment: .trailing, spacing: 10) {
          recent("Past 7 Days", hours: stats.hoursPast7Days ?? 0)
          recent("Past 30 Days", hours: stats.hoursPast30Days ?? 0)
        }
      }
    }
  }

  private func recent(_ title: String, hours: Double) -> some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(WatchTime.text(hours: hours)).font(.title3.weight(.semibold)).monospacedDigit()
    }
  }

  private func highlights(_ stats: UserStatistics) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12)
    {
      card("Current Streak", value: days(stats.currentStreakDays ?? 0), symbol: "flame.fill")
      card("Longest Streak", value: days(stats.longestStreakDays ?? 0), symbol: "trophy.fill")
      card(
        "Finished", value: "\(Int(stats.completionRatePercent.rounded())) %",
        symbol: "checkmark.circle.fill")
      card(
        "Watches Most", value: stats.busiestWeekday ?? "—",
        detail: stats.busiestTimeOfDay.map(Self.timeOfDay), symbol: "calendar")
    }
  }

  private func card(_ title: String, value: String, detail: String? = nil, symbol: String)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
      if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
    }
    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
    .padding(14)
    .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(AureliaDesign.hairline, lineWidth: 1)
    }
  }

  private func weeks(_ weeks: [PeriodHours]) -> some View {
    let selected = weeks.first { $0.period == selectedWeek }
    return AureliaSettingsSection("Last 12 Weeks", symbol: "chart.bar.fill") {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          selected.map {
            "Week of \(Self.weekTitle($0.period)): \(WatchTime.text(hours: $0.hours))"
          }
            ?? "Point at a week to see its watch time."
        )
        .font(.callout).foregroundStyle(selected == nil ? .secondary : .primary)
        Chart(weeks, id: \.period) { week in
          BarMark(
            x: .value("Week", week.period),
            y: .value("Watch Time", week.hours)
          )
          .foregroundStyle(
            selectedWeek == nil || selectedWeek == week.period
              ? Color.accentColor : Color.accentColor.opacity(0.35)
          )
          .cornerRadius(4)
          .accessibilityLabel("Week of \(Self.weekTitle(week.period))")
          .accessibilityValue(WatchTime.text(hours: week.hours))
        }
        .chartXSelection(value: $selectedWeek)
        .chartXAxis {
          AxisMarks { value in
            AxisValueLabel {
              if let period = value.as(String.self) { Text(Self.weekTitle(period)) }
            }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisValueLabel {
              if let hours = value.as(Double.self) { Text(WatchTime.text(hours: hours)) }
            }
          }
        }
        .frame(height: 180)
      }
    }
  }

  private func ranking(
    _ title: String, symbol: String, description: String, items: [NamedCount]
  ) -> some View {
    let shown = Array(items.prefix(5))
    let longest = max(shown.compactMap(\.hours).max() ?? 0, 0.0001)
    return AureliaSettingsSection(title, symbol: symbol, description: description) {
      VStack(spacing: 12) {
        ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
          VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
              Text("\(index + 1)").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
              Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
              Spacer()
              Text(item.hours.map { WatchTime.text(hours: $0) } ?? plays(item.count))
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if let hours = item.hours {
              GeometryReader { proxy in
                Capsule().fill(Color.accentColor.opacity(0.75))
                  .frame(width: max(4, proxy.size.width * hours / longest))
              }
              .frame(height: 4)
              .padding(.leading, 18)
            }
          }
        }
      }
    }
  }

  private func yearInReview(_ years: [Int]) -> some View {
    AureliaSettingsSection("Year in Review", symbol: "sparkles") {
      VStack(alignment: .leading, spacing: 14) {
        Picker(
          "Year",
          selection: Binding(
            get: { selectedYear ?? years[0] },
            set: { year in
              selectedYear = year
              Task { await loadYear(year) }
            })
        ) {
          ForEach(years, id: \.self) { Text(String($0)).tag($0) }
        }
        .frame(width: 160)
        if let review {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
            card("Watch Time", value: WatchTime.text(hours: review.totalHours), symbol: "clock")
            card("Titles", value: "\(review.totalTitles)", symbol: "square.stack")
            card("Movies", value: "\(review.movieCount)", symbol: "film")
            card("Episodes", value: "\(review.episodeCount)", symbol: "tv")
          }
          VStack(alignment: .leading, spacing: 8) {
            if let genre = review.topGenre { LabeledContent("Favorite Genre", value: genre) }
            if let title = review.topTitle { LabeledContent("Most Watched", value: title) }
            if let day = review.busiestDay {
              LabeledContent(
                "Busiest Day",
                value: [
                  Self.dayText(day), review.busiestDayHours.map { WatchTime.text(hours: $0) },
                ]
                .compactMap { $0 }.joined(separator: " · "))
            }
          }
          .font(.callout)
        }
      }
    }
  }

  private func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
  private func plays(_ count: Int) -> String { count == 1 ? "1 time" : "\(count) times" }

  /// "Evening (18:00–23:00)" from the server reads "in the evening".
  static func timeOfDay(_ text: String) -> String {
    let word = text.split(separator: " ").first.map(String.init)?.lowercased() ?? text
    return word == "night" ? "at night" : "in the \(word)"
  }

  static func weekTitle(_ period: String) -> String {
    guard let start = WatchTime.weekStart(period) else { return period }
    return start.formatted(.dateTime.day().month(.abbreviated))
  }

  static func dayText(_ day: String) -> String? {
    let parser = DateFormatter()
    parser.calendar = Calendar(identifier: .gregorian)
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd"
    return parser.date(from: day)?.formatted(date: .long, time: .omitted) ?? day
  }

  private func load() async {
    guard let profile = model.profile else { return }
    loading = true
    defer { loading = false }
    do {
      let loaded = try await APIClient(profile: profile).statistics()
      stats = loaded
      error = nil
      if let year = selectedYear ?? loaded.yearsAvailable?.first { await loadYear(year) }
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func loadYear(_ year: Int) async {
    guard let profile = model.profile else { return }
    review = try? await APIClient(profile: profile).yearInReview(year: year)
  }
}

// MARK: - History

/// What the profile watched, newest first and grouped by day, with how long each time lasted.
struct ActivityHistoryView: View {
  @EnvironmentObject private var model: AppModel
  /// Opens a title in the library; Settings has no library to open it in.
  let onSelect: ((UUID) -> Void)?
  @State private var items: [WatchHistoryItem] = []
  @State private var total = 0
  @State private var loading = false
  @State private var error: String?
  @State private var confirmClear = false

  init(onSelect: ((UUID) -> Void)? = nil, items: [WatchHistoryItem] = [], total: Int = 0) {
    self.onSelect = onSelect
    _items = State(initialValue: items)
    _total = State(initialValue: total)
  }

  private var days: [(title: String, items: [WatchHistoryItem])] {
    var result: [(title: String, items: [WatchHistoryItem])] = []
    for item in items {
      let title = item.watchedDate.map { WatchTime.dayTitle(for: $0) } ?? "Earlier"
      if result.last?.title == title {
        result[result.count - 1].items.append(item)
      } else {
        result.append((title, [item]))
      }
    }
    return result
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text(total == 1 ? "1 entry" : "\(total) entries")
          .font(.callout).foregroundStyle(.secondary)
        Spacer()
        if !items.isEmpty {
          Button("Clear History…", role: .destructive) { confirmClear = true }
            .accessibilityIdentifier("clear-history-button")
        }
      }
      if let error { Text(error).font(.callout).foregroundStyle(.orange) }
      if loading && items.isEmpty {
        ProgressView("Loading history…").frame(maxWidth: .infinity, minHeight: 160)
      } else if items.isEmpty {
        ContentUnavailableView(
          "No Watch History", systemImage: "clock.arrow.circlepath",
          description: Text("Movies and episodes you watch appear here.")
        )
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        ForEach(days, id: \.title) { day in
          AureliaSettingsSection(day.title, symbol: "calendar") {
            VStack(spacing: 0) {
              ForEach(day.items) { item in
                row(item)
                if item.id != day.items.last?.id { Divider().padding(.leading, 56) }
              }
            }
          }
        }
        if items.count < total {
          Button(loading ? "Loading…" : "Show More") { Task { await load(offset: items.count) } }
            .disabled(loading)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .task(id: model.profile?.sessionId) { await load(offset: 0) }
    .confirmationDialog(
      "Clear your watch history?", isPresented: $confirmClear, titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) { Task { await clear() } }
    } message: {
      Text("Your statistics start over. Progress, favorites and your media stay as they are.")
    }
    .accessibilityIdentifier("activity-history")
  }

  private func row(_ item: WatchHistoryItem) -> some View {
    HStack(spacing: 14) {
      AuthenticatedArtwork(
        artwork: item.poster, symbol: item.kind == "movie" ? "film" : "tv",
        placeholderSymbolSize: 16
      )
      .frame(width: 40, height: 60)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(AureliaDesign.hairline, lineWidth: 1)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title).font(.body.weight(.medium)).lineLimit(1)
        Text(
          [item.eyebrow, item.watchedDate?.formatted(date: .omitted, time: .shortened)]
            .compactMap { $0 }.joined(separator: " · ")
        )
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 12)
      VStack(alignment: .trailing, spacing: 5) {
        Text("Watched \(WatchTime.text(seconds: Int(item.secondsWatched)))")
          .font(.callout).monospacedDigit()
        if item.isCompleted {
          Label("Finished", systemImage: "checkmark.circle.fill")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ProgressView(value: min(max(item.completionPercentage / 100, 0), 1))
            .frame(width: 90)
            .help("\(Int(item.completionPercentage)) % of the title")
        }
      }
      if let onSelect {
        Button {
          onSelect(item.mediaId)
        } label: {
          Image(systemName: "chevron.right.circle.fill").font(.title3)
        }
        .buttonStyle(.plain)
        .help("Open Title")
      }
      Button {
        Task { await remove(item) }
      } label: {
        Image(systemName: "xmark.circle").foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Remove from History")
      .accessibilityLabel("Remove \(item.title) from History")
    }
    .padding(.vertical, 8)
  }

  private func load(offset: Int) async {
    guard let profile = model.profile else { return }
    loading = true
    defer { loading = false }
    do {
      let page = try await APIClient(profile: profile).history(offset: offset, limit: 50)
      items = offset == 0 ? page.items : items + page.items
      total = page.total
      error = nil
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func remove(_ item: WatchHistoryItem) async {
    guard let profile = model.profile else { return }
    do {
      try await APIClient(profile: profile).deleteHistoryItem(id: item.id)
      items.removeAll { $0.id == item.id }
      total = max(0, total - 1)
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func clear() async {
    guard let profile = model.profile else { return }
    do {
      try await APIClient(profile: profile).clearHistory()
      items = []
      total = 0
    } catch {
      self.error = error.localizedDescription
    }
  }
}
