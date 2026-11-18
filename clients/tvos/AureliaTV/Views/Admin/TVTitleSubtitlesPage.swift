import SwiftUI

/// Subtitles… on a title's page, for administrators: the downloaded ones, a search on
/// OpenSubtitles in a language chosen with the remote, and downloading or removing one.
struct TVTitleSubtitlesPage: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var admin = TVAdministrationModel()
  let mediaID: UUID
  let title: String

  @State private var downloaded: [TVDownloadedSubtitle] = []
  @State private var language = "en"
  @State private var results: [TVSubtitleCandidate]?
  @State private var working = false
  @State private var message: String?

  var body: some View {
    TVSettingsPage(
      symbol: "captions.bubble", title: "Subtitles",
      subtitle: "\(title). Downloaded subtitles play on every device."
    ) {
      TVSettingsHeader(text: "Downloaded")
      if downloaded.isEmpty { TVSettingsNote(text: "No subtitles downloaded for this title.") }
      ForEach(downloaded) { subtitle in
        TVSettingsRow(
          title: subtitle.title, value: "Remove", id: "subtitle-\(subtitle.id)", role: .destructive
        ) {
          Task {
            let id = mediaID
            if await admin.perform({ try await $0.removeSubtitle(id: id, subtitle: subtitle.id) }) {
              downloaded.removeAll { $0.id == subtitle.id }
            }
          }
        }
      }
      TVSettingsHeader(text: "OpenSubtitles")
      TVSettingsRow(
        title: "Language", value: TVSubtitleLanguages.name(language), id: "subtitle-language"
      ) {
        language = TVSettingsRow.next(after: language, in: TVSubtitleLanguages.choices)
        results = nil
      }
      TVSettingsRow(title: working ? "Searching…" : "Search", id: "subtitle-search") {
        Task { await search() }
      }
      .disabled(working)
      if let message { TVSettingsNote(text: message) }
      if let results {
        if results.isEmpty {
          TVSettingsNote(text: "No subtitles found in \(TVSubtitleLanguages.name(language)).")
        }
        ForEach(results.prefix(15)) { candidate in
          Button {
            Task { await download(candidate) }
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              Text(candidate.release ?? TVSubtitleLanguages.name(candidate.language)).lineLimit(2)
              Text(candidate.details).font(.system(size: 20)).opacity(0.65)
            }
            .padding(.horizontal, 30).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
          }
          .buttonStyle(TVButtonStyle(kind: .row))
          .disabled(working)
        }
      }
      TVSettingsHeader(text: "")
      TVSettingsRow(title: "Done", id: "subtitles-done") { dismiss() }
    }
    .tvAdministration(admin)
    .task {
      let id = mediaID
      downloaded = await admin.value { try await $0.downloadedSubtitles(id: id) } ?? []
      if let provider = try? await admin.client?.subtitleProvider() {
        language = TVSubtitleLanguages.first(provider)
        if !provider.enabled {
          message = "The owner sets up OpenSubtitles in the server's metadata settings first."
        }
      }
    }
  }

  private func search() async {
    working = true
    defer { working = false }
    message = nil
    let id = mediaID
    let code = language
    do {
      results = try await admin.run { try await $0.searchSubtitles(id: id, language: code) }
    } catch is CancellationError {
    } catch {
      message = Self.text(error)
    }
  }

  private func download(_ candidate: TVSubtitleCandidate) async {
    working = true
    defer { working = false }
    let id = mediaID
    let request = candidate.download
    do {
      let saved = try await admin.run { try await $0.downloadSubtitle(id: id, request) }
      downloaded.removeAll { $0.id == saved.id }
      downloaded.append(saved)
      results = nil
      message = "Downloaded “\(saved.title)”."
    } catch is CancellationError {
    } catch {
      message = Self.text(error)
    }
  }

  private static func text(_ error: Error) -> String {
    if (error as? TVCoreError)?.code == "subtitle_quota_reached" {
      return "Today's OpenSubtitles downloads are used up. Try again tomorrow."
    }
    return TVAdministrationModel.message(error)
  }
}
