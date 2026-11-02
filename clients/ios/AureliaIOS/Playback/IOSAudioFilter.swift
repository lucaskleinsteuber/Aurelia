import Foundation
@preconcurrency import MobileVLCKit
import os

/// Turns on a VLC audio filter for one player. MobileVLCKit has no public switch for this: a player's
/// audio output is created with the player and ignores the `--audio-filter` option. The filter
/// is set on the libvlc player object and the output is then recreated with libvlc's public
/// `libvlc_audio_output_set`, so it starts with the filter. Without these entry points the
/// caller reports unavailable processing instead of silently claiming it is active.
enum IOSAudioFilter {
  private typealias PlayerPointer = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
  private typealias SetVariable =
    @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, Int32, UnsafeMutableRawPointer?)
    -> Int32
  private typealias SetOutput =
    @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Int32

  private typealias FilterList =
    @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
  private typealias FreeList = @convention(c) (UnsafeMutableRawPointer) -> Void

  static func availableFilters(on player: VLCMediaPlayer) -> Set<String> {
    let symbols = UnsafeMutableRawPointer(bitPattern: -2)
    guard let listSymbol = dlsym(symbols, "libvlc_audio_filter_list_get"),
      let freeSymbol = dlsym(symbols, "libvlc_module_description_list_release")
    else { return [] }
    let list = unsafeBitCast(listSymbol, to: FilterList.self)
    let release = unsafeBitCast(freeSymbol, to: FreeList.self)
    guard let head = list(player.libraryInstance.instance) else { return [] }
    defer { release(head) }
    var result = Set<String>()
    var current: UnsafeMutableRawPointer? = head
    // libvlc_module_description_t has four char pointers followed by p_next.
    for _ in 0..<512 {
      guard let node = current else { break }
      if let name = node.load(as: UnsafePointer<CChar>?.self) {
        result.insert(String(cString: name))
      }
      current = node.load(
        fromByteOffset: 4 * MemoryLayout<UnsafeRawPointer>.size,
        as: UnsafeMutableRawPointer?.self)
    }
    return result
  }

  static func apply(_ processing: AudioProcessing, on player: VLCMediaPlayer, output: String)
    -> Bool
  {
    guard processing.missingFilters(in: availableFilters(on: player)).isEmpty else { return false }
    let equalizer = processing.dialogue == .off ? nil : VLCAudioEqualizer()
    if let equalizer {
      guard !equalizer.bands.isEmpty,
        equalizer.bands.allSatisfy({ $0.frequency.isFinite && $0.frequency > 0 })
      else {
        return false
      }
      equalizer.preAmplification = processing.dialogue.preamp
      for band in equalizer.bands {
        band.amplification = processing.dialogue.gain(at: band.frequency)
      }
    }
    player.equalizer = equalizer
    return enable(processing.filters.joined(separator: ":"), on: player, output: output)
  }

  /// VLC's public setter replaces the active output's filter chain as well.
  /// With compression active, reopen with the complete chain instead of erasing it.
  static func applyDialogue(
    _ mode: DialogueBoost, leveling: VolumeLeveling, on player: VLCMediaPlayer
  ) -> AudioChangeResult {
    guard mode == .off || availableFilters(on: player).contains("equalizer") else {
      return .unavailable
    }
    if leveling != .off { return .reloadRequired }
    let equalizer = mode == .off ? nil : VLCAudioEqualizer()
    if let equalizer {
      guard !equalizer.bands.isEmpty,
        equalizer.bands.allSatisfy({ $0.frequency.isFinite && $0.frequency > 0 })
      else {
        return .unavailable
      }
      equalizer.preAmplification = mode.preamp
      for band in equalizer.bands { band.amplification = mode.gain(at: band.frequency) }
    }
    player.equalizer = equalizer
    return .applied
  }

  /// VLC_VAR_STRING in libvlccore.
  private static let stringVariable: Int32 = 0x0040
  private static let logger = Logger(subsystem: "com.lucas.aurelia.ios", category: "Playback")

  @discardableResult
  static func enable(
    _ filter: String, on player: VLCMediaPlayer, output: String, recreateOutput: Bool = true
  ) -> Bool {
    let selector = NSSelectorFromString("libVLCMediaPlayer")
    let symbols = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    guard player.responds(to: selector),
      let setVariableSymbol = dlsym(symbols, "var_SetChecked"),
      let setOutputSymbol = dlsym(symbols, "libvlc_audio_output_set"),
      let mediaPlayer = unsafeBitCast(player.method(for: selector), to: PlayerPointer.self)(
        player, selector)
    else {
      logger.error("The \(filter, privacy: .public) audio filter is unavailable.")
      return false
    }
    let setVariable = unsafeBitCast(setVariableSymbol, to: SetVariable.self)
    let setOutput = unsafeBitCast(setOutputSymbol, to: SetOutput.self)
    // VLC copies the string, so the temporary copy is released right away.
    let value = strdup(filter)
    defer { free(value) }
    guard
      setVariable(mediaPlayer, "audio-filter", stringVariable, UnsafeMutableRawPointer(value))
        == 0,
      !recreateOutput || setOutput(mediaPlayer, output) == 0
    else {
      logger.error("The \(filter, privacy: .public) audio filter could not be enabled.")
      return false
    }
    return true
  }
}
