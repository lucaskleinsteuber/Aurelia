import Foundation
import Testing

@testable import Aurelia

@MainActor struct SettingsReviewFixTests {
  private func settings(revision: Int64 = 1) -> ServerPolicySettings {
    ServerPolicySettings(
      version: 1, serverName: "Test Server", lanAccessEnabled: false, lanHttpsPort: 43_111,
      revision: revision, pairingEnabled: true, deviceSessionDays: 30, globalStreamLimit: 8,
      userStreamLimit: 3, bonjourEnabled: true, allowedNetworks: nil, monitoringEnabled: true,
      reconciliationMinutes: 360, maintenanceStartHour: 2, maintenanceEndHour: 6,
      jobQueueLimit: 100, automaticBackupsEnabled: true, backupIntervalHours: 24,
      dailyBackupsRetained: 7, weeklyBackupsRetained: 4, eventRetentionDays: 14,
      maximumEvents: 1_000)
  }

  @Test func unchangedDraftFollowsTheServer() {
    var draft = ServerSettingsDraft(settings())
    var latest = settings(revision: 2)
    latest.backupIntervalHours = 12
    draft.follow(latest)
    #expect(draft.value == latest)
    #expect(!draft.isDirty)
  }

  @Test func anotherBoxSavingKeepsThisBoxsEdits() {
    var draft = ServerSettingsDraft(settings())
    draft.value.dailyBackupsRetained = 10
    var latest = settings(revision: 2)
    latest.pairingEnabled = false
    draft.follow(latest)
    #expect(draft.isDirty)
    #expect(draft.value.dailyBackupsRetained == 10)
    #expect(draft.value.pairingEnabled == false)
    #expect(draft.value.revision == 2)
  }

  @Test func savingSendsTheLatestSettingsWithOnlyThisBoxsChanges() {
    var draft = ServerSettingsDraft(settings())
    draft.value.eventRetentionDays = 30
    var latest = settings(revision: 3)
    latest.serverName = "Renamed"
    latest.jobQueueLimit = 200
    let sent = draft.merged(onto: latest)
    #expect(sent.eventRetentionDays == 30)
    #expect(sent.serverName == "Renamed")
    #expect(sent.jobQueueLimit == 200)
    #expect(sent.revision == 3)
  }

  @Test func savedChangesLeaveTheDraftClean() {
    var draft = ServerSettingsDraft(settings())
    draft.value.weeklyBackupsRetained = 8
    var saved = settings(revision: 2)
    saved.weeklyBackupsRetained = 8
    draft.follow(saved)
    #expect(!draft.isDirty)
    #expect(draft.value == saved)
  }
}
