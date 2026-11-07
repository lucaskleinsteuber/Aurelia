# Aurelia for Linux: Mac feature inventory

This inventory compares the current Mac app in `clients/macos/Aurelia` with the independent Linux
app in `clients/linux`. It was reviewed on 2026-11-01. The shared server and contracts supply the
same library and account behavior; interface code and platform adapters remain independent.

Each row describes a user-visible capability rather than a source file. A named test identifies
the scenario it exercises, not proof of every interaction in that row. “Source review” means the
implementation exists but has no dedicated automated assertion yet. Headless tests draw the real
Avalonia views without opening desktop windows. Integration tests use the real server with
synthetic accounts and media; simulated player tests never load a real decoder. Desktop, package,
portal and physical playback checks must be reported separately with the release verification.

In the tables, UI test names are in `Aurelia.Linux.Tests`; server integration test names are in
`Aurelia.Linux.IntegrationTests`. Linux paths are relative to `clients/linux`. This document is a
source and coverage map; private test receipts record which tests actually ran for a release.

## Window and navigation

| Mac capability | Linux counterpart | Coverage and limits |
| --- | --- | --- |
| Full-height content beneath window chrome | `Views/MainWindow`, `Controls/AppWindowBehavior` | `WindowTests.TheTopBandMovesTheWindow`; Wayland/X11 compositor behavior needs desktop launch checks. |
| Native close, minimize, maximize and full screen | `Controls/WindowChrome`, desktop button layout, F11 | `WindowTests.WindowButtonsFollowTheDesktopLayout`, `MaximizeButtonTogglesAndRelabels`, `FullScreenHidesTheButtons`; Linux follows the desktop's layout. |
| Dark blurred sidebar with opaque accessibility fallback | `Controls/SidebarBackground`, Reduce Transparency | `ShellTests.SidebarBlursWhatPassesBeneathItAndCanBeOpaque`. |
| Content passes beneath the sidebar while labels remain beside it | `Views/LibraryShell`, page leading insets | `ShellTests.PagesRunBeneathTheSidebarAndStartBesideIt`. |
| Sidebar resize and show/hide | Sidebar width 210–300, F9 | `WindowTests.SidebarWidthStaysBetweenTheMacLimits`, `SidebarToggleMovesBesideLeftWindowButtons`. |
| Saved sidebar order, hidden pages and default start page | `Settings/GeneralPreferences`, `SettingsView` Sidebar | `LibraryLogicTests.TheSidebarLayoutIsSavedAndReset`, `SettingsViewTests.TheSidebarPagesCanBeHiddenAndMovedButOneStays`. |
| Reopen an already running app, including a hidden host | `Core/Platform/AppInstance`, same-user pipe and exclusive app lock | `AppInstanceTests.ASecondLaunchRaisesTheExistingWindowWithoutStartingAnotherOwner`, `AnEarlyShowRequestWaitsForTheWindowCallback`; native startup script can verify a second background invocation. |
| Start reliably without preinstalled system fonts | Bundled Inter is also the startup font; native packages declare fallback fonts | Container startup is the release regression check; the application uses the same font assets on every distribution. |
| Keep the current page when navigating | `Views/LibraryShell` page cache and detail stack | `ShellTests.SwitchingPagesKeepsEachPageAlive`; Alt+Left/Esc back behavior is source reviewed. |
| Keyboard sidebar navigation and library search shortcut | Arrow keys, Ctrl+F | `ShellTests.KeyboardMovesThroughTheSidebar`, `ControlFLeadsToTheLibrarySearch`. |
| Keyboard shortcuts help | Ctrl+/ sheet in `Views/LibraryShell` | Source review; Linux uses Ctrl where Mac uses Command. |
| Reduce Motion | Stored preference in `SettingsView`; Linux pages use immediate transitions | `SettingsViewTests.GeneralSettingsAreSavedAtOnce`; Mac hero sliding/zoom animations are platform-specific presentation. |

## Connection and profiles

