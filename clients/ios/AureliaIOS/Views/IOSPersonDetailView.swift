import SwiftUI

struct IOSPersonDetailView: View {
  @EnvironmentObject private var model: IOSAppModel
  let name: String
  @State private var person: IOSPersonDetailResponse?
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: IOSDesign.s(36)) {
        if let person {
          HStack(spacing: IOSDesign.s(36)) {
            if let profile = person.profile {
              IOSArtworkView(artwork: profile, width: 240, symbol: "person.fill")
                .frame(width: IOSDesign.s(240), height: IOSDesign.s(240))
                .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: IOSDesign.s(10)) {
              Text(person.name)
                .font(.system(size: IOSDesign.s(56), weight: .bold))
              if let subtitle = person.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                  .font(.system(size: IOSDesign.s(26), weight: .medium))
                  .foregroundStyle(.secondary)
              }
            }
          }
          .padding(.horizontal, IOSDesign.pagePadding)
          .padding(.top, IOSDesign.s(40))

          if !person.items.isEmpty {
            VStack(alignment: .leading, spacing: IOSDesign.s(24)) {
              IOSSectionHeader(title: "Appears In", count: person.items.count)
                .padding(.horizontal, IOSDesign.pagePadding)
              ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: IOSDesign.s(48)) {
                  ForEach(person.items) { item in
                    NavigationLink {
                      IOSDetailView(id: item.detailID, initial: item)
                    } label: {
                      IOSPosterLabel(item: item).frame(width: IOSDesign.posterWidth)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("person-work-\(item.id)")
                  }
                }
                .padding(.horizontal, IOSDesign.pagePadding)
                .padding(.vertical, IOSDesign.s(16))
              }
              .scrollIndicators(.hidden)
              .scrollClipDisabled()

            }
          } else {
            ContentUnavailableView("No Titles Found", systemImage: "film")
              .padding(.top, IOSDesign.s(60))
          }
        } else if loading {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.top, IOSDesign.s(120))
        } else if let error {
          VStack(alignment: .leading, spacing: IOSDesign.s(20)) {
            IOSErrorText(message: error)
            Button("Try Again") {
              Task { await load() }
            }
            .buttonStyle(IOSButtonStyle())
          }
          .padding(.horizontal, IOSDesign.pagePadding)
          .padding(.top, IOSDesign.s(60))
        }
      }
      .padding(.bottom, IOSDesign.s(60))
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
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
