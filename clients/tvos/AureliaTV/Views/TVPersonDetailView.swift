import SwiftUI

struct TVPersonDetailView: View {
  @EnvironmentObject private var model: TVAppModel
  let name: String
  @State private var person: TVPersonDetailResponse?
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

  private func load() async {
    guard let client = model.client else { return }
    loading = true
    error = nil
    do {
      person = try await client.personDetail(name: name)
    } catch {
      self.error = error.localizedDescription
    }
    loading = false
  }
}
