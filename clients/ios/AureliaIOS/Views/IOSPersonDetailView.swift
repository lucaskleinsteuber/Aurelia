import SwiftUI

/// A person with their titles in the library and, from TMDB ("people-v1"), their life and the
/// titles they are known for that the library doesn't have, with Wish and Me Too.
struct IOSPersonDetailView: View {
  @EnvironmentObject private var model: IOSAppModel
  let name: String
  var personKey: String?
  @State private var person: IOSPersonDetailResponse?
  @State private var loading = true
  @State private var error: String?
  @State private var profile: IOSPersonProfile?
  @State private var biographyOpen = false
  @State private var wishing: String?
  @State private var wishMessage: String?

  private var showsProfile: Bool { model.supportsPeople && IOSPeoplePresentation.hasProfile(personKey) }

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        if let person {
          VStack(spacing: 10) {
            IOSArtworkView(artwork: person.profile, width: 320, symbol: "person.fill")
              .frame(width: 120, height: 120).clipShape(Circle())
              .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.5))
            Text(person.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            if let subtitle = person.subtitle, !subtitle.isEmpty {
              Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            if let life = IOSPeoplePresentation.life(profile?.about) {
              Text(life).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
          }
          .padding(.horizontal, IOSDesign.margin).padding(.top, 12)

          if let biography = profile?.about?.biography?.trimmingCharacters(in: .whitespacesAndNewlines),
            !biography.isEmpty
          {
            biographySection(biography)
          }

          if !person.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              IOSSectionHeader(title: showsProfile ? "In Your Library" : "Appears In", count: person.items.count)
              LazyVGrid(columns: IOSDesign.gridColumns, spacing: 20) {
                ForEach(person.items) { item in
                  NavigationLink {
                    IOSDetailView(id: item.detailID, initial: item)
                  } label: {
                    IOSPosterLabel(item: model.overlay(item))
                  }
                  .buttonStyle(IOSContentButtonStyle())
                  .accessibilityIdentifier("person-work-\(item.id)")
                }
              }
              .padding(.horizontal, IOSDesign.margin)
            }
          } else {
            ContentUnavailableView("No Titles Found", systemImage: "film").padding(.top, 40)
          }

          if let knownFor = profile?.knownFor, !knownFor.isEmpty {
            knownForSection(knownFor)
          }
        } else if loading {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if let error {
          VStack(spacing: 12) {
            IOSErrorText(message: error)
            Button("Try Again") { Task { await load() } }.buttonStyle(IOSButtonStyle())
          }
          .padding(.horizontal, IOSDesign.margin).padding(.top, 60)
        }
      }
      .padding(.bottom, 32)
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle(person?.name ?? name)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      // The life never holds up the library's titles; each shows when it arrives.
      async let life: Void = loadProfile()
      await load()
      await life
    }
  }

  private func biographySection(_ biography: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Biography").font(.title3.weight(.bold))
      Text(biography)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(biographyOpen ? nil : 5)
      HStack(spacing: 12) {
        if biography.count > 280 {
          Button(biographyOpen ? "Less" : "More") { biographyOpen.toggle() }
            .font(.subheadline.weight(.semibold))
            .tint(.white)
        }
        Text("From TMDB").font(.caption).foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, IOSDesign.margin)
  }

  private func knownForSection(_ hits: [IOSWishSearchHit]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      IOSSectionHeader(title: "Known For", count: hits.count)
      if let wishMessage {
        Text(wishMessage).font(.footnote).foregroundStyle(.secondary)
          .padding(.horizontal, IOSDesign.margin)
      }
      IOSShelf {
        ForEach(hits) { hit in
          VStack(alignment: .leading, spacing: 5) {
            IOSWishPosterView(
              posterPath: hit.posterPath, kind: hit.kind, width: IOSDesign.posterWidth,
              height: IOSDesign.posterWidth * 1.5)
            Text(hit.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text([hit.year.map(String.init), hit.kind == .series ? "TV Show" : "Movie"].compactMap { $0 }.joined(separator: " · "))
              .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if model.supportsWishes { wishControl(hit) }
          }
          .frame(width: IOSDesign.posterWidth, alignment: .leading)
          .accessibilityIdentifier("known-for-\(hit.id)")
        }
      }
    }
  }

  @ViewBuilder
  private func wishControl(_ hit: IOSWishSearchHit) -> some View {
    if hit.alreadyWished && hit.supportedByCaller {
      Label("Wished", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    } else {
      Button {
        Task { await wish(hit) }
      } label: {
        Label(hit.alreadyWished ? "Me Too" : "Wish", systemImage: "gift").font(.caption.weight(.semibold))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .tint(.white)
      .disabled(wishing != nil)
    }
  }

  private func load() async {
    guard let client = model.client else { return }
    loading = true
    error = nil
    do {
      person = try await client.personDetail(name: name, key: personKey)
    } catch {
      if !(error is CancellationError) { self.error = error.localizedDescription }
    }
    loading = false
  }

  private func loadProfile() async {
    guard showsProfile, let personKey, let client = model.client else { return }
    // Without TMDB, or while it is away, the page shows the library's titles only.
    if let loaded = try? await client.personProfile(key: personKey), !Task.isCancelled {
      withAnimation(.easeOut(duration: 0.2)) { profile = loaded }
    }
  }

  /// Wishes the title, or adds this profile to someone else's wish for it.
  private func wish(_ hit: IOSWishSearchHit) async {
    guard let client = model.client else { return }
    wishing = hit.id
    wishMessage = nil
    defer { wishing = nil }
    do {
      var wishId = hit.existingWishId
      if hit.alreadyWished, let existing = hit.existingWishId {
        _ = try await client.setWishSupport(id: existing, supported: true)
      } else {
        switch try await client.createWish(
          IOSCreateWishRequest(
            kind: hit.kind, title: hit.title, year: hit.year, provider: hit.provider,
            providerMediaId: hit.providerMediaId, overview: hit.overview, posterPath: hit.posterPath,
            note: nil))
        {
        case .created(let created): wishId = created.wish.id
        case .alreadyInLibrary(let problem):
          wishMessage = problem.message
          return
        }
      }
      if let current = profile {
        profile = IOSPersonProfile(
          about: current.about,
          knownFor: current.knownFor.map { $0.id == hit.id ? IOSPeoplePresentation.wished($0, wishId: wishId) : $0 })
      }
      await model.refreshWishSummary(notify: false)
    } catch {
      if error is CancellationError { return }
      wishMessage = error.localizedDescription
    }
  }
}
