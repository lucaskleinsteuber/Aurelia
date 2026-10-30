import AVKit
import SwiftUI
import UIKit

public struct IOSVideoSurfaceView: UIViewRepresentable {
  let engine: IOSPlaybackEngine

  public init(engine: IOSPlaybackEngine) {
    self.engine = engine
  }

  public func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .black
    engine.attach(to: view)
    return view
  }

  public func updateUIView(_ uiView: UIView, context: Context) {}
}

public struct IOSAirPlayRoutePicker: UIViewRepresentable {
  public init() {}

  public func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.tintColor = .white
    picker.activeTintColor = .systemTeal
    return picker
  }

  public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

public struct IOSPlayerView: View {
  @ObservedObject var controller: IOSPlaybackController
  let onDismiss: () -> Void

  public init(controller: IOSPlaybackController, onDismiss: @escaping () -> Void) {
    self.controller = controller
    self.onDismiss = onDismiss
  }

  public var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      IOSVideoSurfaceView(engine: controller.engine)
        .ignoresSafeArea()
        .onTapGesture {
          controller.resetControlsTimer()
        }

      if controller.isLoading {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle(tint: .white))
          .scaleEffect(1.5)
      }

      if controller.showControls {
        controlsOverlay
          .transition(.opacity)
      }

      if let countdown = controller.upNextCountdown {
        upNextBanner(countdown: countdown)
      }
    }
    .statusBarHidden(!controller.showControls)
  }

  private var controlsOverlay: some View {
    VStack {
      // Top bar
      HStack {
        Button(action: {
          controller.stop()
          onDismiss()
        }) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 28))
            .foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityLabel("Close Player")

        Spacer()

        VStack {
          Text(controller.currentTitle)
            .font(.headline)
            .foregroundStyle(.white)
          if let sub = controller.currentSubtitle {
            Text(sub)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.7))
          }
        }

        Spacer()

        IOSAirPlayRoutePicker()
          .frame(width: 32, height: 32)
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .background(
        LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
      )

      Spacer()

      // Center transport controls
      HStack(spacing: 40) {
        Button(action: { controller.skip(seconds: -10) }) {
          Image(systemName: "gobackward.10")
            .font(.system(size: 36))
            .foregroundStyle(.white)
        }
        .accessibilityLabel("Skip back 10 seconds")

        Button(action: { controller.togglePlayPause() }) {
          Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 48))
            .foregroundStyle(.white)
        }
        .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

        Button(action: { controller.skip(seconds: 10) }) {
          Image(systemName: "goforward.10")
            .font(.system(size: 36))
            .foregroundStyle(.white)
        }
        .accessibilityLabel("Skip forward 10 seconds")
      }

      Spacer()

      // Bottom scrubber & times
      VStack(spacing: 8) {
        Slider(
          value: Binding(
            get: {
              controller.isScrubbing ? controller.scrubPositionSeconds : controller.positionSeconds
            },
            set: { controller.updateScrub(position: $0) }
          ),
          in: 0...max(1, controller.durationSeconds),
          onEditingChanged: { editing in
            if editing {
              controller.startScrubbing()
            } else {
              controller.endScrubbing()
            }
          }
        )
        .tint(.white)

        HStack {
          let currentMs = Int64(
            (controller.isScrubbing ? controller.scrubPositionSeconds : controller.positionSeconds)
              * 1000)
          let durMs = Int64(controller.durationSeconds * 1000)
          Text(IOSPlayerPolicy.formatTime(milliseconds: currentMs))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))

          Spacer()

          if let end = IOSPlayerPolicy.endTimeLabel(position: currentMs, duration: durMs) {
            Text(end)
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.6))
          }

          Spacer()

          let remMs = max(0, durMs - currentMs)
          Text("-\(IOSPlayerPolicy.formatTime(milliseconds: remMs))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 24)
      .background(
        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
      )
    }
  }

  private func upNextBanner(countdown: Int) -> some View {
    VStack {
      Spacer()
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Up Next")
            .font(.caption.bold())
            .foregroundStyle(.white.opacity(0.8))
          Text("Next episode in \(countdown)s")
            .font(.subheadline)
            .foregroundStyle(.white)
        }
        Spacer()
        Button("Play Now") {
          controller.stop()
          onDismiss()
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(.black)
      }
      .padding()
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .padding(.horizontal, 20)
      .padding(.bottom, 80)
    }
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }
}
