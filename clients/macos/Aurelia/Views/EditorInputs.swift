import AppKit
import SwiftUI

struct EditorDescriptionInput: View {
  @Binding var text: String
  @State private var focused = false
  @Environment(\.aureliaContrast) private var contrast

  var body: some View {
    TextArea(text: $text, onFocus: { focused = $0 })
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            focused ? Color.accentColor.opacity(0.8) : AureliaDesign.hairline,
            lineWidth: focused || contrast == .increased ? 1.5 : 0.5)
      }
  }

  private struct TextArea: NSViewRepresentable {
    @Binding var text: String
    let onFocus: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.borderType = .noBorder
      scroll.drawsBackground = false
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = false
      scroll.scrollerStyle = .overlay
      scroll.verticalScroller?.controlSize = .small
      let view = TextView()
      view.onFocus = onFocus
      view.delegate = context.coordinator
      view.isRichText = false
      view.allowsUndo = true
      view.drawsBackground = false
      view.font = .preferredFont(forTextStyle: .body)
      view.textColor = .labelColor
      view.textContainerInset = NSSize(width: 12, height: 12)
      view.isVerticallyResizable = true
      view.isHorizontallyResizable = false
      view.autoresizingMask = [.width]
      view.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      view.textContainer?.widthTracksTextView = true
      view.textContainer?.containerSize = NSSize(
        width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = 4
      view.defaultParagraphStyle = paragraph
      view.setAccessibilityLabel("Description")
      view.setAccessibilityIdentifier("metadata-description")
      view.string = text
      scroll.documentView = view
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      context.coordinator.text = $text
      guard let view = scroll.documentView as? TextView else { return }
      view.onFocus = onFocus
      // Preserve selection and native undo for ordinary typing; only replace external changes.
      if view.string != text { view.string = text }
    }

    final class TextView: NSTextView {
      var onFocus: ((Bool) -> Void)?
      override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?(true) }
        return result
      }
      override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocus?(false) }
        return result
      }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
      var text: Binding<String>
      init(text: Binding<String>) { self.text = text }
      func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        text.wrappedValue = view.string
      }
    }
  }
}

struct EditorImagePreview: View {
  let client: APIClient?
  let mediaId: UUID
  let selection: EditorArtwork?
  let width: CGFloat
  let height: CGFloat
  var circular = false
  @State private var image: NSImage?
  @State private var loading = false
  @State private var failed = false

  var body: some View {
    ZStack {
      AureliaDesign.canvasTop
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
          .frame(width: width, height: height)
      } else if loading {
        ProgressView().controlSize(.small).accessibilityLabel("Loading Image")
      } else if failed {
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
          Button("Retry") { Task { await load() } }.font(.caption)
        }.accessibilityLabel("Image Unavailable")
      } else {
        Image(systemName: circular ? "person.fill" : "photo")
          .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
          .accessibilityLabel("No Image Selected")
      }
    }
    .frame(width: width, height: height)
    .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10)))
    .overlay {
      if circular {
        Circle().stroke(AureliaDesign.hairline, lineWidth: 0.5)
      } else {
        RoundedRectangle(cornerRadius: 10).stroke(AureliaDesign.hairline, lineWidth: 0.5)
      }
    }
    .task(id: selection) { await load() }
  }

  private func load() async {
    image = nil
    failed = false
    guard let selection, let client else {
      loading = false
      return
    }
    loading = true
    do {
      let bytes = try await client.editorImage(id: mediaId, selection: selection)
      try Task.checkCancellation()
      guard let original = NSImage(data: bytes) else { throw APIClientError.invalidResponse }
      image = CropImage.render(original, crop: selection.crop, maximumDimension: 1024)
      loading = false
    } catch is CancellationError {
      return
    } catch {
      if !Task.isCancelled {
        loading = false
        failed = true
      }
    }
  }
}
