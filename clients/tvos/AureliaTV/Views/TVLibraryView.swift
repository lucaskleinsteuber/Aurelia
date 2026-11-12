import SwiftUI
import UIKit

/// Mac-style poster card. Focus uses the native tvOS lift, shadow and sheen on
/// the artwork, which stays visible on bright or white-edged posters.
struct TVPosterLabel: View {
  let item: TVCatalogItem
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      TVArtworkView(artwork: item.poster, width: 640, symbol: item.kind == .series ? "tv" : "film")
        .aspectRatio(2 / 3, contentMode: .fit)
        .overlay(alignment: .topTrailing) { TVItemBadges(item: item).padding(12) }
        .overlay(alignment: .bottom) {
          if let fraction = item.progressFraction {
            TVProgressBar(fraction: fraction).padding(.horizontal, 14).padding(.bottom, 14)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
        .hoverEffect(.highlight)
      VStack(alignment: .leading, spacing: 6) {
        Text(item.title).font(.system(size: 24, weight: .semibold)).lineLimit(1)
        Text(subtitle).font(.system(size: 20)).foregroundStyle(.secondary).lineLimit(1)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var subtitle: String {
    item.availabilityMessage ?? item.year.map(String.init) ?? item.kindLabel
  }
}

/// Favorite, watched and unavailable markers in the artwork's top-right corner.
struct TVItemBadges: View {
  let item: TVCatalogItem
  var body: some View {
    let symbols =
      [
        item.availabilityMessage != nil ? "exclamationmark.triangle.fill" : nil,
        item.isFavorite ? "star.fill" : nil, item.isWatched ? "checkmark.circle.fill" : nil,
      ].compactMap { $0 }
    if !symbols.isEmpty {
      HStack(spacing: 8) {
        ForEach(symbols, id: \.self) { symbol in
          Image(systemName: symbol).foregroundStyle(
            symbol.hasPrefix("exclamation") ? Color.orange : Color.white)
        }
      }.font(.system(size: 20, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 7)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
  }
}

struct TVArtworkView: View {
  @EnvironmentObject private var model: TVAppModel
  let artwork: TVArtwork?
  let width: Int
  var symbol: String? = "film"
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      TVDesign.surface
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else if let symbol {
        Image(systemName: symbol).font(.system(size: 54)).foregroundStyle(.tertiary)
      }
    }.clipped().task(id: key) {
      image = nil
      guard let artwork, let api = model.client, key != nil else { return }
      let sessionID = model.session?.sessionId
      do {
        let decoded = try await model.artwork.image(artwork: artwork, width: requestWidth, api: api)
        guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
        image = decoded
      } catch {}
    }
  }

  /// The server renders only these widths; any other request is rejected.
  private var requestWidth: Int { [320, 640, 1280, 1920].first { $0 >= width } ?? 1920 }

  private var key: String? {
    guard let artwork, let connection = model.connection, let session = model.session else {
      return nil
    }
    return
      "\(connection.serverID):\(session.sessionId):\(artwork.cacheIdentity):\(artwork.revision ?? 0):\(requestWidth)"
  }
}
