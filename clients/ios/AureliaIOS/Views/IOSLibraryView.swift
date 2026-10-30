import SwiftUI

public struct IOSLibraryView: View {
  @ObservedObject var model: IOSAppModel
  @State private var selectedTab: IOSLibraryTab = .movies
  @State private var selectedItem: IOSCatalogItemSummary?

  private let columns = [
    GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 14)
  ]

  public init(model: IOSAppModel) {
    self.model = model
  }

  public var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("Category", selection: $selectedTab) {
          ForEach(IOSLibraryTab.allCases) { tab in
            Text(tab.rawValue).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)

        ScrollView {
          LazyVGrid(columns: columns, spacing: 18) {
            switch selectedTab {
            case .movies:
              ForEach(model.movies) { item in
                itemCard(item)
              }
            case .shows:
              ForEach(model.shows) { item in
                itemCard(item)
              }
            case .franchises:
              ForEach(model.franchises) { fran in
                franchiseCard(fran)
              }
            case .collections:
              ForEach(model.collections) { coll in
                collectionCard(coll)
              }
            }
          }
          .padding(16)
        }
      }
      .navigationTitle("Library")
      .refreshable {
        await model.refreshCatalog()
      }
      .navigationDestination(item: $selectedItem) { item in
        IOSDetailView(model: model, item: item)
      }
    }
  }

  private func itemCard(_ item: IOSCatalogItemSummary) -> some View {
    Button(action: { selectedItem = item }) {
      VStack(alignment: .leading, spacing: 6) {
        IOSAsyncImage(urlString: item.posterUrl, aspectRatio: 2 / 3)
          .clipShape(RoundedRectangle(cornerRadius: 10))

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
    }
    .buttonStyle(.plain)
  }

  private func franchiseCard(_ fran: IOSFranchiseSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      IOSAsyncImage(urlString: fran.posterUrl, aspectRatio: 2 / 3)
        .clipShape(RoundedRectangle(cornerRadius: 10))

      Text(fran.name)
        .font(.caption.bold())
        .lineLimit(1)

      Text("\(fran.movieCount) movies")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func collectionCard(_ coll: IOSCollectionSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack(alignment: .topTrailing) {
        IOSAsyncImage(urlString: coll.posterUrl, aspectRatio: 2 / 3)
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
  }
}
