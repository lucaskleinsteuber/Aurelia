import Foundation

public enum IOSDecoderState: Equatable, Sendable {
  case opening, buffering, streamsAdded, playing, paused, stopped, ended, failed
}

public struct IOSDecoderSnapshot: Equatable, Sendable {
  public let state: IOSDecoderState
  public let positionMilliseconds: Int64?
  public let durationMilliseconds: Int64?
  public let isPlaying: Bool
  public let isSeekable: Bool

  public init(
    state: IOSDecoderState,
    positionMilliseconds: Int64? = nil,
    durationMilliseconds: Int64? = nil,
    isPlaying: Bool = false,
    isSeekable: Bool = false
  ) {
    self.state = state
    self.positionMilliseconds = positionMilliseconds
    self.durationMilliseconds = durationMilliseconds
    self.isPlaying = isPlaying
    self.isSeekable = isSeekable
  }
}

public struct IOSPlaybackState: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case idle, preparing, playing, paused, stalled, ended, failed
  }

  public var phase: Phase = .idle
  public var positionMilliseconds: Int64 = 0
  public var durationMilliseconds: Int64 = 0
  public var isSeekable = false
  public var hasObservedPlayback = false

  public var isPlaying: Bool { phase == .playing }
  public var isLoading: Bool { phase == .preparing || phase == .stalled }

  public init(
    phase: Phase = .idle,
    positionMilliseconds: Int64 = 0,
    durationMilliseconds: Int64 = 0,
    isSeekable: Bool = false,
    hasObservedPlayback: Bool = false
  ) {
    self.phase = phase
    self.positionMilliseconds = positionMilliseconds
    self.durationMilliseconds = durationMilliseconds
    self.isSeekable = isSeekable
    self.hasObservedPlayback = hasObservedPlayback
  }
}

public struct IOSPlaybackStateMachine: Sendable {
  public static let stallDelay: TimeInterval = 1.5
  public private(set) var state = IOSPlaybackState()
  private var active = false
  private var startedAt: TimeInterval = 0
  private var wantsPlayback = true

  public init() {}

  public mutating func reset(at now: TimeInterval) {
    self = Self()
    active = true
    startedAt = now
    state.phase = .preparing
  }

  public mutating func stop() {
    active = false
    state.phase = .idle
  }

  public mutating func setWantsPlayback(_ value: Bool) {
    wantsPlayback = value
    if !value && active {
      state.phase = .paused
    }
  }

  public mutating func sample(_ snapshot: IOSDecoderSnapshot, at now: TimeInterval) {
    guard active else { return }

    if let dur = snapshot.durationMilliseconds, dur > 0 {
      state.durationMilliseconds = dur
    }
    if let pos = snapshot.positionMilliseconds, pos >= 0 {
      state.positionMilliseconds = pos
    }
    state.isSeekable = snapshot.isSeekable

    switch snapshot.state {
    case .playing:
      state.hasObservedPlayback = true
      state.phase = wantsPlayback ? .playing : .paused
    case .paused:
      state.phase = .paused
    case .ended:
      state.phase = .ended
    case .failed:
      state.phase = .failed
    case .buffering, .opening, .streamsAdded:
      if state.hasObservedPlayback && wantsPlayback {
        state.phase = (now - startedAt > Self.stallDelay) ? .stalled : state.phase
      } else {
        state.phase = .preparing
      }
    case .stopped:
      if state.hasObservedPlayback {
        state.phase = .ended
      }
    }
  }
}
