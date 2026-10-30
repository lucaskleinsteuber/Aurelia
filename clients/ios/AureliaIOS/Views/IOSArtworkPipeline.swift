import SwiftUI

public struct IOSAsyncImage: View {
  let urlString: String?
  let aspectRatio: CGFloat

  @State private var image: UIImage? = nil
  @State private var isLoading = false

  public init(urlString: String?, aspectRatio: CGFloat = 2 / 3) {
    self.urlString = urlString
    self.aspectRatio = aspectRatio
  }

  public var body: some View {
    ZStack {
      Color(uiColor: .secondarySystemBackground)

      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else if isLoading {
        ProgressView()
      } else {
        Image(systemName: "film")
          .font(.system(size: 28))
          .foregroundStyle(.tertiary)
      }
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
    .clipped()
    .task(id: urlString) {
      await loadImage()
    }
  }

  private func loadImage() async {
    guard let urlString, !urlString.isEmpty else { return }

    if let cached = IOSArtworkDiskCache.shared.data(for: urlString),
      let uiImage = UIImage(data: cached)
    {
      self.image = uiImage
      return
    }

    guard let url = URL(string: urlString) else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      if let uiImage = UIImage(data: data) {
        IOSArtworkDiskCache.shared.store(data, for: urlString)
        self.image = uiImage
      }
    } catch {
      // Ignored: placeholder displayed
    }
  }
}
