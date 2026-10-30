import SwiftUI
import UIKit

/// Mac-style poster card. Focus uses the native tvOS lift, shadow and sheen on
/// the artwork, which stays visible on bright or white-edged posters.
struct IOSPosterLabel: View {
  let item: IOSCatalogItem
  var body: some View {
    VStack(alignment: .leading, spacing: IOSDesign.s(18)) {
      IOSArtworkView(artwork: item.poster, width: 640, symbol: item.kind == .series ? "tv" : "film")
        .aspectRatio(2 / 3, contentMode: .fit)
        .overlay(alignment: .topTrailing) { IOSItemBadges(item: item).padding(IOSDesign.s(12)) }
        .overlay(alignment: .bottom) {
          if let fraction = item.progressFraction {
            IOSProgressBar(fraction: fraction).padding(.horizontal, IOSDesign.s(14)).padding(
              .bottom, IOSDesign.s(14))
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous))
        .hoverEffect(.highlight)
      VStack(alignment: .leading, spacing: IOSDesign.s(6)) {
        Text(item.title).font(.system(size: IOSDesign.s(24), weight: .semibold)).lineLimit(1)
        Text(subtitle).font(.system(size: IOSDesign.s(20))).foregroundStyle(.secondary).lineLimit(1)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var subtitle: String {
    item.availabilityMessage ?? item.year.map(String.init) ?? item.kindLabel
  }
}

/// Favorite, watched and unavailable markers in the artwork's top-right corner.
struct IOSItemBadges: View {
  let item: IOSCatalogItem
  var body: some View {
    let symbols =
      [
        item.availabilityMessage != nil ? "exclamationmark.triangle.fill" : nil,
        item.isFavorite ? "star.fill" : nil, item.isWatched ? "checkmark.circle.fill" : nil,
      ].compactMap { $0 }
    if !symbols.isEmpty {
      HStack(spacing: IOSDesign.s(8)) {
        ForEach(symbols, id: \.self) { symbol in
          Image(systemName: symbol).foregroundStyle(
            symbol.hasPrefix("exclamation") ? Color.orange : Color.white)
        }
      }.font(.system(size: IOSDesign.s(20), weight: .semibold)).padding(
        .horizontal, IOSDesign.s(10)
      ).padding(.vertical, IOSDesign.s(7))
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: IOSDesign.s(10)))
        .accessibilityHidden(true)
    }
  }
}

struct IOSArtworkView: View {
  @EnvironmentObject private var model: IOSAppModel
  let artwork: IOSArtwork?
  let width: Int
  var symbol: String? = "film"
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      IOSDesign.surface
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else if let symbol {
        Image(systemName: symbol).font(.system(size: IOSDesign.s(54))).foregroundStyle(.tertiary)
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
      "\(connection.serverID):\(session.sessionId):\(artwork.id):\(artwork.revision ?? 0):\(requestWidth)"
  }
}
