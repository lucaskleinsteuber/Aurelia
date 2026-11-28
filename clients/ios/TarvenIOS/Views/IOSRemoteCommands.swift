import SwiftUI

/// The Apple TV code this app shares its screens with reacts to the Siri Remote's Menu, arrow and
/// Play/Pause buttons. On iPhone and iPad these come from touch controls and a hardware keyboard
/// instead: arrows and Space work with a keyboard, the rest is ignored.
enum IOSMoveDirection {
  case up, down, left, right
}

extension View {
  // Keyboard shortcuts, not onKeyPress: a key press reaches onKeyPress only while something has
  // the focus, and on iPad nothing does on most screens (the PIN screen ignored Esc).
  func iosBackCommand(perform action: (() -> Void)?) -> some View {
    background { IOSKeyCommand(key: .escape, action: action) }
  }

  func iosMoveCommand(perform action: ((IOSMoveDirection) -> Void)?) -> some View {
    background {
      ZStack {
        IOSKeyCommand(key: .upArrow, action: action.map { act in { act(.up) } })
        IOSKeyCommand(key: .downArrow, action: action.map { act in { act(.down) } })
        IOSKeyCommand(key: .leftArrow, action: action.map { act in { act(.left) } })
        IOSKeyCommand(key: .rightArrow, action: action.map { act in { act(.right) } })
      }
    }
  }

  func iosPlayPauseCommand(perform action: (() -> Void)?) -> some View {
    background { IOSKeyCommand(key: .space, action: action) }
  }
}

/// An invisible button that only answers a key of a hardware keyboard.
struct IOSKeyCommand: View {
  let key: KeyEquivalent
  let action: (() -> Void)?

  var body: some View {
    if let action {
      Button("", action: action)
        .keyboardShortcut(key, modifiers: [])
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}