| Mac capability | Linux counterpart | Coverage and limits |
| --- | --- | --- |
| Remember host/client mode and show the welcome choice | `Flow/AppFlow`, `Views/WelcomeView` | `AppFlowTests.StartsThenAsksWhereTheServerRuns`, `RemembersTheChosenMode`; `WindowTests.ChoosingAModeOpensItsScreenAndBackReturns`. |
| Discover nearby servers, including legacy service advertisements | `Connection/ServerDiscovery`, `DiscoveryCache` | `DiscoveryMergeTests.ListsEachServerOnceSortedByName`; `DiscoveryLifecycleTests` covers offline startup, cleanup, background retry and manual entry. Real multicast discovery is a desktop/network check. |
| Typed HTTPS address and default port | `Api/ServerAddress`, `Views/ConnectionView` | `ServerAddressTests.NormalizesTypedAddresses`, `RejectsUnsafeOrUnclearAddresses`. |
| Compare fingerprint and pair using an eight-digit code | `Flow/ConnectionModel`, `Api/AureliaApi` | `SetupScreenTests.PairsChoosesAProfileAndOpensTheLibrary`; `ConnectionFlowTests.PairsOpensTheOwnerProfileAndDisconnects`. |
| Pin the trusted key on later requests | `Api/PinnedServerTransport`, `ServerIdentity` | `ConnectionFlowTests.RefusesAServerWithAnotherIdentity`; `ServerIdentityTests.FingerprintIsTheHashOfTheP256PublicKey`. |
| Keep device credentials in secure OS storage | Secret Service, no plain-file fallback | `StoredConnectionTests.RoundTripsThroughTheKeyringFormat`; `KeyringTests.SavesReplacesReadsAndDeletesAnEntry` is opt-in on a real Linux desktop. |
| Wake a sleeping server and stop waiting | `Connection/ServerWakeUp`, `WakeOnLan`, Starting view | `WakeOnLanTests.BuildsTheMagicPacket`; `SetupScreenTests.ASilentServerOffersToTryAgain`. Network wake and desktop reachability are separate checks. |
| Follow a known server at a new advertised address | Same server id and trusted key in `ServerWakeUp` | Source review; no dedicated live multicast relocation test. |
| Initialize profiles with Server Password and owner PIN | `Flow/ProfilePickerModel`, `Views/ProfilePickerView` | `SetupScreenTests.AServerThatNeedsProfilesAsksForThePasswordAndPin`; `ConnectionFlowTests.SetsUpProfilesForTheFirstTime`. |
| Choose a profile, check PIN, show failures | Profile picker, PIN 4–8 digits | `ConnectionFlowTests.ReportsAWrongCodeAndAWrongPin`; `SetupScreenTests.PairsChoosesAProfileAndOpensTheLibrary`. |
| Limit viewing sessions and return to profile picker after restart | `Flow/AppSession` timer and authentication handling | `ConnectionFlowTests.TheScreensLeadFromConnectingToTheLibraryAndBackAfterARestart`; timer logic is source reviewed. |
| Switch profile and change its own PIN | Settings → Profiles and Devices | `SettingsViewTests.ChangingTheOwnPinChecksTheEntryAndLocksTheProfile`. |
| Disconnect this computer without removing server data | Advanced → Disconnect This PC | `SettingsViewTests.DisconnectingAsksFirstAndForgetsTheServer`; `ConnectionFlowTests.PairsOpensTheOwnerProfileAndDisconnects`. |
| Let a remote server rest when unused, wake on input | `Flow/AppSession.Rest`, main window idle policy | `SettingsViewTests.TheServerRestsWhenUnusedAndAnyInputContinues`, `RestFollowsTheMacRules`. |

## Library and activity

