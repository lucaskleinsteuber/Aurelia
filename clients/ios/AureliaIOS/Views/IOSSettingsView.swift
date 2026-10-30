import SwiftUI

public struct IOSSettingsView: View {
  @ObservedObject var model: IOSAppModel
  @State private var showProfilePicker = false

  public init(model: IOSAppModel) {
    self.model = model
  }

  public var body: some View {
    NavigationStack {
      List {
        // Profile Section
        Section("Profile") {
          HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
              .font(.system(size: 40))
              .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 2) {
              Text(model.currentProfile?.name ?? "No Profile")
                .font(.headline)
              if model.currentProfile?.isAdmin == true {
                Text("Administrator")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            Spacer()

            Button("Switch") {
              showProfilePicker = true
            }
            .buttonStyle(.bordered)
            .tint(.white)
          }
          .padding(.vertical, 4)
        }

        // Activity Section
        Section("Activity") {
          NavigationLink {
            IOSHistoryView(model: model)
          } label: {
            Label("Watch History", systemImage: "clock.arrow.circlepath")
          }

          NavigationLink {
            IOSStatisticsView(model: model)
          } label: {
            Label("Statistics", systemImage: "chart.bar.xaxis")
          }
        }

        // Server Connection Section
        Section("Server Connection") {
          HStack {
            Text("Server")
            Spacer()
            Text(model.serverInfo?.name ?? model.storedConnection?.serverName ?? "Aurelia")
              .foregroundStyle(.secondary)
          }

          HStack {
            Text("Version")
            Spacer()
            Text(model.serverInfo?.version ?? "Unknown")
              .foregroundStyle(.secondary)
          }

          HStack {
            Text("Status")
            Spacer()
            HStack(spacing: 6) {
              Circle()
                .fill(model.isOffline ? Color.red : Color.green)
                .frame(width: 8, height: 8)
              Text(model.isOffline ? "Offline" : "Connected")
                .foregroundStyle(model.isOffline ? .red : .secondary)
            }
          }

          if let fp = model.storedConnection?.fingerprint {
            HStack {
              Text("Fingerprint")
              Spacer()
              Text(String(fp.prefix(16)) + "…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }

        // Playback Defaults Section
        Section("Playback Defaults") {
          HStack {
            Text("Skip Interval")
            Spacer()
            Text("10 seconds")
              .foregroundStyle(.secondary)
          }

          HStack {
            Text("Up Next Countdown")
            Spacer()
            Text("15 seconds")
              .foregroundStyle(.secondary)
          }

          HStack {
            Text("Auto-Play Next Episode")
            Spacer()
            Text("On")
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Settings")
      .sheet(isPresented: $showProfilePicker) {
        IOSProfilePickerView(model: model)
      }
    }
  }
}
