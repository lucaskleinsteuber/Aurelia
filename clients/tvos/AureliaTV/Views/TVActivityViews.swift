import Charts
import SwiftUI

extension Color {
  /// A color from 0xRRGGBB, for Wrapped's fixed palette.
  init(wrappedHex hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

/// What this profile watched, grouped by day, newest first (copied from the iPhone app). Press
/// and hold a title to remove it.
struct TVWatchHistoryView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var items: [TVWatchHistoryItem] = []
  @State private var total = 0
  @State private var loading = true
  @State private var loadingMore = false
  @State private var error: String?
  @State private var confirmClear = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 34) {
        HStack {
          Text("Watch History").font(.system(size: 52, weight: .bold))
          Spacer()
          if !items.isEmpty {
            Button("Clear History", role: .destructive) { confirmClear = true }
              .buttonStyle(TVButtonStyle())
              .accessibilityIdentifier("history-clear")
          }
        }
        if loading && items.isEmpty {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if let error, items.isEmpty {
          VStack(spacing: 20) {
            TVErrorText(message: error)
            Button("Try Again") { Task { await load() } }.buttonStyle(TVButtonStyle())
          }
          .frame(maxWidth: .infinity).padding(.top, 80)
        } else if items.isEmpty {
          Text("Titles you watch on any device appear here.")
            .font(.system(size: 28)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.top, 120)
        }
        ForEach(TVWatchTime.days(items), id: \.title) { day in
          VStack(alignment: .leading, spacing: 16) {
            Text(day.title).font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(day.items) { item in
              Button {
              } label: {
                TVHistoryRow(item: item)
              }
              .buttonStyle(TVButtonStyle())
              .contextMenu {
                Button("Remove from History", role: .destructive) { Task { await remove(item) } }
              }
              .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
              .accessibilityHint("Press and hold to remove it from the history.")
            }
          }
        }
        if loadingMore { ProgressView().frame(maxWidth: .infinity) }
      }
      .padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 40)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
    .confirmationDialog(
      "Clear the whole watch history of this profile?", isPresented: $confirmClear,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) { Task { await clear() } }
    } message: {
      Text("Progress and watched marks stay as they are.")
    }
    .task { await load() }
  }

  private func load() async {
    guard let client = model.client else { return }
    loading = true
    defer { loading = false }
    do {
      let page = try await client.history(offset: 0)
      items = page.items
      total = page.total
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func loadMore() async {
    guard !loadingMore, items.count < total, let client = model.client else { return }
    loadingMore = true
    defer { loadingMore = false }
    if let page = try? await client.history(offset: items.count) {
      let known = Set(items.map(\.id))
      items += page.items.filter { !known.contains($0.id) }
      total = page.total
    }
  }

  private func remove(_ item: TVWatchHistoryItem) async {
    guard let client = model.client else { return }
    do {
      try await client.deleteHistoryItem(id: item.id)
      items.removeAll { $0.id == item.id }
      total = max(0, total - 1)
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func clear() async {
    guard let client = model.client else { return }
    do {
      try await client.clearHistory()
      items = []
      total = 0
    } catch {
      self.error = error.localizedDescription
    }
  }
}

private struct TVHistoryRow: View {
  let item: TVWatchHistoryItem

  var body: some View {
    HStack(spacing: 24) {
      TVArtworkView(artwork: item.poster, width: 320, symbol: item.kind == "episode" ? "tv" : "film")
        .frame(width: 80, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 6) {
        Text(item.title).font(.system(size: 30, weight: .semibold)).lineLimit(1)
        if let eyebrow = item.eyebrow, !eyebrow.isEmpty {
          Text(eyebrow).font(.system(size: 24)).foregroundStyle(.secondary).lineLimit(1)
        }
        HStack(spacing: 10) {
          if item.isCompleted {
            Label("Finished", systemImage: "checkmark.circle.fill")
          } else {
            Capsule().fill(.white.opacity(0.25)).frame(width: 90, height: 6)
              .overlay(alignment: .leading) {
                Capsule().fill(.white).frame(width: 90 * item.fraction, height: 6)
              }
          }
          Text("· \(TVWatchTime.text(seconds: Int(item.secondsWatched)))")
          if let date = item.watchedDate {
            Text("· \(date.formatted(date: .omitted, time: .shortened))")
          }
        }
        .font(.system(size: 22)).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

struct TVWrappedLaunch: Identifiable, Equatable {
  let year: Int
  var month: Int? = nil
  var id: String { "\(year)-\(month ?? 0)" }
}

/// Watch time, streaks, the last weeks as a chart, favorite titles and genres, a year in review
/// and Wrapped, for this profile (copied from the iPhone app).
struct TVStatisticsView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var stats: TVUserStatistics?
  @State private var review: TVYearInReview?
  @State private var year = Calendar.current.component(.year, from: Date())
  @State private var wrappedYear: TVWrappedLaunch?
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 40) {
        Text("Statistics").font(.system(size: 52, weight: .bold))
        if let stats {
          HStack(spacing: 24) {
            tile("Total", TVWatchTime.text(hours: stats.totalHoursWatched), symbol: "clock")
            tile("Last 7 Days", TVWatchTime.text(hours: stats.hoursPast7Days ?? 0), symbol: "calendar")
            tile("Current Streak", days(stats.currentStreakDays ?? 0), symbol: "flame")
            tile(
              "Finished", "\(Int((stats.completionRate ?? 0).rounded())) %",
              symbol: "checkmark.circle")
          }
          if model.capabilities?.supportsMonthlyWrapped == true {
            monthlyWrapped
          }
          weeks(stats.hoursByWeek ?? [])
          HStack(alignment: .top, spacing: 40) {
            ranking("Top Titles", stats.topTitles ?? [])
            ranking("Top Genres", stats.topGenres ?? [])
          }
          yearInReview(stats.yearsAvailable ?? [])
        } else if let error {
          VStack(spacing: 20) {
            TVErrorText(message: error)
            Button("Try Again") { Task { await load() } }.buttonStyle(TVButtonStyle())
          }
          .frame(maxWidth: .infinity).padding(.top, 80)
        } else {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        }
      }
      .padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 40)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
    .task { await load() }
    .task(id: year) { await loadReview() }
    .fullScreenCover(item: $wrappedYear) { launch in
      TVWrappedView(launch: launch).environmentObject(model)
    }
  }

  private func tile(_ title: String, _ value: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: symbol).font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.secondary)
      Text(value).font(.system(size: 38, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(26)
    .background(TVDesign.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private var monthlyWrapped: some View {
    let ready = TVWrapped.readyMonth()
    return Button {
      wrappedYear = TVWrappedLaunch(year: ready.year, month: ready.month)
    } label: {
      HStack(spacing: 24) {
        Text(String(ready.name.prefix(3))).font(.system(size: 40, weight: .black))
        VStack(alignment: .leading, spacing: 4) {
          Text("Your \(ready.name) Wrapped is here").font(.system(size: 30, weight: .bold))
          Text("Last month in slides. It's worse than you think.").font(.system(size: 22))
        }
        Spacer()
        Image(systemName: "play.fill")
      }
      .foregroundStyle(Color(wrappedHex: 0x22000F))
      .padding(24)
      .background(Color(wrappedHex: 0xFF4D88), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    .buttonStyle(TVButtonStyle())
    .accessibilityIdentifier("monthly-wrapped")
  }

  @ViewBuilder
  private func weeks(_ periods: [TVPeriodHours]) -> some View {
    let points = periods.suffix(12).compactMap { period in
      TVWatchTime.weekStart(period.period).map { (week: $0, hours: period.hours) }
    }
    if !points.isEmpty {
      VStack(alignment: .leading, spacing: 16) {
        Text("Last Weeks").font(.system(size: 32, weight: .bold))
        Chart(points, id: \.week) { point in
          BarMark(
            x: .value("Week", point.week, unit: .weekOfYear),
            y: .value("Hours", point.hours)
          )
          .foregroundStyle(.white.opacity(0.85))
          .cornerRadius(4)
        }
        .chartYAxis {
          AxisMarks { value in
            AxisGridLine().foregroundStyle(.white.opacity(0.1))
            AxisValueLabel {
              if let hours = value.as(Double.self) { Text(TVWatchTime.text(hours: hours)) }
            }
          }
        }
        .chartXAxis {
          AxisMarks(values: .stride(by: .weekOfYear, count: 2)) {
            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
          }
        }
        .frame(height: 260)
        .accessibilityLabel("Watch time in the last weeks")
      }
    }
  }

  @ViewBuilder
  private func ranking(_ title: String, _ entries: [TVNamedCount]) -> some View {
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        Text(title).font(.system(size: 32, weight: .bold))
        VStack(spacing: 0) {
          ForEach(Array(entries.prefix(5).enumerated()), id: \.offset) { index, entry in
            HStack(spacing: 18) {
              Text("\(index + 1)").font(.system(size: 26, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 30)
              Text(entry.name).font(.system(size: 26)).lineLimit(1)
              Spacer(minLength: 12)
              Text(
                entry.hours.map { TVWatchTime.text(hours: $0) }
                  ?? (entry.count == 1 ? "1 time" : "\(entry.count) times")
              )
              .font(.system(size: 24)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).frame(minHeight: 66)
          }
        }
        .background(TVDesign.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func yearInReview(_ years: [Int]) -> some View {
    if !years.isEmpty {
      VStack(alignment: .leading, spacing: 18) {
        Text("Year in Review").font(.system(size: 32, weight: .bold))
        HStack(spacing: 16) {
          ForEach(years.sorted(by: >), id: \.self) { candidate in
            Button(String(candidate)) { year = candidate }
              .buttonStyle(TVButtonStyle())
              .accessibilityAddTraits(candidate == year ? .isSelected : [])
              .opacity(candidate == year ? 1 : 0.65)
          }
        }
        .focusSection()
        if model.capabilities?.supportsWrapped == true {
          Button {
            wrappedYear = TVWrappedLaunch(year: year)
          } label: {
            HStack(spacing: 24) {
              Text(String(year)).font(.system(size: 44, weight: .black))
                .foregroundStyle(Color(wrappedHex: 0xFFD84D))
              VStack(alignment: .leading, spacing: 4) {
                Text("Play your \(String(year)) Wrapped").font(.system(size: 30, weight: .bold))
                Text("Your year in slides, with commentary nobody asked for.").font(.system(size: 22))
              }
              Spacer()
              Image(systemName: "play.fill")
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(Color(wrappedHex: 0x6A4CFF), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
          }
          .buttonStyle(TVButtonStyle())
          .accessibilityIdentifier("statistics-wrapped")
        }
        if let review {
          HStack(spacing: 24) {
            tile("Watch Time", TVWatchTime.text(hours: review.totalHoursWatched ?? 0), symbol: "clock")
            tile("Titles", "\(review.titlesWatched ?? 0)", symbol: "film.stack")
            tile("Movies", "\(review.moviesWatched ?? 0)", symbol: "film")
            tile("Episodes", "\(review.episodesWatched ?? 0)", symbol: "tv")
          }
          if let top = review.topTitle {
            Label("Most watched: \(top)", systemImage: "star").font(.system(size: 24))
              .foregroundStyle(.secondary)
          }
        }
      }
      .onAppear { if !years.contains(year), let latest = years.max() { year = latest } }
    }
  }

  private func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }

  private func load() async {
    guard let client = model.client else { return }
    do {
      stats = try await client.statistics()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func loadReview() async {
    guard let client = model.client else { return }
    review = try? await client.yearInReview(year: year)
  }
}

/// Wrapped on the Apple TV: the year (or a month) as full-screen slides. Each slide runs for six
/// seconds; right moves on, left goes back, Play/Pause holds, Back leaves. With Reduce Motion the
/// slides wait for the remote and numbers do not count up.
struct TVWrappedView: View {
  @EnvironmentObject private var model: TVAppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let launch: TVWrappedLaunch
  @State private var wrapped: TVYearWrapped?
  @State private var error: String?
  @State private var index = 0
  @State private var progress: Double = 0
  @State private var held = false
  @State private var shownNumber: String?
  @FocusState private var focused: Bool

  var body: some View {
    let slide = wrapped?.slides.indices.contains(index) == true ? wrapped?.slides[index] : nil
    let accent = TVWrapped.accent(slide?.accent ?? "night")
    ZStack {
      Color(wrappedHex: accent.field).ignoresSafeArea()
      if let poster = slide?.poster {
        TVArtworkView(artwork: poster, width: 640, symbol: nil)
          .blur(radius: 60).opacity(0.3).ignoresSafeArea()
      }
      if let slide {
        content(slide, accent: accent)
        bars(count: wrapped?.slides.count ?? 0, accent: accent)
      } else if let error {
        VStack(spacing: 24) {
          Text("Wrapped didn't load.").font(.system(size: 56, weight: .black))
          Text(error).font(.system(size: 26)).multilineTextAlignment(.center)
          Button("Close") { dismiss() }.buttonStyle(TVButtonStyle())
        }
      } else {
        ProgressView().tint(.white)
      }
    }
    .foregroundStyle(Color(wrappedHex: accent.ink))
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onAppear { focused = true }
    .onMoveCommand { direction in
      switch direction {
      case .left: go(forward: false)
      case .right: go(forward: true)
      default: break
      }
    }
    .onTapGesture { go(forward: true) }
    .onPlayPauseCommand { held.toggle() }
    .onExitCommand { dismiss() }
    .animation(.easeInOut(duration: 0.3), value: index)
    .task { await load() }
    .task(id: "\(index)-\(held)-\(wrapped != nil)") { await run() }
    .accessibilityElement(children: .contain)
    .accessibilityHint("Swipe right for the next slide, left for the previous one.")
  }

  private func content(_ slide: TVWrappedSlide, accent: TVWrapped.Accent) -> some View {
    HStack(alignment: .center, spacing: 70) {
      VStack(alignment: .leading, spacing: 22) {
        Text(slide.eyebrow).font(.system(size: 30, weight: .bold)).opacity(0.8)
        Text(slide.headline).font(.system(size: 72, weight: .black)).tracking(-2).lineLimit(3)
          .minimumScaleFactor(0.6)
        if let number = slide.bigNumber {
          VStack(alignment: .leading, spacing: 0) {
            Text(shownNumber ?? number)
              .font(.system(size: 220, weight: .black).monospacedDigit())
              .tracking(-10).minimumScaleFactor(0.4).lineLimit(1)
            if let unit = slide.unit { Text(unit).font(.system(size: 48, weight: .heavy)) }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel([number, slide.unit].compactMap { $0 }.joined(separator: " "))
        }
        if let detail = slide.detail { Text(detail).font(.system(size: 30)) }
        if let facts = slide.facts {
          Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
            ForEach(facts, id: \.label) { fact in
              GridRow {
                Text(fact.label).opacity(0.72)
                Text(fact.value).fontWeight(.heavy)
              }
            }
          }
          .font(.system(size: 28))
        }
        Text(slide.quip)
          .font(.system(size: 30, weight: .heavy))
          .foregroundStyle(Color(wrappedHex: accent.field))
          .padding(.horizontal, 24).padding(.vertical, 14)
          .background(Color(wrappedHex: accent.sticker), in: RoundedRectangle(cornerRadius: 8))
          .rotationEffect(.degrees(-2.5))
          .padding(.top, 10)
      }
      .frame(maxWidth: 1000, alignment: .leading)
      if slide.kind == "summary", let posters = slide.posters, !posters.isEmpty {
        LazyVGrid(columns: [GridItem(.fixed(200), spacing: 16), GridItem(.fixed(200), spacing: 16)], spacing: 16) {
          ForEach(Array(posters.prefix(4).enumerated()), id: \.offset) { _, poster in
            TVArtworkView(artwork: poster, width: 320)
              .frame(width: 200, height: 300)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
        }
      } else if let poster = slide.poster {
        TVArtworkView(artwork: poster, width: 640)
          .frame(width: 340, height: 510)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .rotationEffect(.degrees(-3))
          .shadow(color: .black.opacity(0.35), radius: 24, y: 16)
      }
    }
    .padding(.horizontal, 120)
    .id(index)
    .transition(.opacity)
  }

  private func bars(count: Int, accent: TVWrapped.Accent) -> some View {
    VStack {
      HStack(spacing: 8) {
        ForEach(0..<count, id: \.self) { at in
          GeometryReader { geometry in
            Capsule().fill(Color(wrappedHex: accent.ink).opacity(0.28))
              .overlay(alignment: .leading) {
                Capsule().fill(Color(wrappedHex: accent.ink))
                  .frame(width: geometry.size.width * (at < index ? 1 : at == index ? progress : 0))
              }
          }
          .frame(height: 5)
        }
      }
      .padding(.horizontal, 120).padding(.top, 50)
      .accessibilityHidden(true)
      Spacer()
      if held {
        Label("Paused · Play/Pause continues", systemImage: "pause.fill")
          .font(.system(size: 22, weight: .semibold)).padding(.bottom, 50)
      }
    }
  }

  private func go(forward: Bool) {
    guard let count = wrapped?.slides.count else { return }
    guard let next = TVWrapped.step(from: index, count: count, forward: forward) else {
      return dismiss()
    }
    progress = 0
    index = next
  }

  /// Counts the number up, then runs the bar; Play/Pause stops it where it is.
  private func run() async {
    guard let slides = wrapped?.slides, slides.indices.contains(index) else { return }
    let slide = slides[index]
    if progress == 0, !reduceMotion, let target = TVWrapped.countTarget(slide.bigNumber), target > 1 {
      let start = Date()
      while !Task.isCancelled {
        let fraction = Date().timeIntervalSince(start) / 1.1
        shownNumber = String(TVWrapped.countValue(target, fraction: fraction))
        if fraction >= 1 { break }
        try? await Task.sleep(for: .milliseconds(30))
      }
    }
    shownNumber = nil
    guard !reduceMotion, !held else { return }
    while !Task.isCancelled && progress < 1 {
      try? await Task.sleep(for: .milliseconds(50))
      if Task.isCancelled { return }
      progress = min(1, progress + 0.05 / TVWrapped.slideSeconds)
    }
    if !Task.isCancelled { go(forward: true) }
  }

  private func load() async {
    guard wrapped == nil, let client = model.client else { return }
    do {
      wrapped = try await client.wrapped(year: launch.year, month: launch.month)
    } catch {
      self.error = error.localizedDescription
    }
  }
}
