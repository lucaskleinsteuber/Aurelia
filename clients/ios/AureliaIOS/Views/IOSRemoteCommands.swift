import SwiftUI

/// The Apple TV code this app shares its screens with reacts to the Siri Remote's Menu, arrow and
/// Play/Pause buttons. On iPhone and iPad these come from touch controls and a hardware keyboard
/// instead: arrows and Space work with a keyboard, the rest is ignored.
enum IOSMoveDirection {
  case up, down, left, right
}

extension View {
  func iosBackCommand(perform action: (() -> Void)?) -> some View {
    onKeyPress(.escape) {
      guard let action else { return .ignored }
      action()
      return .handled
    }
  }

  func iosMoveCommand(perform action: ((IOSMoveDirection) -> Void)?) -> some View {
    onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
      guard let action else { return .ignored }
      switch press.key {
      case .upArrow: action(.up)
      case .downArrow: action(.down)
      case .leftArrow: action(.left)
      default: action(.right)
      }
      return .handled
    }
  }

  func iosPlayPauseCommand(perform action: (() -> Void)?) -> some View {
    onKeyPress(.space) {
      guard let action else { return .ignored }
      action()
      return .handled
    }
  }
}
