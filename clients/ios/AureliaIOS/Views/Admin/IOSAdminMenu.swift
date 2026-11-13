import SwiftUI

/// Wake-on-LAN for the saved server, shown in Settings › Server.
struct IOSWakeOnLanRows: View {
  @EnvironmentObject private var model: IOSAppModel

  var body: some View {
    let status = model.wakeOnLanStatus
    LabeledContent("Wake-on-LAN") {
      Text(status.summary).multilineTextAlignment(.trailing)
    }
    .accessibilityIdentifier("settings-wake-status")
    if status.canWake {
      Button {
        model.sendWakeSignal()
      } label: {
        Label("Send Wake Signal", systemImage: "power")
      }
      .accessibilityIdentifier("settings-wake-send")
    }
  }
}
