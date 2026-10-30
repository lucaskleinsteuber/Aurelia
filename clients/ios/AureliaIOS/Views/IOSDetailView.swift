import SwiftUI

public struct IOSDetailView: View {
  @ObservedObject var model: IOSAppModel
  let item: IOSCatalogItemSummary

  public init(model: IOSAppModel, item: IOSCatalogItemSummary) {
    self.model = model
    self.item = item
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Hero backdrop / poster
        ZStack(alignment: .bottomLeading) {
          if let backdrop = item.backdropUrl ?? item.posterUrl {
            IOSAsyncImage(urlString: backdrop, aspectRatio: 16 / 9)
              .overlay(
                LinearGradient(
                  colors: [.clear, .black.opacity(0.8), .black],
                  startPoint: .top,
                  endPoint: .bottom
                )
              )
          }

          HStack(alignment: .bottom, spacing: 16) {
            IOSAsyncImage(urlString: item.posterUrl, aspectRatio: 2 / 3)
              .frame(width: 100, height: 150)
              .clipShape(RoundedRectangle(cornerRadius: 12))
              .shadow(radius: 8)

            VStack(alignment: .leading, spacing: 6) {
              Text(item.title)
                .font(.title2.bold())
                .foregroundStyle(.white)

              HStack(spacing: 8) {
                if let year = item.releaseYear {
                  Text("\(year)")
                }
                if let dur = item.durationSeconds {
                  Text("\(Int(dur / 60))m")
                }
                if let rating = item.rating {
                  Text(String(format: "★ %.1f", rating))
                    .foregroundStyle(.yellow)
                }
              }
              .font(.caption)
              .foregroundStyle(.white.opacity(0.8))
            }
          }
          .padding(16)
        }

        // Action Buttons
        HStack(spacing: 12) {
          Button(action: {
            Task {
              await model.playItem(item)
            }
          }) {
            HStack {
              Image(systemName: "play.fill")
              Text(item.positionSeconds != nil && item.positionSeconds! > 0 ? "Resume" : "Play")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white)
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
          }

          // "Play on..." device menu
          Menu {
            if model.activePlayers.isEmpty {
              Text("No other players online")
            } else {
              ForEach(model.activePlayers) { player in
                Button(action: {
                  Task {
                    await model.playOnDevice(targetDevice: player, item: item)
                  }
                }) {
                  Label(player.deviceName, systemImage: "airplayvideo")
                }
              }
            }
          } label: {
            HStack {
              Image(systemName: "tv.and.mediabox")
              Text("Play on…")
            }
            .font(.subheadline.bold())
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
          }
        }
        .padding(.horizontal, 16)

        // Overview
        if let overview = item.overview, !overview.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Overview")
              .font(.headline)
            Text(overview)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineSpacing(4)
          }
          .padding(.horizontal, 16)
        }

        // Genres
        if let genres = item.genres, !genres.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack {
              ForEach(genres, id: \.self) { genre in
                Text(genre)
                  .font(.caption.bold())
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(Color(uiColor: .secondarySystemBackground))
                  .clipShape(Capsule())
              }
            }
            .padding(.horizontal, 16)
          }
        }

        // Franchise link
        if let franName = item.franchiseName {
          VStack(alignment: .leading, spacing: 8) {
            Text("Part of the Franchise")
              .font(.headline)
            HStack {
              Image(systemName: "film.stack")
              Text(franName)
                .font(.subheadline.bold())
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
          }
          .padding(.horizontal, 16)
        }
      }
      .padding(.bottom, 32)
    }
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await model.refreshActivePlayers()
    }
  }
}
