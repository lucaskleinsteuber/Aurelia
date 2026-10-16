import SwiftUI
import UIKit

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
      guard let artwork, let api = model.client, key != nil else { return }
      let sessionID = model.session?.sessionId
      do {
        let decoded = try await model.artwork.image(artwork: artwork, width: width, api: api)
        guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
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
