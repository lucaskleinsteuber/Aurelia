#if DEBUG
  import AppKit
  import SwiftUI

  enum ServerSettingsVisualProbe {
    @MainActor static func render() async throws -> Data {
      let previous = AppModel.active
      defer { AppModel.active = previous }
      let model = AppModel.serverSettingsRenderPreview()
      let view = NSHostingView(
        rootView: ServerManagementView(showsAdvanced: true).environmentObject(model)
          .padding(24).frame(width: 712, alignment: .topLeading)
          .background(AureliaDesign.canvas).environment(\.colorScheme, .dark))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 712, height: 640),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = view
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .seconds(2))
      let size = view.fittingSize
      guard size.height > 2500 else {
        throw NSError(
          domain: "ServerSettingsRender", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "Incomplete native layout: \(size.height) points."
          ])
      }
      view.setFrameSize(NSSize(width: 712, height: size.height))
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw NSError(
          domain: "ServerSettingsRender", code: 2,
          userInfo: [
            NSLocalizedDescriptionKey: "Native bitmap creation failed."
          ])
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 10_000 else {
        throw NSError(
          domain: "ServerSettingsRender", code: 3,
          userInfo: [
            NSLocalizedDescriptionKey: "Native PNG encoding was empty."
          ])
      }
      return png
    }

    static func validatedOutput(_ path: String, allowsEmptyOutputDescriptor: Bool = false) throws
      -> URL
    {
      let supplied = URL(fileURLWithPath: path)
      let cache =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library/Caches/Aurelia/TestRuns", isDirectory: true
        ).path + "/"
      if allowsEmptyOutputDescriptor {
        guard path.hasPrefix(cache) || path.hasPrefix("/private/tmp/Aurelia/"),
          supplied.pathExtension == "png", !supplied.pathComponents.contains("..")
        else { throw APIClientError.invalidResponse }
        // No path is opened by the app in descriptor mode. Sandboxed symlink
        // resolution cannot inspect the external directory opened by Launch Services.
        return supplied
      }
      let url = supplied.standardizedFileURL.resolvingSymlinksInPath()
      guard url.path.hasPrefix(cache) || url.path.hasPrefix("/private/tmp/Aurelia/"),
        url.pathExtension == "png"
      else {
        throw NSError(
          domain: "ServerSettingsRender", code: 4,
          userInfo: [
            NSLocalizedDescriptionKey: "The render output is outside an isolated test directory."
          ])
      }
      // Descriptor mode does not open or replace a path in the sandboxed app.
      // Launch Services already opened stdout in the test script's own directory.
      if !allowsEmptyOutputDescriptor && FileManager.default.fileExists(atPath: url.path) {
        throw NSError(
          domain: "ServerSettingsRender", code: 5,
          userInfo: [
            NSLocalizedDescriptionKey: "The render output already exists."
          ])
      }
      return url
    }
  }
#endif
