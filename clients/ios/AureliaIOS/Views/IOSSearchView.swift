import SwiftUI

public struct IOSSearchView: View {
  @ObservedObject var model: IOSAppModel
  @State private var query = ""
  @State private var selectedItem: IOSCatalogItemSummary?

  private let columns = [
    GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 14)
  ]

  public init(model: IOSAppModel) {
    self.model = model
  }

  public var body: some View {
    NavigationStack {
      VStack {
        if model.searchResults.isEmpty && !query.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 40))
              .foregroundStyle(.tertiary)
            Text("No titles matching “\(query)”")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
              ForEach(model.searchResults) { item in
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
            }
            .padding(16)
          }
        }
      }
      .navigationTitle("Search")
      .searchable(text: $query, prompt: "Movies, series, actors…")
      .onChange(of: query) { _, newQuery in
        Task {
          await model.performSearch(query: newQuery)
        }
      }
      .navigationDestination(item: $selectedItem) { item in
        IOSDetailView(model: model, item: item)
      }
    }
  }
}
