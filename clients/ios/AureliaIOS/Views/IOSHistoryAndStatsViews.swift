import SwiftUI

public struct IOSHistoryView: View {
  @ObservedObject var model: IOSAppModel
  @State private var events: [IOSWatchEvent] = []
  @State private var isLoading = false

  public init(model: IOSAppModel) {
    self.model = model
  }

  public var body: some View {
    List {
      if events.isEmpty && !isLoading {
        Text("No watch history yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(events) { event in
          HStack(spacing: 12) {
            IOSAsyncImage(urlString: event.posterUrl, aspectRatio: 2 / 3)
              .frame(width: 50, height: 75)
              .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
              Text(event.title)
                .font(.subheadline.bold())

              Text(event.watchedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .navigationTitle("Watch History")
    .task {
      isLoading = true
      if let resp = try? await model.apiClient.getWatchHistory() {
        events = resp.events
      }
      isLoading = false
    }
  }
}

public struct IOSStatisticsView: View {
  @ObservedObject var model: IOSAppModel
  @State private var stats: IOSPersonalStatisticsResponse?
  @State private var isLoading = false

  public init(model: IOSAppModel) {
    self.model = model
  }

  public var body: some View {
    ScrollView {
      if let stats {
        VStack(spacing: 18) {
          // Watch Time Grid
          HStack(spacing: 12) {
            metricCard(
              title: "All Time", value: String(format: "%.1fh", stats.totalHours),
              subtitle: "Hours watched")
            metricCard(
              title: "This Month", value: String(format: "%.1fh", stats.monthHours),
              subtitle: "Hours watched")
            metricCard(
              title: "This Week", value: String(format: "%.1fh", stats.weekHours),
              subtitle: "Hours watched")
          }

          // Streaks
          HStack(spacing: 12) {
            metricCard(
              title: "Current Streak", value: "\(stats.currentStreakDays)d",
              subtitle: "Consecutive days")
            metricCard(
              title: "Longest Streak", value: "\(stats.longestStreakDays)d",
              subtitle: "Personal best")
          }

          // Top Genres
          if !stats.topGenres.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              Text("Top Genres")
                .font(.headline)
              HStack {
                ForEach(stats.topGenres, id: \.self) { genre in
                  Text(genre)
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(Capsule())
                }
              }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
          }
        }
        .padding(16)
      } else if isLoading {
        ProgressView()
          .padding(.top, 40)
      }
    }
    .navigationTitle("Statistics")
    .task {
      isLoading = true
      stats = try? await model.apiClient.getPersonalStatistics()
      isLoading = false
    }
  }

  private func metricCard(title: String, value: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title2.bold())
      Text(subtitle)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}
