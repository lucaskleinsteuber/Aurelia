import SwiftUI
import UIKit

/// A poster with its title and year below, as in the Apple TV app on iPhone.
struct IOSPosterLabel: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let item: IOSCatalogItem
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      IOSArtworkView(
        artwork: item.poster, width: 320,
        symbol: item.kind == .series || item.kind == .episode ? "tv" : "film",
        placeholderTitle: item.parentTitle ?? item.title
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
        Text(item.title).font(.footnote.weight(.semibold))
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        Text(item.cardSubtitle).font(.caption).foregroundStyle(.secondary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : (item.kind == .episode ? 2 : 1))
        if item.kind == .episode, let availability = item.availabilityMessage {
          Text(availability).font(.caption).foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .opacity(item.isPlayable || item.kind == .series ? 1 : 0.72)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(item.title)
    .accessibilityValue(item.accessibilitySummary)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let artwork: IOSArtwork?
  let width: Int
  var symbol: String? = "film"
  var placeholderTitle: String?
  var onUnavailable: (() -> Void)?
  @State private var image: UIImage?

  var body: some View {
    // The picture is an overlay: filling its frame must never widen the layout around it.
    IOSDesign.surface
      .overlay {
        if let image {
          Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            .accessibilityHidden(true)
        } else if let symbol {
          VStack(spacing: 12) {
            Image(systemName: symbol).font(.title2.weight(.light))
              .foregroundStyle(.white.opacity(0.45))
            if let placeholderTitle, !placeholderTitle.isEmpty {
              Text(placeholderTitle).font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
                .lineLimit(4).minimumScaleFactor(0.85)
            }
          }
          .padding(placeholderTitle == nil ? 8 : 12)
          // Decorative copy of the accessible card title; keep it within the poster at
          // accessibility sizes, while the actual title below follows the full text size.
          .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          .accessibilityHidden(true)
        }
      }
      .clipped()
      .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: image != nil)
      .task(id: key) {
        image = nil
        guard let artwork, let api = model.client, key != nil else { return }
        let sessionID = model.session?.sessionId
        do {
          let decoded = try await model.artwork.image(
            artwork: artwork, width: requestWidth, api: api.background)
          guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
          image = decoded
        } catch {
          guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
          onUnavailable?()
        }
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
