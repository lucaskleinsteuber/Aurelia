import SwiftUI
import UIKit

struct TVLibraryGrid: View {
  @EnvironmentObject private var model: TVAppModel
  @ObservedObject var listing: TVLibraryListing
  let title: String
  @State private var scrollAnchor: UUID?
  @FocusState private var focusedItem: UUID?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 36) {
        Text(title).font(.system(size: 46, weight: .bold))
        if listing.items.isEmpty && !listing.loading && listing.error == nil {
          Text("No titles shared with this profile.").foregroundStyle(.secondary)
        }
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 36), count: 5), spacing: 44
        ) {
          ForEach(listing.items) { item in
            NavigationLink {
              TVDetailView(id: item.id, initial: item)
            } label: {
              TVPosterLabel(item: item, isFocused: focusedItem == item.id)
            }.buttonStyle(TVContentButtonStyle()).focusEffectDisabled().focused(
              $focusedItem, equals: item.id
            ).id(item.id).accessibilityIdentifier("catalog-\(item.id)")
              .onAppear { if item.id == listing.items.last?.id { loadNext() } }
          }
        }.scrollTargetLayout().focusSection()
        if listing.loading { ProgressView().frame(maxWidth: .infinity) }
        if let error = listing.error {
          TVErrorText(message: error)
          Button("Try Again") { loadNext() }
        }
      }.padding(.horizontal, 64).padding(.vertical, 40)
    }.scrollPosition(id: $scrollAnchor, anchor: .top)
      .background(TVDesign.canvas.ignoresSafeArea())
      .task(id: model.session?.sessionId) { loadNext() }
  }

  private func loadNext() {
    guard let api = model.client else { return }
    Task { await listing.loadNext(api: api, onFailure: model.handleSessionFailure) }
  }
}

struct TVPosterLabel: View {
  let item: TVCatalogItem
  var isFocused = false
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      TVArtworkView(artwork: item.poster, width: 640, symbol: item.kind == .series ? "tv" : "film")
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
          RoundedRectangle(cornerRadius: 14).stroke(
            .white.opacity(isFocused ? 0.9 : 0), lineWidth: 2))
      Text(item.title).font(.system(size: 28, weight: .semibold)).multilineTextAlignment(.leading)
        .lineLimit(2).frame(
          height: 68, alignment: .topLeading)
      HStack {
        if let year = item.year { Text(String(year)) }
        Spacer()
        if item.watchState == "completed" || item.progress?.isCompleted == true {
          Image(systemName: "checkmark.circle.fill")
        }
      }.font(.caption).foregroundStyle(.secondary)
      if let message = item.availabilityMessage {
        Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
      .scaleEffect(isFocused ? 1.025 : 1).animation(.easeOut(duration: 0.12), value: isFocused)
  }
}

struct TVArtworkView: View {
  @EnvironmentObject private var model: TVAppModel
  let artwork: TVArtwork?
  let width: Int
  var symbol = "film"
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      TVDesign.surface
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: symbol).font(.system(size: 54)).foregroundStyle(.tertiary)
      }
    }.clipped().task(id: key) {
      image = nil
      guard let artwork, let api = model.client, let key else { return }
      let sessionID = model.session?.sessionId
      if let cached = model.images.object(forKey: key as NSString) {
        image = UIImage(data: cached as Data)
        return
      }
      do {
        let data = try await api.artworkData(artwork: artwork, width: width)
        guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
        guard let decoded = UIImage(data: data) else { return }
        model.images.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        image = decoded
      } catch {}
    }
  }

  private var key: String? {
    guard let artwork, let connection = model.connection, let session = model.session else {
      return nil
    }
    return
      "\(connection.serverID):\(session.sessionId):\(artwork.id):\(artwork.revision ?? 0):\(width)"
  }
}
