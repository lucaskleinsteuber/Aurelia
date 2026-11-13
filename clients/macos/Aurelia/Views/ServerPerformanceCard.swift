import SwiftUI

/// Settings › Server › Performance: what the server measured about itself. Response times per
/// endpoint and slow database queries of the last days, so "is it faster?" has an answer.
struct ServerPerformanceCard: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var performance: ServerPerformanceResponse?
  @State private var message: String?
  @State private var showsQueries = false
  @State private var resetting = false

  var body: some View {
    Group {
      if let performance {
        AureliaSettingsSection(
          "Performance", symbol: "speedometer",
          description:
            "How long the server takes to answer, measured by the server since \(ServerDateText.display(performance.since)). Streams and waiting requests are left out."
        ) {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
              metric("Requests", performance.requests.formatted())
              metric("95 % Answered Within", ServerPerformanceText.duration(performance.p95Milliseconds))
              metric("Slow Queries", "\(performance.slowQueries.filter { !$0.warmUp }.count)")
              Spacer()
              Button("Reset Measurements") { Task { await reset() } }
                .disabled(resetting || model.profile?.user?.role != .owner)
            }
            if performance.endpoints.isEmpty {
              Text("Nothing measured yet.").font(.caption).foregroundStyle(.secondary)
            } else {
              Text("Slowest Endpoints").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                  Text("Endpoint")
                  Text("Requests").gridColumnAlignment(.trailing)
                  Text("Median").gridColumnAlignment(.trailing)
                  Text("95 %").gridColumnAlignment(.trailing)
                  Text("Slowest").gridColumnAlignment(.trailing)
                  Text("Queries").gridColumnAlignment(.trailing)
                }
                .font(.caption2).foregroundStyle(.secondary)
                ForEach(performance.endpoints.prefix(10)) { endpoint in
                  GridRow {
                    Text("\(endpoint.method) \(ServerPerformanceText.route(endpoint.route))")
                      .lineLimit(1).truncationMode(.middle)
                      .help(endpoint.method + " " + endpoint.route)
                    Text(endpoint.count.formatted())
                    Text(ServerPerformanceText.duration(endpoint.medianMilliseconds))
                    Text(ServerPerformanceText.duration(endpoint.p95Milliseconds))
                      .foregroundStyle(
                        endpoint.p95Milliseconds >= Double(performance.slowRequestMilliseconds)
                          ? .orange : .primary)
                    Text(ServerPerformanceText.duration(endpoint.maxMilliseconds))
                    Text(String(format: "%.1f", endpoint.queriesPerRequest))
                  }
                  .font(.caption.monospacedDigit())
                }
              }
            }
            if !performance.slowQueries.isEmpty {
              DisclosureGroup(
                "Slow Database Queries (\(performance.slowQueries.count), over \(performance.slowQueryMilliseconds) ms)",
                isExpanded: $showsQueries
              ) {
                VStack(alignment: .leading, spacing: 8) {
                  ForEach(performance.slowQueries.prefix(50)) { query in
                    VStack(alignment: .leading, spacing: 2) {
                      HStack {
                        Text("\(ServerPerformanceText.duration(query.milliseconds)) · \(query.kind)")
                          .font(.caption.weight(.semibold))
                        if query.warmUp {
                          Text("while starting").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ServerDateText.display(query.at)).font(.caption2)
                          .foregroundStyle(.secondary)
                      }
                      if let endpoint = query.endpoint {
                        Text(endpoint).font(.caption2).foregroundStyle(.secondary)
                      }
                      Text(query.statement).font(.caption2.monospaced()).textSelection(.enabled)
                        .lineLimit(4)
                    }
                  }
                }
                .padding(.top, 6)
              }
              .font(.caption)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .task(id: model.administrationGeneration) { await load() }
  }

  private func metric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value).font(.callout.weight(.semibold)).monospacedDigit()
      Text(title).font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func load() async {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    do {
      performance = try await model.currentAdministration {
        try await scope.request { try await client.serverPerformance() }
      }
      message = nil
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      performance = nil
    } catch {
      message = scope.message(for: error)
    }
  }

  private func reset() async {
    resetting = true
    defer { resetting = false }
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    do {
      try await model.currentAdministration {
        try await scope.request { try await client.resetServerPerformance() }
      }
      await load()
    } catch {
      message = scope.message(for: error)
    }
  }
}