| Mac capability | Linux counterpart | Coverage and limits |
| --- | --- | --- |
| Home recommendation hero | `Library/HomePage` | `ShellTests` renders Home; `LibraryFlowTests.LoadsHomeTheCatalogAndPagesWithFiltersAndSearch` verifies the response. |
| Refresh the recommendation at its scheduled deadline | `Core/Library/RecommendationRefresh` | `HomeRefreshTests.RecommendationsRefreshAtTheirDeadlineWithoutASyncChangeAndStopAtRest`, `AHomeChangeReschedulesAnEarlierRecommendationDeadline`. |
| Continue Watching, genre rows, Favorites, Collections, Recently Added | `Library/HomePage`, `LibraryPresentation` | `LibraryLogicTests.GenreRowsAreTheFirstThreeGenresAlphabetically`, `RowsHideWatchedAndOfflineTitlesByTheSettings`; Home rendering in `ShellTests`. |
| Library, Movies, TV Shows and Recently Added pages | `Library/BrowsePage`, `Core/Library/BrowseQuery` | `LibraryLogicTests.PagesKeepTheirKindAndRecentlyAddedSortsNewestFirst`; `LibraryScreenTests.MoviesShowPostersAndFiltersReachTheServer`. |
| Search, kind/genre/year/favorite/watch-state filters and sort | `Core/Library/BrowseModel`, `BrowseQuery` | `LibraryLogicTests.BrowseQueriesUseTheServersParameterNames`; `LibraryFlowTests.LoadsHomeTheCatalogAndPagesWithFiltersAndSearch`. |
| Remember queries per server, profile and page | General preferences and browse cache | `LibraryLogicTests.PreferencesRememberPagesPerServerAndProfile`; cache behavior is source reviewed. |
| Revision-safe catalog paging | `LibraryClient.BrowseAsync` retries changed snapshots | `LibraryFlowTests.LoadsHomeTheCatalogAndPagesWithFiltersAndSearch`; changed-revision retry is source reviewed. |
| Poster, landscape, collection and person cards with offline/progress badges | `Library/MediaCards` | `LibraryLogicTests.CardsSayWhatKindOfTitleItIs`; rendered library tests. |
| Horizontal rails with whole-card paging and keyboard arrows | `Library/Rail` | Source review and rendered Home; no dedicated paging assertion. |
| Artwork variants and bounded memory/disk cache | `Core/Library/ArtworkCache`, `Controls/ArtworkImage` | `LibraryLogicTests.ArtworkAsksForTheSmallestSharpSize`, `TheArtworkFolderShrinksOldestFirst`. |
| Movie and series detail, seasons, episodes, trailers and extras | `Library/DetailPage` | `LibraryScreenTests.ASeriesPageResumesItsEpisodeAndGoesBack`; `LibraryFlowTests.ShowsASeriesWithItsEpisodesAndMarksItWatched`. |
| Cast/crew and person filmography | `Library/DetailPage`, `PersonPage` | Source review; server endpoints share `LibraryClient.PersonAsync`. |
| Film series and saving one as a collection | `Library/CollectionPages`, franchise endpoints | `LibraryFlowTests.KeepsAWatchlistAndCollections` covers collection API; franchise UI is source reviewed. |
| Standard collections with create/edit/delete and title membership | `CollectionEditorSheet`, `CollectionEditorModel`, `MediaMenu` | `LibraryScreenTests.TheCollectionEditorNeedsTwoTitlesAndSendsThem`; `LibraryFlowTests.KeepsAWatchlistAndCollections`. |
| Smart collection rules and live matching count | `CollectionEditorModel` and editor | `LibraryLogicTests.SmartListRulesUseTheServersCanonicalSpelling`, `AnExistingSmartListOpensWithItsRules`. |
| Watchlist and Favorites | `WatchlistPage`, `MediaMenu`, detail actions | `LibraryFlowTests.KeepsAWatchlistAndCollections`; Favorites request/refresh is source reviewed. |
| Play, resume and Go to Series from context menus | `Library/MediaMenu` | `LibraryScreenTests.TheContextMenuFollowsTheMacOrder`. |
| Mark title/season/series watched or unwatched | Media menu with server-calculated affected count | `LibraryScreenTests.MarkingASeasonAsksWithTheEpisodeCountFirst`; `LibraryFlowTests.ShowsASeriesWithItsEpisodesAndMarksItWatched`. |
| Keep/remove Continue Watching state | `MediaMenu`, `LibraryClient.SetContinueWatchingAsync` | Menu order test and source review; no dedicated mutation assertion. |
| History grouped by day, paging, remove/clear with confirmation | `Library/ActivityPages.HistoryPage` | `LibraryScreenTests.HistoryAndStatisticsShowTheProfilesActivity`, `LibraryLogicTests.HistoryGroupsByDay`; delete/clear handlers are source reviewed. |
| Statistics and year in review | `Library/ActivityPages.StatisticsPage` | `LibraryScreenTests.HistoryAndStatisticsShowTheProfilesActivity`; `LibraryFlowTests.ReadsHistoryStatisticsAndSyncChanges`. |
| Long-poll updates with per-session cursor and selective refresh | `Core/Library/LibrarySync`, `LibraryStore.ApplyChangesAsync` | `LibraryFlowTests.ReadsHistoryStatisticsAndSyncChanges`; cursor persistence and refresh plan are source reviewed. |
| Prepare title details on pointer hover/focus | `MediaCards` → bounded 30-second prepared-detail cache (12 entries, two concurrent preparations) | `PreparedDetailTests.FocusingATitlePreparesItsMetadataWithoutOpeningAVideoStream`, `LeavingATitleBeforeTheDelayCancelsPreparation`, `PreparationIsBoundedReusedAndInvalidatedWhenTheCatalogChanges`. |

