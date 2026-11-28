import Foundation
import Testing

@testable import Tarven

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

  @Test func settingsErrorBannerDeduplicatesPageAndSectionErrors() {
    #expect(
      SettingsErrorBannerPolicy.topError(
        category: .server, administrationError: "The server could not be reached.",
        modelError: "Fallback error") == "The server could not be reached.")
    #expect(
      SettingsErrorBannerPolicy.topError(
        category: .updates, administrationError: "The server could not be reached.",
        modelError: "Model error") == nil)
    #expect(
      SettingsErrorBannerPolicy.topError(
        category: .general, administrationError: "   ", modelError: "Offline") == "Offline")

    #expect(
      !SettingsErrorBannerPolicy.shouldShowSectionError(
        "The server could not be reached.",
        pageAdministrationError: "The server could not be reached.",
        pageModelError: nil))
    #expect(
      SettingsErrorBannerPolicy.shouldShowSectionError(
        "Backup directory is read-only.",
        pageAdministrationError: "The server could not be reached.",
        pageModelError: nil))
    #expect(
      !SettingsErrorBannerPolicy.shouldShowSectionError(
        nil, pageAdministrationError: nil, pageModelError: nil))
  }

  @Test func playbackPickerNormalizationSnapsLegacyValuesToMenuChoices() {
    #expect(SettingsChoiceNormalization.autoHideDelay(3.0) == 3.0)
    #expect(SettingsChoiceNormalization.autoHideDelay(4.2) == 5.0)
    #expect(SettingsChoiceNormalization.autoHideDelay(0.5) == 2.0)
    #expect(SettingsChoiceNormalization.autoHideDelay(20.0) == 8.0)

    #expect(SettingsChoiceNormalization.seekInterval(15) == 15)
    #expect(SettingsChoiceNormalization.seekInterval(12) == 10)
    #expect(SettingsChoiceNormalization.seekInterval(18) == 20)
    #expect(SettingsChoiceNormalization.seekInterval(90) == 60)
  }

  @Test func subtitleLanguageSelectionEnforcesOneToFiveBounds() {
    #expect(!SubtitleLanguageSelection.canToggle(code: "en", in: ["en"]))
    #expect(SubtitleLanguageSelection.toggled(code: "en", in: ["en"]) == nil)

    let five = ["en", "de", "fr", "es", "it"]
    #expect(!SubtitleLanguageSelection.canToggle(code: "ja", in: five))
    #expect(SubtitleLanguageSelection.toggled(code: "ja", in: five) == nil)
    #expect(SubtitleLanguageSelection.canToggle(code: "fr", in: five))
    #expect(SubtitleLanguageSelection.toggled(code: "fr", in: five) == ["en", "de", "es", "it"])
    #expect(SubtitleLanguageSelection.toggled(code: "de", in: ["en"]) == ["en", "de"])
  }

  @Test func stateLabelsAvoidCamelCaseCapitalizedArtifacts() {
    #expect(TarvenStateLabels.hostState(.setupRequired) == "Setup Required")
    #expect(TarvenStateLabels.hostState(.running) == "Running")
    #expect(TarvenStateLabels.libraryAvailability(.error) == "Access Error")
    #expect(TarvenStateLabels.libraryAvailability(.available) == "Available")
    #expect(TarvenStateLabels.userRole(.admin) == "Administrator")
    #expect(TarvenStateLabels.userRole(.owner) == "Owner")
  }
}
