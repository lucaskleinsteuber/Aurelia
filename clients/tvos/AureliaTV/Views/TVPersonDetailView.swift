import SwiftUI

struct TVPersonDetailView: View {
  @EnvironmentObject private var model: TVAppModel
  let name: String
  var personKey: String? = nil
  @State private var person: TVPersonDetailResponse?
  @State private var profile: TVPersonProfile?
  @State private var wishing: String?
  @State private var wishMessage: String?
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 36) {
        if let person {
          HStack(spacing: 36) {
            if let profile = person.profile {
              TVArtworkView(artwork: profile, width: 240, symbol: "person.fill")
                .frame(width: 240, height: 240)
                .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 10) {
              Text(person.name)
                .font(.system(size: 56, weight: .bold))
              if let subtitle = person.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                  .font(.system(size: 26, weight: .medium))
                  .foregroundStyle(.secondary)
              }
              if let life = TVPeoplePresentation.life(profile?.about) {
                Text(life).font(.system(size: 24)).foregroundStyle(.secondary)
              }
              if let biography = profile?.about?.biography, !biography.isEmpty {
                Text(biography).font(.system(size: 22)).foregroundStyle(.secondary)
                  .lineLimit(4).frame(maxWidth: 1200, alignment: .leading)
              }
            }
          }
          .padding(.horizontal, TVDesign.pagePadding)
          .padding(.top, 40)

          if !person.items.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
              TVSectionHeader(title: "Appears In", count: person.items.count)
                .padding(.horizontal, TVDesign.pagePadding)
              ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) {
                  ForEach(person.items) { item in
                    NavigationLink {
                      TVDetailView(id: item.detailID, initial: item)
                    } label: {
                      TVPosterLabel(item: item).frame(width: TVDesign.posterWidth)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("person-work-\(item.id)")
                  }
                }
                .padding(.horizontal, TVDesign.pagePadding)
                .padding(.vertical, 16)
              }
              .scrollIndicators(.hidden)
              .scrollClipDisabled()
              .focusSection()
            }
          } else {
            ContentUnavailableView("No Titles Found", systemImage: "film")
              .padding(.top, 60)
          }
          if let knownFor = profile?.knownFor, !knownFor.isEmpty {
            knownForRow(knownFor)
          }
        } else if loading {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
        } else if let error {
          VStack(alignment: .leading, spacing: 20) {
            TVErrorText(message: error)
            Button("Try Again") {
              Task { await load() }
            }
            .buttonStyle(TVButtonStyle())
          }
          .padding(.horizontal, TVDesign.pagePadding)
          .padding(.top, 60)
        }
      }
      .padding(.bottom, 60)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
    .task { await load() }
  }

  /// Titles TMDB knows this person for that the library doesn't have, each to wish for.
  private func knownForRow(_ hits: [TVWishSearchHit]) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      TVSectionHeader(title: "Known For", count: hits.count)
        .padding(.horizontal, TVDesign.pagePadding)
      if let wishMessage {
        TVErrorText(message: wishMessage).padding(.horizontal, TVDesign.pagePadding)
      }
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 48) {
          ForEach(hits) { hit in
            Button {
              Task { await wish(hit) }
            } label: {
              VStack(alignment: .leading, spacing: 10) {
                TVWishPosterThumbnail(posterPath: hit.posterPath, kind: hit.kind)
                  .frame(width: TVDesign.posterWidth, height: TVDesign.posterWidth * 1.5)
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(hit.title).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                Label(
                  wishing == hit.id ? "Wishing…" : TVWishActions.label(hit),
                  systemImage: hit.alreadyWished && hit.supportedByCaller ? "checkmark" : "gift"
                )
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary)
              }
              .frame(width: TVDesign.posterWidth)
            }
            .buttonStyle(.borderless)
            .disabled(wishing != nil || (hit.alreadyWished && hit.supportedByCaller))
            .accessibilityIdentifier("known-for-\(hit.id)")
          }
        }
        .padding(.horizontal, TVDesign.pagePadding)
        .padding(.vertical, 16)
      }
      .scrollIndicators(.hidden)
      .scrollClipDisabled()
      .focusSection()
    }
  }

  private func load() async {
    guard let client = model.client else { return }
    loading = true
    error = nil
    do {
      person = try await client.personDetail(name: name, key: personKey)
    } catch {
      self.error = error.localizedDescription
    }
    loading = false
    // Without TMDB, or while it is away, the page shows the library's titles only.
    if model.capabilities?.supportsPeople == true, TVPeoplePresentation.hasProfile(personKey),
      let personKey, let loaded = try? await client.personProfile(key: personKey)
    {
      profile = loaded
    }
  }

  private func wish(_ hit: TVWishSearchHit) async {
    guard let client = model.client else { return }
    wishing = hit.id
    wishMessage = nil
    defer { wishing = nil }
    do {
      switch try await TVWishActions.wish(hit, client: client) {
      case .wished(let id):
        if let current = profile {
          profile = TVPersonProfile(
            about: current.about,
            knownFor: current.knownFor.map {
              $0.id == hit.id ? TVPeoplePresentation.wished($0, wishId: id) : $0
            })
        }
        await model.refreshWishSummary()
      case .inLibrary(let message):
        wishMessage = message
      }
    } catch {
      if !(error is CancellationError) { wishMessage = error.localizedDescription }
    }
  }
}