## Playback

| Mac capability | Linux counterpart | Coverage and limits |
| --- | --- | --- |
| Obtain ticket and relay authenticated ranges to decoder locally | `PlaybackClient`, `LoopbackStreamRelay` | `PlaybackFlowTests.StreamsThroughTheRelayWithoutTheTokenReachingTheDecoder` uses synthetic bytes, not playback. |
| Start at resume position, optional start over | `PlaybackController`, `PlayerPolicy` | `PlaybackControllerTests.ResumesAtTheSavedPositionThroughTheRelayWithSidecarSubtitles`, `StartsOverWhenAutomaticResumeIsOff`. |
| Video behind controls on Wayland and X11 | VLC frame callbacks → `VideoSurface` | `PlayerViewTests.OpensOverTheLibraryAndShowsTheControls` uses a simulated engine. Actual decode and hardware performance remain the owner's check. |
| Play/pause, seeking, mute, volume, full screen and keyboard controls | `Playback/PlayerView` | `PlayerViewTests.KeysControlPlaybackLikeOnTheMac`. |
| Playback rate, audio/subtitle menus and track language/memory | `PlaybackController`, `PlaybackPreferences.TrackMemory` | `PlayerViewTests.TheMenusListTheTracksAndRates`; `PlaybackControllerTests.UsesRememberedAndDefaultTracks`, `TrackChoicesMatchLanguageCodesFromVlcAndSettings`. |
| Sidecar subtitle files | `PlaybackClient` and engine adapter | `PlaybackControllerTests.ResumesAtTheSavedPositionThroughTheRelayWithSidecarSubtitles`. |
| Night Mode compressor | New VLC engine instance at current position | `PlaybackControllerTests.NightModeReopensTheTitleAtTheSamePosition`. |
| Chapters menu and timeline chapter markers | Engine chapter metadata, player menu and timeline marks | `PlayerViewTests.ChaptersShowAMenuAndTimelineMarkersAndSeekThroughTheEngine` uses a simulated engine. |
| Sleep for minutes or end of episode, notify server | `PlaybackController.SetSleepTimer` | `PlaybackControllerTests.TheSleepTimerEndsPlaybackAndTellsTheServer`, `EndOfEpisodeSleepsInsteadOfPlayingOn`. |
| Previous/next episode and Up Next countdown with cancel | Controller and player card | `PlaybackControllerTests.ASeriesPlaysTheNextEpisodeAtTheNaturalEnd`, `UpNextShowsInTheCountdownAndCancelStopsAtTheEnd`; `PlayerViewTests.TheUpNextCardAppearsNearTheEndOfAnEpisode`. |
| Persist progress every 15 seconds, pause, seek, close and end | `ProgressOutbox`, controller | `PlaybackControllerTests.SavesProgressWithItsRevisionOnPauseAndEveryFifteenSeconds`; disk replay is source reviewed. |
| Progress conflict and explicit replacement | Conflict card, `KeepThisPositionAsync` | `PlaybackControllerTests.AConflictOffersToKeepThisComputersPosition`; `PlaybackFlowTests.SavesProgressWithRevisionsAndReportsAConflict`. |
| Ticket renewal and bounded stall recovery | Controller watchdog | `PlaybackControllerTests.RecoversWithANewTicketAtTheLastPosition`, `GivesUpAfterTheRecoveryBudgetAndOffersTryAgain`; renewal path is source reviewed. |
| Server-generated scrub images | `Playback/PlayerHelpers.ScrubPreviews` | Source review; served through authenticated HTTPS. |
| Local in-memory scrub fallback when the server has no still | Dedicated silent preview decoder and authenticated preview relay | `PlaybackPreviewTests.MissingServerPictureUsesASilentLocalDecoderThroughItsOwnRelay`, `FastPointerMovementCancelsStalePreviewWork`, `ProductionFrameCallbacksCaptureSmallStillsFromABackgroundThread`; no real decode runs in tests. |
| Scene notes, cues and note editor | `SceneNotes`, `SceneNoteCues` | `PlaybackControllerTests.SceneNotesShowOnceForSixSecondsAndNotAfterAJump`; `PlaybackFlowTests.KeepsSceneNotes`. |
| Play On sender and remote control | Detail-page device menu and remote bar | `PlaybackFlowTests.PlayOnSendsAPlayCommandToAnotherPlayer`; remote bar controls are source reviewed. |
| Play On receiver with initial position and pause state | `Core/Playback/PlayOn`, `MainWindow` command handling | `PlayOnReceiverTests.EveryRemoteCommandUsesTheProductionPlayerAndHonorsItsState`, `TheHeartbeatReportsPausedPlaybackThroughTheUiDispatch` use simulated engines through the production window/controller. |
| OS media keys/Now Playing | MPRIS adapter in `Platform/LinuxPlaybackSystem` | Platform counterpart; D-Bus adapter is source reviewed, needs desktop verification. |
| Keep screen awake during playback | ScreenSaver/portal inhibition | Simulated controller tests verify keep-awake state; actual D-Bus permission/inhibitor behavior needs desktop verification. |
| Export playback diagnostics from player/error screen | Bounded sanitized diagnostics collector and save action | `PlaybackPreviewTests.DiagnosticsAreBoundedAndExcludeUnrecognizedErrorText`, `ControllerDiagnosticsRecordActionsAndSanitizeServerFailures`; `PlayerViewTests.ExportsSanitizedDiagnosticsOnlyWhenADestinationIsChosen`. |
| AirPlay route picker | Apple-only framework; Linux exposes Play On and desktop media controls | Platform difference: Aurelia's Linux client does not provide an AirPlay audio-output route picker. |

