import Foundation

struct PersonCardPresentation: Identifiable, Equatable {
  let id: String
  let name: String
  let subtitle: String?
  let profile: ArtworkSummary?
  let order: Int
}

enum CreditPresentation {
  /// The leading cast for a hero's "Starring" line: actors in billing order, each name once.
  static func starring(_ credits: [CreditSummary], limit: Int = 3) -> [String] {
    var seen: Set<String> = []
    return credits.enumerated()
      .filter { $0.element.department.caseInsensitiveCompare("Acting") == .orderedSame }
      .sorted {
        $0.element.order == $1.element.order
          ? $0.offset < $1.offset : $0.element.order < $1.element.order
      }
      .map { $0.element.name.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
      .prefix(limit)
      .map { $0 }
  }

  /// Display projection only: raw credits, jobs, order and manual editor data are untouched.
  static func people(_ credits: [CreditSummary]) -> [PersonCardPresentation] {
    var groups: [String: [(Int, CreditSummary)]] = [:]
    for (index, credit) in credits.enumerated() {
      let key =
        credit.personKey.flatMap { $0.isEmpty ? nil : $0 }
        ?? "unidentified:\(credit.creditId?.uuidString ?? String(index))"
      groups[key, default: []].append((index, credit))
    }
    var result: [(index: Int, card: PersonCardPresentation)] = []
    for (key, group) in groups {
      let ordered: [(Int, CreditSummary)] = group.sorted {
        $0.1.order == $1.1.order ? $0.0 < $1.0 : $0.1.order < $1.1.order
      }
      let actors = ordered.filter {
        $0.1.department.caseInsensitiveCompare("Acting") == .orderedSame
      }
      let primary: (Int, CreditSummary) = actors.first ?? ordered[0]
      let descriptions: [String] =
        actors.isEmpty
        ? ordered.map { $0.1.job ?? $0.1.department }
        : actors.compactMap { $0.1.character }
      var seen: Set<String> = []
      var labels: [String] = []
      for description in descriptions {
        let clean = description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !clean.isEmpty, seen.insert(clean).inserted { labels.append(clean) }
      }
      let photo: ArtworkSummary? = primary.1.profile ?? ordered.compactMap { $0.1.profile }.first
      let card = PersonCardPresentation(
        id: key, name: primary.1.name,
        subtitle: labels.isEmpty ? nil : labels.joined(separator: ", "),
        profile: photo, order: primary.1.order)
      result.append((index: primary.0, card: card))
    }
    result.sort {
      $0.card.order == $1.card.order ? $0.index < $1.index : $0.card.order < $1.card.order
    }
    return result.map(\.card)
  }
}
