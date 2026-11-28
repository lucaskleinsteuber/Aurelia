import AppKit
import SwiftUI

/// While an update downloads, the Dock icon carries a small bar, so the download can be followed
/// without a window in the way; Settings › Updates shows the details and Cancel.
@MainActor
enum AppUpdateDockProgress {
  private static var bar: NSProgressIndicator?

  static func show(_ fraction: Double?) {
    let tile = NSApp.dockTile
    if bar == nil {
      let image = NSImageView(image: NSApp.applicationIconImage)
      let indicator = NSProgressIndicator()
      indicator.style = .bar
      indicator.isIndeterminate = false
      indicator.minValue = 0
      indicator.maxValue = 1
      let container = NSView(frame: NSRect(origin: .zero, size: tile.size))
      image.frame = container.bounds
      indicator.frame = NSRect(x: 8, y: 6, width: tile.size.width - 16, height: 14)
      container.addSubview(image)
      container.addSubview(indicator)
      tile.contentView = container
      bar = indicator
    }
    if let fraction {
      bar?.isIndeterminate = false
      bar?.doubleValue = fraction
    } else {
      bar?.isIndeterminate = true
    }
    tile.display()
  }

  static func clear() {
    guard bar != nil else { return }
    bar = nil
    NSApp.dockTile.contentView = nil
    NSApp.dockTile.display()
  }
}

/// The bar and the line under it in Settings › Updates.
struct AppUpdateProgressBar: View {
  @ObservedObject var updater: AppUpdater

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if updater.state == .downloading, let fraction = updater.progress?.fraction {
        ProgressView(value: fraction)
          .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("update-progress")
  }

  private var detail: String {
    switch updater.state {
    case .downloading:
      guard let progress = updater.progress, progress.received > 0 else {
        return "Connecting to GitHub…"
      }
      if let fraction = progress.fraction {
        return "\(progress.text) (\(Int((fraction * 100).rounded()))%)"
      }
      return progress.text
    case .installing:
      return "Tarven closes and opens again by itself in a moment. Your library and settings stay."
    default:
      return ""
    }
  }

  static func headline(_ updater: AppUpdater) -> String {
    let name =
      updater.installingRelease.map {
        "Tarven \($0.version)\($0.isBeta ? " Beta" : "")"
      } ?? "the update"
    return updater.state == .installing ? "Installing \(name)…" : "Downloading \(name)…"
  }
}