## App settings and updates

| Mac capability | Linux counterpart | Coverage and limits |
| --- | --- | --- |
| Searchable settings inside the main window | `Settings/SettingsView`, Ctrl+, | `SettingsViewTests.ListsTheCategoriesAndSearchesThem`. |
| General defaults, poster size, watched rows and rest interval | General settings | `SettingsViewTests.GeneralSettingsAreSavedAtOnce`, `RestFollowsTheMacRules`. |
| All playback defaults, forget track choices and restore defaults | Playback settings | `SettingsViewTests.PlaybackSettingsUseTheMacChoices`; `PlaybackControllerTests.PlaybackPreferencesKeepToTheAllowedValues`. |
| Sidebar customization and Activity in settings | Sidebar and Activity categories | `SettingsViewTests.TheSidebarPagesCanBeHiddenAndMovedButOneStays`; Activity embeds the same pages. |
| Own profile, PIN protection and profile switch | Profiles and Devices category | `SettingsViewTests.ChangingTheOwnPinChecksTheEntryAndLocksTheProfile`. |
| Server address, fingerprint and disconnect/switch | Advanced settings, local-host mode switch | `SettingsViewTests.DisconnectingAsksFirstAndForgetsTheServer`; local switch handler is source reviewed. |
| Automatic and manual release checks | `Core/Updates/AppUpdater`, Updates settings | `AppUpdateTests.AutomaticChecksRespectThePreferenceAndDailyInterval`, `SelectsOnlyACompleteNewerLinuxReleaseForTheInstalledPackage`. |
| Private repository credential in secure OS storage | Update-token Secret Service entry | `AppUpdateTests.TheGitHubTokenIsRemovedFromAssetRedirects`; `KeyringTests.UpdateTokensStaySeparateFromThePairedServer` uses isolated real-keyring entries on Linux. |
| Verify package before installing | Exact release asset + SHA-256 manifest | `AppUpdateTests.ChecksumMustIdentifyTheExactPackageOnce`, `NeverStopsTheHostOrInstallsADamagedDownload`. |
| Confirm update and install using the OS package manager | `pkexec` for native packages; Flatpak user update | `AppUpdateTests.VerifiesThenPreparesThenInstallsAndRemovesTheDownload`, `NativeInstallsUsePkexecAndLiteralArguments`; privileged installation needs package/desktop checks. |

## Server and library administration

