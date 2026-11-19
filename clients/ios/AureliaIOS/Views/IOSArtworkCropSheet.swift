import SwiftUI

/// Zoom and move a picture inside the frame of a poster (2:3), a backdrop (16:9) or a cover.
struct IOSArtworkCropSheet: View {
  let image: CGImage
  let aspectRatio: CGFloat
  let title: String
  let done: (IOSArtworkCrop?) -> Void
  @State private var zoom: CGFloat = 1
  @State private var offset: CGSize = .zero
  @GestureState private var dragging: CGSize = .zero
  @GestureState private var pinching: CGFloat = 1

  private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let maxW = max(120, geometry.size.width - 40)
        let maxH = max(80, geometry.size.height - 40)
        let frameW = min(maxW, maxH * aspectRatio)
        let frameSize = CGSize(width: frameW, height: frameW / aspectRatio)
        let liveZoom = min(max(zoom * pinching, 1), IOSRectCrop.maximumZoom)
        let live = IOSRectCrop.clamped(
          offset: CGSize(
            width: offset.width + dragging.width, height: offset.height + dragging.height),
          imageSize: imageSize, frameSize: frameSize, zoom: liveZoom)
        let scale =
          max(frameSize.width / imageSize.width, frameSize.height / imageSize.height)
          * liveZoom
        ZStack {
          Color.black.ignoresSafeArea()
          Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: imageSize.width * scale, height: imageSize.height * scale)
            .offset(live)
          Rectangle().fill(.black.opacity(0.55))
            .ignoresSafeArea()
            .mask {
              Rectangle().ignoresSafeArea().overlay {
                RoundedRectangle(cornerRadius: 10)
                  .frame(width: frameSize.width, height: frameSize.height)
                  .blendMode(.destinationOut)
              }
              .compositingGroup()
            }
            .allowsHitTesting(false)
          RoundedRectangle(cornerRadius: 10).strokeBorder(.white, lineWidth: 2)
            .frame(width: frameSize.width, height: frameSize.height)
            .allowsHitTesting(false)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .onChange(of: geometry.size) { _, newSize in
          let newMaxW = max(120, newSize.width - 40)
          let newMaxH = max(80, newSize.height - 40)
          let newFrameW = min(newMaxW, newMaxH * aspectRatio)
          let newFrameSize = CGSize(width: newFrameW, height: newFrameW / aspectRatio)
          offset = IOSRectCrop.clamped(
            offset: offset, imageSize: imageSize, frameSize: newFrameSize, zoom: zoom)
        }
        .clipped()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) crop area")
        .accessibilityHint("Drag to move the artwork, pinch to zoom.")
        .gesture(
          DragGesture()
            .updating($dragging) { value, state, _ in state = value.translation }
            .onEnded { value in
              offset = IOSRectCrop.clamped(
                offset: CGSize(
                  width: offset.width + value.translation.width,
                  height: offset.height + value.translation.height),
                imageSize: imageSize, frameSize: frameSize, zoom: zoom)
            }
            .simultaneously(
              with: MagnifyGesture()
                .updating($pinching) { value, state, _ in state = value.magnification }
                .onEnded { value in
                  zoom = min(max(zoom * value.magnification, 1), IOSRectCrop.maximumZoom)
                  offset = IOSRectCrop.clamped(
                    offset: offset, imageSize: imageSize, frameSize: frameSize, zoom: zoom)
                })
        )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Use Artwork") {
              done(
                IOSRectCrop.normalizedCrop(
                  imageSize: imageSize, frameSize: frameSize, zoom: zoom, offset: offset))
            }
          }
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}
