import SwiftUI
import UIKit

/// A poster with its title and year below, as in the Apple TV app on iPhone.
struct IOSPosterLabel: View {
  let item: IOSCatalogItem
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      IOSArtworkView(
        artwork: item.poster, width: 320,
        symbol: item.kind == .series || item.kind == .episode ? "tv" : "film"
      )
      .aspectRatio(2 / 3, contentMode: .fit)
      .overlay(alignment: .topTrailing) { IOSItemBadges(item: item).padding(5) }
      .overlay(alignment: .bottom) {
        if let fraction = item.progressFraction {
          IOSProgressBar(fraction: fraction).padding(.horizontal, 8).padding(.bottom, 8)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous)
          .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1)
        Text(item.cardSubtitle).font(.caption).foregroundStyle(.secondary)
          .lineLimit(item.kind == .episode ? 2 : 1)
        if item.kind == .episode, let availability = item.availabilityMessage {
          Text(availability).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .opacity(item.isPlayable || item.kind == .series ? 1 : 0.6)
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
      HStack(spacing: 4) {
        ForEach(symbols, id: \.self) { symbol in
          Image(systemName: symbol).foregroundStyle(
            symbol.hasPrefix("exclamation") ? Color.orange : Color.white)
        }
      }
      .font(.system(size: 10, weight: .bold))
      .padding(.horizontal, 5).padding(.vertical, 4)
      .background(.black.opacity(0.55), in: Capsule())
      .accessibilityHidden(true)
    }
  }
}

struct IOSArtworkView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.displayScale) private var displayScale
  let artwork: IOSArtwork?
  let width: Int
  var symbol: String? = "film"
  @State private var image: UIImage?

  var body: some View {
    // The picture is an overlay: filling its frame must never widen the layout around it.
    IOSDesign.surface
      .overlay {
        if let image {
          Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
        } else if let symbol {
          Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
        }
      }
      .clipped()
      .animation(.easeOut(duration: 0.2), value: image != nil)
      .task(id: key) {
        image = nil
        guard let artwork, let api = model.client, key != nil else { return }
        let sessionID = model.session?.sessionId
        do {
          let decoded = try await model.artwork.image(
            artwork: artwork, width: requestWidth, api: api)
          guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
          image = decoded
        } catch {}
      }
  }

  /// The server renders only these widths; any other request is rejected. A phone screen has
  /// two or three pixels per point, so the request asks for that much more.
  private var requestWidth: Int {
    let pixels = width * Int(displayScale.rounded()) / 2
    return [320, 640, 1280, 1920].first { $0 >= pixels } ?? 1920
  }

  private var key: String? {
    guard let artwork, let connection = model.connection, let session = model.session else {
      return nil
    }
    return
      "\(connection.serverID):\(session.sessionId):\(artwork.cacheIdentity):\(artwork.revision ?? 0):\(requestWidth)"
  }
}