| Mac capability | Linux counterpart | Coverage and limits |
| --- | --- | --- |
| Role-appropriate management pages | `AdminScope`, settings availability | `ManagementScreenTests.CategoriesFollowTheRole`. Owner-only server requests are hidden from administrators rather than offered as failing actions. |
| Request-bound approval and Server Password unlock on demand | `Core/Management/ManagementClient`, stacked sheets | `ManagementScreenTests.AManagementLockAsksForTheServerPasswordOverTheEditor`; `ManagementFlowTests.ManagesProfilesWithTheServerPasswordWhenAsked`, `AWrongServerPasswordIsReportedAndCancellingStops`. |
| Server summary, health and restart | `Management/ServerPage` | `ManagementScreenTests.TheOwnerSeesAndUsesTheServerSettings`; `HostingFlowTests.SetsUpAndReopensThisComputersServer`. |
| Linux service updates and power saving | Server-page Updates and Power sections | Server settings rendering test; endpoints in `ManagementFlowTests.ReadsTheServerAndSavesSettingsKeepingUnknownFields`. Running a real server update/suspend is outside synthetic tests. |
| Allow new devices and approve browser/TV requests | `PeoplePage`, device approval sheet | `ManagementScreenTests.ProfilesAndDevicesListPeopleAndMakeCodes`; `ManagementFlowTests.PairsDevicesAndListsSessions`. |
| Pairing code, expiry, browser address and device revocation | Profiles and Devices | Same tests cover listing/code creation; revocation and expiry UI are source reviewed. |
| Create/edit/delete profiles, roles, enabled state and title access | `PeoplePage`, `ProfileEditorSheet` | `ManagementScreenTests.ProfilesAndDevicesListPeopleAndMakeCodes`; `ManagementFlowTests.ManagesProfilesWithTheServerPasswordWhenAsked`. |
| Storage folders from the server, multiple folder drafts | `LibraryPage`, `ServerFolderPicker` | `ManagementScreenTests.TheLibrarySettingsShowLocationsAndTheImportPreview`; `ManagementFlowTests.AddsAStorageLocationThroughTheImportPreview`. |
| Preview import, filter/search, edit assignments and confirm revision | `ImportPreviewSheet`, `Core/Management/ImportPreviewModel` | `ManagementScreenTests.ImportAssignmentsFollowTheMacRules`; `ManagementFlowTests.AddsAStorageLocationThroughTheImportPreview`. |
| Rescan, cancel scan, monitoring and remove location without touching files | `LibraryPage` | Source review; import integration exercises scan progress. No automated operation uses personal media. |
| Trailer/import review and metadata review queue | `LibraryPage`, `ReviewQueueSheet` | Source review; metadata settings render in `ManagementScreenTests.TheMetadataSettingsShowTmdb`. |
| Library Health: duplicates, offline, unmatched and excluded | `TitleAdmin.LibraryHealthSheet` | `ManagementFlowTests.ReadsLibraryHealthAndPreviewsAReset`; individual health actions are source reviewed. |
| Hide offline titles while retaining their identity and metadata | General preference and library display policy | `LibraryLogicTests.RowsHideWatchedAndOfflineTitlesByTheSettings`. |
| Reset library with preview, revision and password approval | `ResetLibrarySheet` | `ManagementFlowTests.ReadsLibraryHealthAndPreviewsAReset` covers preview; full reset action is source reviewed. |
| TMDB credential, enrich, jobs, cancel and prune artwork | `TitleAdmin.MetadataPage` | `ManagementScreenTests.TheMetadataSettingsShowTmdb`; management endpoint integration covers provider reads. Mutations requiring external TMDB are not exercised. |
| Edit metadata fields and manual overrides | `MetadataEditorSheet` | `ManagementFlowTests.EditsMetadataAndKeepsManualChanges`; `ManagementScreenTests.EditorRulesCropsAndSmallFormats`. |
| Edit cast/crew, upload/crop artwork and choose source file | Metadata editor, `CropSheet`, `ServerFilePicker` | Crop/rule tests above; complete upload/file-picker interaction is source reviewed. |
| Find metadata match and remove a catalog title without deleting media | `MetadataMatchSheet`, `TitleAdmin.RemoveAsync` | `ManagementScreenTests.TitleMenusOfferAdministratorActions`; `ManagementFlowTests.RemovesATitleKeepsItsFileAndReimportsIt`. |
| Scrub-preview generation mode, interval, cap and removal | Server-page Scrub Previews | Server settings render and endpoint integration test; deleting generated stills is source reviewed. |
| Network changes with 60-second rollback and confirmation on new address | `NetworkSettingsSection`, `Core/Management/NetworkTrial` | `NetworkTrialTests`; `HostingFlowTests.NetworkTrialsConfirmOnTheNewAddressAndRollBackWhenTheyExpire`; `HostingRaceTests.AConfirmationBeforeTheDeadlineCannotBeOverwrittenByTheWatchdog`. |
| Sign-in/stream limits, library maintenance and queue settings | Advanced Server sections | `ManagementFlowTests.ReadsTheServerAndSavesSettingsKeepingUnknownFields`; UI renders advanced settings. |
| Automatic backups, Back Up Now, retention and verify | `ServerPage` backup sections | `ManagementFlowTests.BacksUpListsAndVerifies`; retention editing is source reviewed. |
| Encrypted full backup export, staged restore and restart | Server-page backup sheets | Source review; no dedicated Linux-client export/restore integration test yet. Server-side backup tests cover its own implementation. |
| Sanitized server diagnostics and export | Advanced Server diagnostics | Settings rendering and endpoint integration cover reads; export/save action is source reviewed. |

