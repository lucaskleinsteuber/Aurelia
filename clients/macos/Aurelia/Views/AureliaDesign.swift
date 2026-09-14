import AppKit
import SwiftUI

enum AureliaDesign {
  static let pagePadding: CGFloat = 32
  static let sectionSpacing: CGFloat = 28
  static let cardRadius: CGFloat = 18
  static let compactRadius: CGFloat = 12
  static let heroRadius: CGFloat = 24
  static let sidebarWidth: CGFloat = 236
  static let pageTitle = Font.system(size: 34, weight: .bold)
  static let heroTitle = Font.system(size: 44, weight: .bold)
  static let sectionTitle = Font.system(size: 20, weight: .semibold)
  static let canvas = Color(red: 0.045, green: 0.055, blue: 0.071)
}

struct AureliaBackdrop: View {
  var body: some View {
    LinearGradient(
      colors: [
        Color(red: 0.08, green: 0.098, blue: 0.122),
        AureliaDesign.canvas,
        Color(red: 0.025, green: 0.031, blue: 0.041),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
  }
}

struct CinemaMaterialCard<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    content
      .padding(20)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
      .overlay {
        RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
          .stroke(.white.opacity(0.085), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
  }
}

struct AuthenticatedArtwork: View {
  @EnvironmentObject private var model: AppModel
  let artwork: ArtworkSummary?
  let symbol: String
  var contentMode: ContentMode = .fill
  var extendsBlurredEdges = false
  @State private var image: NSImage?

  var body: some View {
    ZStack {
      MediaArtworkPlaceholder(symbol: symbol)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Artwork placeholder")
        .accessibilityIdentifier("artwork-placeholder")
      if let image {
        if extendsBlurredEdges {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .scaleEffect(1.08)
            .blur(radius: 28, opaque: true)
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .transition(.opacity)
        } else {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .transition(.opacity)
        }
      }
    }
    .clipped()
    .accessibilityElement(children: .contain)
    .task(id: taskID) {
      image = nil
      guard let artwork, let profile = model.profile else { return }
      do {
        let data = try await model.artworkLoader.data(for: artwork, profile: profile)
        guard !Task.isCancelled else { return }
        image = NSImage(data: data)
      } catch is CancellationError {
        return
      } catch {
        image = nil
      }
    }
  }

  private var taskID: String {
    "\(model.profile?.serverId.uuidString ?? "none"):\(artwork?.id.uuidString ?? "none")"
  }
}

struct MediaArtworkPlaceholder: View {
  let symbol: String

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.16, green: 0.19, blue: 0.23),
          Color(red: 0.065, green: 0.078, blue: 0.098),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
      Image(systemName: symbol)
        .font(.system(size: 38, weight: .light))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.white.opacity(0.64))
    }
  }
}

struct MediaPosterCard: View {
  let item: CatalogItemSummary
  var width: CGFloat = 154
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      AuthenticatedArtwork(artwork: item.poster, symbol: item.kind == .movie ? "film" : "tv")
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
        .overlay(alignment: .topTrailing) {
          if item.availability == .missing {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption.weight(.bold))
              .foregroundStyle(.orange)
              .padding(8)
              .background(.ultraThinMaterial, in: Circle())
              .padding(8)
              .accessibilityLabel("Media missing")
          }
        }
        .overlay {
          RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
            .stroke(.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

      Text(item.title)
        .font(.headline)
        .lineLimit(1)
        .frame(width: width, alignment: .leading)
      Text(secondaryLine)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: width, alignment: .leading)
    }
    .contentShape(Rectangle())
    .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
    .animation(.easeOut(duration: 0.14), value: hovering)
    .onHover { hovering = $0 }
  }

  private var secondaryLine: String {
    if item.availability == .missing { return "Unavailable" }
    if let year = item.year { return String(year) }
    return item.kind == .movie ? "Movie" : "TV Show"
  }
}

struct LandscapeMediaCard: View {
  let item: CatalogItemSummary
  var width: CGFloat = 320
  var eyebrow: String?
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      AuthenticatedArtwork(
        artwork: item.backdrop ?? item.poster,
        symbol: item.kind == .movie ? "film" : item.kind == .episode ? "play.rectangle" : "tv")
      LinearGradient(
        colors: [.clear, .black.opacity(0.25), .black.opacity(0.88)],
        startPoint: .top,
        endPoint: .bottom)
      VStack(alignment: .leading, spacing: 3) {
        if let eyebrow {
          Text(eyebrow.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.72))
        }
        Text(item.title).font(.headline).lineLimit(1)
        Text(item.year.map(String.init) ?? (item.kind == .movie ? "Movie" : "TV Show"))
          .font(.caption)
          .foregroundStyle(.white.opacity(0.7))
      }
      .padding(16)
      if item.availability == .missing {
        AvailabilityBadge(availability: item.availability)
          .padding(12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
      if let progress = item.progressFraction {
        GeometryReader { geometry in
          VStack {
            Spacer()
            Capsule()
              .fill(.white.opacity(0.22))
              .frame(height: 4)
              .overlay(alignment: .leading) {
                Capsule().fill(.white).frame(width: geometry.size.width * progress, height: 4)
              }
          }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
      }
    }
    .frame(width: width, height: width * 0.5625)
    .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
        .stroke(.white.opacity(0.1), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
    .animation(.easeOut(duration: 0.14), value: hovering)
    .onHover { hovering = $0 }
  }
}

struct AvailabilityBadge: View {
  let availability: MediaAvailability

  var body: some View {
    if availability == .missing {
      Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.12), in: Capsule())
    }
  }
}

struct ErrorBanner: View {
  let message: String
  var retry: (() -> Void)?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
      if let retry { Button("Try Again", action: retry) }
    }
    .padding(14)
    .background(
      .regularMaterial, in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.compactRadius)
        .stroke(.white.opacity(0.08), lineWidth: 1)
    }
    .padding(.horizontal, AureliaDesign.pagePadding)
    .padding(.bottom, 18)
  }
}
