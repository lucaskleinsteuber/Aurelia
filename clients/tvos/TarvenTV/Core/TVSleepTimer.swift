import Foundation

enum TVSleepTimer: Equatable, Sendable {
  case off, endOfEpisode
  case minutes(Int)

  var title: String {
    switch self {
    case .off: "Off"
    case .endOfEpisode: "At End of Episode"
    case .minutes(let value): "\(value) minutes"
    }
  }
}
