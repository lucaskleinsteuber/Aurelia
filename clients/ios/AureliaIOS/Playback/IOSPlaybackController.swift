import AVKit
import Foundation
import SwiftUI
import UIKit

@MainActor
public final class IOSPlaybackController: ObservableObject {
  @Published public var isPlaying: Bool = false
  @Published public var isLoading: Bool = false
  @Published public var positionSeconds: Double = 0
  @Published public var durationSeconds: Double = 0
  @Published public var currentTitle: String = ""
  @Published public var currentSubtitle: String? = nil
  @Published public var showControls: Bool = true
  @Published public var isScrubbing: Bool = false
  @Published public var scrubPositionSeconds: Double = 0
  @Published public var upNextCountdown: Int? = nil

  public let engine: IOSPlaybackEngine
  private var relay: IOSStreamRelay?
  private var progressOutbox: IOSProgressOutbox?
  private var currentItemId: String?
  private var controlsHideTimer: Timer?
  private var progressTimer: Timer?
  private var upNextTimer: Timer?
  private var preferences = IOSPlaybackPreferences.defaultValue

  public init(engine: IOSPlaybackEngine = IOSVideoEngine()) {
    self.engine = engine
    self.engine.onUpdate = { [weak self] in
      self?.handleEngineUpdate()
    }
    self.engine.onEnded = { [weak self] in
      self?.handlePlaybackEnded()
    }
  }

  public func play(
    item: IOSCatalogItemSummary,
    plan: IOSStreamPlanResponse,
    fingerprint: String,
    authorizationToken: String?,
    apiClient: IOSAPIClient
  ) async {
    self.currentItemId = item.id
    self.currentTitle = item.title
    self.currentSubtitle =
      item.seriesTitle != nil
      ? "S\(item.seasonNumber ?? 1) E\(item.episodeNumber ?? 1)"
      : (item.releaseYear != nil ? "\(item.releaseYear!)" : nil)

    self.progressOutbox = IOSProgressOutbox(apiClient: apiClient)

    do {
      guard let sourceURL = URL(string: plan.streamUrl) else { return }
      let streamRelay = IOSStreamRelay(
        sourceURL: sourceURL,
        publicKeyFingerprint: fingerprint,
        authorizationToken: authorizationToken
      )
      self.relay = streamRelay
      let localURL = try await streamRelay.start()

      let resumeMs = Int64((plan.resumePositionSeconds ?? 0) * 1000)
      engine.play(url: localURL, resumeMilliseconds: resumeMs)

      // Attach sidecar subtitles if present
      for sub in plan.subtitleTracks where sub.isSidecar {
        if let subURL = streamRelay.subtitleURL(for: sub.id) {
          engine.addSubtitleSlave(url: subURL)
        }
      }

      startProgressLoop()
      resetControlsTimer()
    } catch {
      self.isLoading = false
    }
  }

  public func togglePlayPause() {
    engine.togglePlayPause()
    resetControlsTimer()
  }

  public func skip(seconds: Int) {
    let currentMs = Int64(positionSeconds * 1000)
    let durMs = Int64(durationSeconds * 1000)
    let targetMs = IOSPlayerPolicy.seekPosition(
      current: currentMs, offset: Int64(seconds * 1000), duration: durMs)
    engine.seek(toMilliseconds: targetMs)
    resetControlsTimer()
  }

  public func startScrubbing() {
    isScrubbing = true
    scrubPositionSeconds = positionSeconds
    controlsHideTimer?.invalidate()
  }

  public func updateScrub(position: Double) {
    scrubPositionSeconds = max(0, min(position, durationSeconds))
  }

  public func endScrubbing() {
    isScrubbing = false
    let targetMs = Int64(scrubPositionSeconds * 1000)
    engine.seek(toMilliseconds: targetMs)
    resetControlsTimer()
  }

  public func stop() {
    controlsHideTimer?.invalidate()
    controlsHideTimer = nil
    progressTimer?.invalidate()
    progressTimer = nil
    upNextTimer?.invalidate()
    upNextTimer = nil

    engine.stop()
    relay?.stop()
    relay = nil

    Task { [progressOutbox] in
      await progressOutbox?.flush()
    }

    self.isPlaying = false
    self.isLoading = false
    self.currentItemId = nil
  }

  private func handleEngineUpdate() {
    self.isPlaying = engine.isPlaying
    self.isLoading = engine.isLoading
    if !isScrubbing {
      self.positionSeconds = Double(engine.positionMilliseconds) / 1000.0
    }
    self.durationSeconds = Double(engine.durationMilliseconds) / 1000.0

    // Check for Up Next threshold near the end (15s before end)
    if durationSeconds > 30
      && (durationSeconds - positionSeconds) <= Double(preferences.upNextCountdownSeconds)
    {
      if upNextCountdown == nil {
        startUpNextCountdown()
      }
    }
  }

  private func handlePlaybackEnded() {
    if let itemId = currentItemId {
      Task { [progressOutbox] in
        await progressOutbox?.record(
          itemId: itemId,
          positionSeconds: durationSeconds,
          durationSeconds: durationSeconds,
          watched: true
        )
        await progressOutbox?.flush()
      }
    }
  }

  private func startProgressLoop() {
    progressTimer?.invalidate()
    progressTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let itemId = self.currentItemId, self.isPlaying else { return }
        let pos = self.positionSeconds
        let dur = self.durationSeconds
        let watched = dur > 0 && pos >= (dur - 15)
        await self.progressOutbox?.record(
          itemId: itemId,
          positionSeconds: pos,
          durationSeconds: dur,
          watched: watched
        )
        await self.progressOutbox?.flush()
      }
    }
  }

  private func startUpNextCountdown() {
    upNextCountdown = preferences.upNextCountdownSeconds
    upNextTimer?.invalidate()
    upNextTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let current = self.upNextCountdown else { return }
        if current > 1 {
          self.upNextCountdown = current - 1
        } else {
          self.upNextCountdown = nil
          self.upNextTimer?.invalidate()
          self.upNextTimer = nil
        }
      }
    }
  }

  public func resetControlsTimer() {
    controlsHideTimer?.invalidate()
    showControls = true
    guard isPlaying && !isScrubbing else { return }
    controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) {
      [weak self] _ in
      Task { @MainActor in
        self?.showControls = false
      }
    }
  }
}
