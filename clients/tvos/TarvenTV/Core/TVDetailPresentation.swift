import Foundation

/// One person in Cast & Crew; several credits of the same person are merged.
struct TVPersonCard: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
  let subtitle: String?
  let profile: TVArtwork?
  let order: Int
}

/// Display projections shared with the Mac detail page. Raw server data is untouched.
enum TVDetailPresentation {
  static func people(_ credits: [TVCredit]) -> [TVPersonCard] {
    var groups: [String: [(Int, TVCredit)]] = [:]
    for (index, credit) in credits.enumerated() {
      let key =
        credit.personKey.flatMap { $0.isEmpty ? nil : $0 }
        ?? "unidentified:\(credit.id?.uuidString ?? String(index))"
      groups[key, default: []].append((index, credit))
    }
    var result: [(index: Int, card: TVPersonCard)] = []
    for (key, group) in groups {
      let ordered = group.sorted {
        $0.1.order == $1.1.order ? $0.0 < $1.0 : $0.1.order < $1.1.order
      }
      let actors = ordered.filter {
        $0.1.department.caseInsensitiveCompare("Acting") == .orderedSame
      }
      let primary = actors.first ?? ordered[0]
      let descriptions =
        actors.isEmpty
        ? ordered.map { $0.1.job ?? $0.1.department } : actors.compactMap(\.1.character)
      var seen = Set<String>()
      let labels = descriptions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
      result.append(
        (
          primary.0,
          TVPersonCard(
            id: key, name: primary.1.name,
            subtitle: labels.isEmpty ? nil : labels.joined(separator: ", "),
            profile: primary.1.profile ?? ordered.compactMap(\.1.profile).first,
            order: primary.1.order)
        ))
    }
    return result.sorted {
      $0.card.order == $1.card.order ? $0.index < $1.index : $0.card.order < $1.card.order
    }.map(\.card)
  }

  /// Trailers first, then everything else as Extras, keeping server order.
  static func supplementGroups(_ supplements: [TVSupplement]) -> [(
    title: String, items: [TVSupplement]
  )] {
    let isTrailer: (TVSupplement) -> Bool = {
      $0.item.kind == .trailer || $0.category.localizedCaseInsensitiveContains("trailer")
    }
    let trailers = supplements.filter(isTrailer)
    let extras = supplements.filter { !isTrailer($0) }
    return [
      trailers.isEmpty ? nil : ("Trailers", trailers),
      extras.isEmpty ? nil : ("Extras", extras),
    ].compactMap { $0 }
  }

  /// The Mac's Information fields; empty values are left out.
  static func information(_ detail: TVCatalogDetail) -> [(title: String, value: String)] {
    let metadata = detail.metadata
    let country = metadata.countries?.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let studio = (metadata.studios ?? []).isEmpty ? nil : metadata.studios?.joined(separator: ", ")
    let genres = metadata.genres.isEmpty ? nil : metadata.genres.joined(separator: ", ")
    let fsk = metadata.fskAge.map { "FSK \($0)" }
    let fields: [(String, String?)]
    if detail.item.kind == .series {
      let regular = detail.seasons.filter { $0.number > 0 }
      fields = [
        ("Seasons", regular.isEmpty ? nil : String(regular.count)),
        ("Episodes", String(detail.seasons.reduce(0) { $0 + $1.episodes.count })),
        ("Studio", studio), ("Released", metadata.year.map(String.init)),
        ("Country of Origin", country), ("Genres", genres),
        ("Rating", fsk ?? metadata.contentRating),
      ]
    } else {
      fields = [
        ("Runtime", metadata.runtimeMinutes.map { "\($0) min" }),
        ("Release Year", metadata.year.map(String.init)), ("Genres", genres), ("Studio", studio),
        ("Country of Origin", country), ("Rating", fsk ?? metadata.contentRating),
      ]
    }
    return fields.compactMap { title, value in value.map { (title, $0) } }
  }

  /// Up to `limit` genre shelves, alphabetical like the Mac Home page.
  static func genreRows(_ items: [TVCatalogItem], limit: Int = 3) -> [(
    genre: String, items: [TVCatalogItem]
  )] {
    guard limit > 0 else { return [] }
    var grouped: [String: [TVCatalogItem]] = [:]
    var seen: [String: Set<UUID>] = [:]
    for item in items {
      for genre in Set(item.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      where !genre.isEmpty && seen[genre, default: []].insert(item.id).inserted {
        grouped[genre, default: []].append(item)
      }
    }
    return grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      .prefix(limit).map { ($0, grouped[$0] ?? []) }
  }
}
