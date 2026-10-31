import Charts
import SwiftUI

/// What this profile watched, grouped by day, newest first. Swipe to remove one entry.
struct IOSWatchHistoryView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var items: [IOSWatchHistoryItem] = []
  @State private var total = 0
  @State private var loading = true
  @State private var loadingMore = false
  @State private var error: String?
  @State private var confirmClear = false

  var body: some View {
    List {
      ForEach(IOSWatchTime.days(items), id: \.title) { day in
        Section(day.title) {
          ForEach(day.items) { item in
            IOSHistoryRow(item: item)
              .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
              .swipeActions {
                Button("Remove", systemImage: "trash", role: .destructive) {
                  Task { await remove(item) }
                }
              }
          }
        }
      }
      if loadingMore {
        ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .overlay {
      if loading && items.isEmpty {
        ProgressView()
      } else if let error, items.isEmpty {
        ContentUnavailableView {
          Label("History Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("Try Again") { Task { await load() } }
        }
      } else if items.isEmpty {
        ContentUnavailableView(
          "No History Yet", systemImage: "clock",
          description: Text("Titles you watch on any device appear here."))
      }
    }
    .navigationTitle("Watch History")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !items.isEmpty {
        Button("Clear", role: .destructive) { confirmClear = true }
          .accessibilityIdentifier("history-clear")
      }
    }
    .confirmationDialog(
      "Clear the whole watch history of this profile?", isPresented: $confirmClear,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) { Task { await clear() } }
    } message: {
      Text("Progress and watched marks stay as they are.")
    }
    .refreshable { await load() }
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

  private func remove(_ item: IOSWatchHistoryItem) async {
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

private struct IOSHistoryRow: View {
  let item: IOSWatchHistoryItem
  var body: some View {
    HStack(spacing: 12) {
      IOSArtworkView(
        artwork: item.poster, width: 320, symbol: item.kind == "episode" ? "tv" : "film"
      )
      .frame(width: 40, height: 60)
      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
        if let eyebrow = item.eyebrow, !eyebrow.isEmpty {
          Text(eyebrow).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        HStack(spacing: 6) {
          if item.isCompleted {
            Text("\(Image(systemName: "checkmark.circle.fill")) Finished")
          } else {
            IOSProgressBar(fraction: item.fraction).frame(width: 44)
          }
          Text("· \(IOSWatchTime.text(seconds: Int(item.secondsWatched)))")
          if let date = item.watchedDate {
            Text("· \(date.formatted(date: .omitted, time: .shortened))")
          }
        }
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

/// Watch time, streaks, the last weeks as a chart, favorite titles and genres and a year in
/// review, for this profile.
struct IOSStatisticsView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var stats: IOSUserStatistics?
  @State private var review: IOSYearInReview?
  @State private var year = Calendar.current.component(.year, from: Date())
  @State private var error: String?

  var body: some View {
    ScrollView {
      if let stats {
        VStack(alignment: .leading, spacing: 28) {
          LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
          ) {
            tile("Total", IOSWatchTime.text(hours: stats.totalHoursWatched), symbol: "clock")
            tile(
              "Last 7 Days", IOSWatchTime.text(hours: stats.hoursPast7Days ?? 0),
              symbol: "calendar")
            tile(
              "Current Streak", days(stats.currentStreakDays ?? 0), symbol: "flame")
            tile(
              "Finished", "\(Int(((stats.completionRate ?? 0)).rounded())) %",
              symbol: "checkmark.circle")
          }
          .padding(.horizontal, IOSDesign.margin)
          weeks(stats.hoursByWeek ?? [])
          ranking("Top Titles", stats.topTitles ?? [])
          ranking("Top Genres", stats.topGenres ?? [])
          yearInReview(stats.yearsAvailable ?? [])
        }
        .padding(.vertical, 16)
      } else if let error {
        ContentUnavailableView {
          Label("Statistics Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("Try Again") { Task { await load() } }
        }
        .padding(.top, 80)
      } else {
        ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
      }
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Statistics")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
    .task(id: year) { await loadReview() }
  }

  private func tile(_ title: String, _ value: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol).font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func weeks(_ periods: [IOSPeriodHours]) -> some View {
    let points = periods.suffix(12).compactMap { period in
      IOSWatchTime.weekStart(period.period).map { (week: $0, hours: period.hours) }
    }
    if !points.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        IOSSectionHeader(title: "Last Weeks")
        Chart(points, id: \.week) { point in
          BarMark(
            x: .value("Week", point.week, unit: .weekOfYear),
            y: .value("Hours", point.hours)
          )
          .foregroundStyle(.white.opacity(0.85))
          .cornerRadius(3)
        }
        .chartYAxis {
          AxisMarks { value in
            AxisGridLine().foregroundStyle(.white.opacity(0.1))
            AxisValueLabel {
              if let hours = value.as(Double.self) { Text(IOSWatchTime.text(hours: hours)) }
            }
          }
        }
        .chartXAxis {
          AxisMarks(values: .stride(by: .weekOfYear, count: 3)) {
            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
          }
        }
        .frame(height: 170)
        .padding(.horizontal, IOSDesign.margin)
        .accessibilityLabel("Watch time in the last weeks")
      }
    }
  }

  @ViewBuilder
  private func ranking(_ title: String, _ entries: [IOSNamedCount]) -> some View {
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        IOSSectionHeader(title: title)
        VStack(spacing: 0) {
          ForEach(Array(entries.prefix(5).enumerated()), id: \.offset) { index, entry in
            HStack(spacing: 12) {
              Text("\(index + 1)").font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 18)
              Text(entry.name).font(.subheadline).lineLimit(1)
              Spacer(minLength: 8)
              Text(
                entry.hours.map { IOSWatchTime.text(hours: $0) }
                  ?? (entry.count == 1 ? "1 time" : "\(entry.count) times")
              )
              .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            if index < min(entries.count, 5) - 1 {
              Divider().padding(.leading, 44)
            }
          }
        }
        .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, IOSDesign.margin)
      }
    }
  }

  @ViewBuilder
  private func yearInReview(_ years: [Int]) -> some View {
    if !years.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Year in Review").font(.title3.weight(.bold))
          Spacer()
          Picker("Year", selection: $year) {
            ForEach(years.sorted(by: >), id: \.self) { Text(String($0)).tag($0) }
          }
          .tint(.white)
        }
        .padding(.horizontal, IOSDesign.margin)
        if let review {
          LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
          ) {
            tile(
              "Watch Time", IOSWatchTime.text(hours: review.totalHoursWatched ?? 0),
              symbol: "clock")
            tile("Titles", "\(review.titlesWatched ?? 0)", symbol: "film.stack")
            tile("Movies", "\(review.moviesWatched ?? 0)", symbol: "film")
            tile("Episodes", "\(review.episodesWatched ?? 0)", symbol: "tv")
          }
          .padding(.horizontal, IOSDesign.margin)
          if let top = review.topTitle {
            Label("Most watched: \(top)", systemImage: "star").font(.subheadline)
              .foregroundStyle(.secondary).padding(.horizontal, IOSDesign.margin)
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

/// Sets, changes or turns off this profile's PIN.
struct IOSProfilePINView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  @State private var hasPIN: Bool?
  @State private var current = ""
  @State private var new = ""
  @State private var confirm = ""
  @State private var working = false
  @State private var message: String?
  @State private var failed = false

  private var mayTurnOff: Bool { model.session?.user.role == "user" }
  private var canSave: Bool {
    IOSProfilePIN.isValid(new) && new == confirm && (hasPIN != true || !current.isEmpty)
      && !working
  }

  var body: some View {
    form
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle("Profile PIN")
      .navigationBarTitleDisplayMode(.inline)
      .overlay { if hasPIN == nil { ProgressView() } }
      .onChange(of: new) { _, value in new = Self.digits(value) }
      .onChange(of: confirm) { _, value in confirm = Self.digits(value) }
      .onChange(of: current) { _, value in current = Self.digits(value) }
      .task { await load() }
  }

  private static func digits(_ value: String) -> String {
    String(value.filter { $0.isASCII && $0.isNumber }.prefix(8))
  }

  private var form: some View {
    Form {
      if hasPIN == true {
        Section("Current PIN") {
          SecureField("Current PIN", text: $current).keyboardType(.numberPad)
            .textContentType(.password).accessibilityIdentifier("pin-current")
        }
      }
      Section {
        SecureField("New PIN", text: $new).keyboardType(.numberPad)
          .textContentType(.newPassword).accessibilityIdentifier("pin-new")
        SecureField("Confirm New PIN", text: $confirm).keyboardType(.numberPad)
          .textContentType(.newPassword).accessibilityIdentifier("pin-confirm")
      } header: {
        Text(hasPIN == true ? "New PIN" : "PIN")
      } footer: {
        if let message {
          Text(message).foregroundStyle(failed ? .orange : .secondary)
        } else if !confirm.isEmpty, new != confirm {
          Text("The PINs do not match.").foregroundStyle(.orange)
        } else {
          Text("Four to eight digits. The PIN is asked for when this profile is chosen.")
        }
      }
      Section {
        Button(hasPIN == true ? "Change PIN" : "Set PIN") { Task { await save() } }
          .disabled(!canSave).accessibilityIdentifier("pin-save")
        if hasPIN == true, mayTurnOff {
          Button("Turn Off PIN", role: .destructive) { Task { await turnOff() } }
            .disabled(current.isEmpty || working)
        }
      }
    }
  }

  private func load() async {
    guard let client = model.client, let id = model.session?.user.id else { return }
    let profiles = try? await client.profiles()
    hasPIN = profiles?.profiles.first { $0.id == id }?.pinProtectionEnabled ?? true
  }

  private func save() async {
    guard let client = model.client else { return }
    working = true
    defer { working = false }
    do {
      try await client.changeProfilePIN(current: hasPIN == true ? current : nil, new: new)
      dismiss()
    } catch {
      failed = true
      message = error.localizedDescription
    }
  }

  private func turnOff() async {
    guard let client = model.client else { return }
    working = true
    defer { working = false }
    do {
      try await client.removeProfilePIN(current: current)
      dismiss()
    } catch {
      failed = true
      message = error.localizedDescription
    }
  }
}
