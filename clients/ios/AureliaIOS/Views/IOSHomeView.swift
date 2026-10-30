import SwiftUI

public struct IOSHomeView: View {
  @ObservedObject var model: IOSAppModel
  @State private var selectedItem: IOSCatalogItemSummary?

  public init(model: IOSAppModel) {
    self.model = model
  }

  public var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          if !model.homeCatalog.continueWatching.isEmpty {
            railSection(
              title: "Continue Watching", items: model.homeCatalog.continueWatching,
              showProgress: true)
          }

          if !model.homeCatalog.upNext.isEmpty {
            railSection(title: "Up Next", items: model.homeCatalog.upNext, showProgress: false)
          }

          if !model.franchises.isEmpty {
            franchisesSection(franchises: model.franchises)
          }

          if !model.collections.isEmpty {
            collectionsSection(collections: model.collections)
          }

          if !model.homeCatalog.recentlyAdded.isEmpty {
            railSection(
              title: "Recently Added", items: model.homeCatalog.recentlyAdded, showProgress: false)
          }
        }
        .padding(.vertical, 16)
      }
      .navigationTitle("Home")
      .refreshable {
        await model.refreshCatalog()
      }
      .navigationDestination(item: $selectedItem) { item in
        IOSDetailView(model: model, item: item)
      }
    }
  }

  private func railSection(title: String, items: [IOSCatalogItemSummary], showProgress: Bool)
    -> some View
  {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title3.bold())
        .padding(.horizontal, 16)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 14) {
          ForEach(items) { item in
            Button(action: { selectedItem = item }) {
              VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                  IOSAsyncImage(urlString: item.posterUrl, aspectRatio: 2 / 3)
                    .frame(width: 130, height: 195)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                  if showProgress, let pos = item.positionSeconds, let dur = item.durationSeconds,
                    dur > 0
                  {
                    GeometryReader { geo in
                      let frac = max(0, min(pos / dur, 1.0))
                      ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.6))
                        Rectangle().fill(Color.white).frame(width: geo.size.width * frac)
                      }
                    }
                    .frame(height: 4)
                  }
                }

                Text(item.title)
                  .font(.caption.bold())
                  .lineLimit(1)
                  .foregroundStyle(.primary)

                if let year = item.releaseYear {
                  Text("\(year)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              .frame(width: 130)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }

  private func franchisesSection(franchises: [IOSFranchiseSummary]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Franchises")
        .font(.title3.bold())
        .padding(.horizontal, 16)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 14) {
          ForEach(franchises) { fran in
            VStack(alignment: .leading, spacing: 6) {
              IOSAsyncImage(urlString: fran.posterUrl, aspectRatio: 2 / 3)
                .frame(width: 130, height: 195)
                .clipShape(RoundedRectangle(cornerRadius: 10))

              Text(fran.name)
                .font(.caption.bold())
                .lineLimit(1)

              Text("\(fran.movieCount) movies")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(width: 130)
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }

  private func collectionsSection(collections: [IOSCollectionSummary]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Collections")
        .font(.title3.bold())
        .padding(.horizontal, 16)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 14) {
          ForEach(collections) { coll in
            VStack(alignment: .leading, spacing: 6) {
              ZStack(alignment: .topTrailing) {
                IOSAsyncImage(urlString: coll.posterUrl, aspectRatio: 2 / 3)
                  .frame(width: 130, height: 195)
                  .clipShape(RoundedRectangle(cornerRadius: 10))

                if coll.isSmart {
                  Text("Smart")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(6)
                }
              }

              Text(coll.name)
                .font(.caption.bold())
                .lineLimit(1)

              Text("\(coll.itemCount) items")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(width: 130)
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }
}
