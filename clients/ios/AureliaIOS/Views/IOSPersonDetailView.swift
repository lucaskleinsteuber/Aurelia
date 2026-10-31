import SwiftUI

struct IOSPersonDetailView: View {
  @EnvironmentObject private var model: IOSAppModel
  let name: String
  @State private var person: IOSPersonDetailResponse?
  @State private var loading = true
  @State private var error: String?

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
          }
          .padding(.horizontal, IOSDesign.margin).padding(.top, 12)

          if !person.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              IOSSectionHeader(title: "Appears In", count: person.items.count)
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
