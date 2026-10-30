import Foundation
@preconcurrency import MobileVLCKit
import os

/// Turns on a VLC audio filter for one player. MobileVLCKit has no public switch for this: a player's
/// audio output is created with the player and ignores the `--audio-filter` option. The filter
/// is set on the libvlc player object and the output is then recreated with libvlc's public
/// `libvlc_audio_output_set`, so it starts with the filter. Without these entry points the
/// player simply plays without the filter.
enum IOSAudioFilter {
  private typealias PlayerPointer = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
  private typealias SetVariable =
    @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, Int32, UnsafeMutableRawPointer?)
    -> Int32
  private typealias SetOutput =
    @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Int32

  /// VLC_VAR_STRING in libvlccore.
  private static let stringVariable: Int32 = 0x0040
  private static let logger = Logger(subsystem: "com.lucas.aurelia.ios", category: "Playback")

  @discardableResult
  static func enable(_ filter: String, on player: VLCMediaPlayer, output: String) -> Bool {
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
      setOutput(mediaPlayer, output) == 0
    else {
      logger.error("The \(filter, privacy: .public) audio filter could not be enabled.")
      return false
    }
    return true
  }
}
