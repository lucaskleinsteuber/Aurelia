import Foundation

// Both the VLC adapter and the synthetic driver submit raw samples here. Decoder
// state notifications alone are insufficient: VLC may remain in buffering while
// its clock and video continue to advance.
enum TVDecoderState: Equatable, Sendable {
  case opening, buffering, streamsAdded, playing, paused, stopped, ended, failed
}

struct TVDecoderSnapshot: Equatable, Sendable {
  let state: TVDecoderState
  let position: Int64?
  let duration: Int64?
  let isPlaying: Bool
  let isSeekable: Bool
}

struct TVPlaybackState: Equatable, Sendable {
  enum Phase: Equatable, Sendable { case idle, preparing, playing, paused, stalled, ended, failed }

  var phase: Phase = .idle
  var position: Int64 = 0
  var duration: Int64 = 0
  var isSeekable = false
  var hasObservedPlayback = false
  // A seek may change position, but only a plausible moving clock advances this.
  var progressPosition: Int64?
  var isPlaying: Bool { phase == .playing }
  var isLoading: Bool { phase == .preparing || phase == .stalled }
}

struct TVPlaybackStateMachine: Sendable {
  static let stallDelay: TimeInterval = 1.5
  private(set) var state = TVPlaybackState()
  private var active = false
  private var startedAt: TimeInterval = 0
  private var lastSampleAt: TimeInterval?
  private var lastClock: Int64?
  private var lastMotionAt: TimeInterval?
  private var pendingSeek: (target: Int64, requestedAt: TimeInterval)?
  private var wantsPlayback = true

  mutating func reset(at now: TimeInterval) {
    self = Self()
    active = true
    startedAt = now
    state.phase = .preparing
  }

  mutating func stop() {
    active = false
    pendingSeek = nil
    state.phase = .idle
  }

  mutating func setWantsPlayback(_ value: Bool) {
    wantsPlayback = value
    if !value, active { state.phase = .paused }
  }

  mutating func seek(to position: Int64, at now: TimeInterval) {
    guard active else { return }
    pendingSeek = (max(0, position), now)
    lastMotionAt = nil
    lastClock = nil
    state.hasObservedPlayback = false
  }

  @discardableResult
  mutating func update(
    _ sample: TVDecoderSnapshot, at now: TimeInterval, playbackRate: Double = 1
  ) -> TVPlaybackState {
    guard active, now.isFinite, lastSampleAt.map({ now >= $0 }) ?? true else { return state }
    guard state.phase != .ended, state.phase != .failed else { return state }
    let elapsed = max(0, now - (lastSampleAt ?? now))
    lastSampleAt = now
    if let duration = sample.duration, duration > 0 { state.duration = duration }
    state.isSeekable = sample.isSeekable
    let current = sample.position.flatMap { value -> Int64? in
      guard value >= 0 else { return nil }
      if sample.state == .ended || sample.state == .failed, value == 0, state.position > 0 {
        return nil
      }
      return value
    }
    var moving = false
    if let current {
      var acceptsClock = true
      if let seek = pendingSeek {
        // Do not mistake the original clock, or the eventual seek jump, for a
        // watched segment. A later sample must move normally from the new point.
        if abs(Double(current) - Double(seek.target)) <= 2_000 || now - seek.requestedAt >= 5 {
          pendingSeek = nil
          lastClock = current
        } else {
          acceptsClock = false
        }
      } else if let previous = lastClock, wantsPlayback,
        sample.state != .paused, sample.state != .failed, sample.state != .stopped,
        sample.state != .ended
      {
        let advance = Double(current) - Double(previous)
        let rate = playbackRate.isFinite ? min(max(playbackRate, 0.5), 2) : 1
        let maximum = max(1_500, elapsed * 1_000 * rate * 2 + 500)
        moving = advance > 0 && advance <= maximum
        if moving {
          lastMotionAt = now
          state.hasObservedPlayback = true
          state.progressPosition = state.duration > 0 ? min(current, state.duration) : current
        }
      }
      if acceptsClock {
        state.position = state.duration > 0 ? min(current, state.duration) : current
        lastClock = current
      }
    }

    switch sample.state {
    case .failed: state.phase = .failed
    case .ended: state.phase = .ended
    case .stopped: state.phase = .idle
    case .paused: state.phase = .paused
    default:
      if !wantsPlayback {
        state.phase = .paused
      } else if moving || lastMotionAt.map({ now - $0 < Self.stallDelay }) == true {
        state.phase = .playing
      } else if sample.state == .playing, lastMotionAt == nil,
        now - startedAt < Self.stallDelay, pendingSeek == nil
      {
        state.phase = .playing
      } else {
        state.phase = state.hasObservedPlayback ? .stalled : .preparing
      }
    }
    return state
  }
}

// Transport recovery is bounded even when a driver never emits a terminal
// event. Pauses and deliberate interaction suspend this timer.
struct TVPlaybackWatchdog: Sendable {
  let startupLimit: TimeInterval
  let stallLimit: TimeInterval
  private var waitingSince: TimeInterval?
  private var lastPosition: Int64?
  private var observedMotion = false

  init(startupLimit: TimeInterval = 30, stallLimit: TimeInterval = 12) {
    self.startupLimit = startupLimit
    self.stallLimit = stallLimit
  }

  mutating func reset(at now: TimeInterval) {
    waitingSince = now
    lastPosition = nil
    observedMotion = false
  }

  mutating func noteSeek(at now: TimeInterval) { waitingSince = now }

  mutating func shouldRecover(
    progressPosition: Int64?, wantsPlayback: Bool, interacting: Bool, at now: TimeInterval
  ) -> Bool {
    guard now.isFinite else { return false }
    if !wantsPlayback || interacting {
      waitingSince = now
      lastPosition = progressPosition
      return false
    }
    if let progressPosition, progressPosition != lastPosition {
      lastPosition = progressPosition
      waitingSince = now
      observedMotion = true
      return false
    }
    guard let waitingSince else {
      self.waitingSince = now
      return false
    }
    return now - waitingSince >= (observedMotion ? stallLimit : startupLimit)
  }
}