## Hosting and distribution

| Mac capability | Linux counterpart | Coverage and limits |
| --- | --- | --- |
| Bundle and supervise the server as a separate process | `Core/Hosting/LocalServerHost`, bundled `server/` | `HostingFlowTests.SetsUpAndReopensThisComputersServer` covers launch, restart and crash recovery. |
| First owner setup and immediately open owner after PIN | `HostSetupModel`, profile picker | `HostingScreenTests.SetsUpThisPcOpensItsOwnerAndOffersTheFirstStorageLocations`. |
| Welcome Back when local credential is missing | Local sign-in screen | `HostingScreenTests.WelcomeBackRejectsThePasswordThenRemembersTheLocalConnection`; real process reopening in `HostingFlowTests`. |
| First storage-location setup and deliberate import confirmation | `Views/InitialLibrarySetupView` | `HostingScreenTests.FirstStorageLocationsWaitForTheImportPreviewToBeConfirmed`. |
| Forgot owner PIN with Server Password | Local profile-picker recovery | `HostingScreenTests.ForgotPinChecksConfirmationAndPasswordBeforeReturningToThePicker`; real reset in `HostingFlowTests.SetsUpAndReopensThisComputersServer`. |
| Detect occupied port/missing server and offer a useful recovery | Local host state and setup screens | `HostingScreenTests.AServerAlreadyOnThePortOffersTheExistingServer`, `AMissingServerExplainsTheFailureAndRetries`; process tests cover both conditions. |
| Background hosting, tray where supported, start at sign-in and keep awake | `HostingSettings`, tray, native/portal adapters | `HostingScreenTests.LocalHostingSettingsKeepLoginAndBackgroundChoicesConsistent`; real permission, tray and login behavior needs desktop verification. |
| Firewall instructions without silently changing firewall rules | `Settings/SettingsView` hosting section | `HostingScreenTests.FirewallHintsUseTheConfiguredPortWithoutChangingTheSystem`. |
| Preserve server/library/settings data across app package upgrades | XDG directories outside installed package | Source and package layout review; package-upgrade tests must verify files survive. |
| Linux installation formats | deb, rpm, Arch package and Flatpak | `scripts/package-linux-app.sh`; Ubuntu/Fedora/Arch container installation tests and Flatpak checks are release gates. |
| Decoder distribution | System libVLC for native packages, bundled VLC for Flatpak | Package manifest and third-party-notice review; actual codec playback remains the owner's check. |
| GitHub releases and automatic-update asset naming | Independent `linux-app-X.Y.Z-B` releases | `AppUpdateTests.RejectsMacServerAndMalformedTags`; release downloads/hashes are verified by the publishing workflow. |

## Remaining release gates

The listed Mac capabilities have Linux implementations or an explicit platform counterpart/difference.
The player additions cover chapters, local scrub fallback and sanitized diagnostics; pointer/focus
metadata preparation has a bounded cache and cancellation tests. Automated coverage is still thinner
for the listed source-reviewed editors and platform adapters than for setup and library browsing.
This inventory does not turn source review into execution evidence; keep that distinction in release
notes and validation claims.

Package installation in Ubuntu, Fedora and Arch containers, a Flatpak bundle with its own VLC,
the real Secret Service test, and launches on the owner's laptop using Wayland and X11 are separate
delivery gates. No successful headless test proves those paths. Pairing with the real server and
actual video/audio/subtitle playback are the owner's final checks; automated tests must continue
to use only synthetic data and simulated decoders.
