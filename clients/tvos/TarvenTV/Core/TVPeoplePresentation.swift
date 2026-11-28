import Foundation

/// What People and a person's page say, in the Mac app's words ("people-v1").
enum TVPeoplePresentation {
  static let pageSize = 60

  /// "3 titles", or "Director · 1 title" for someone behind the camera.
  static func role(_ person: TVPersonSummary) -> String {
    let titles = "\(person.titleCount) \(person.titleCount == 1 ? "title" : "titles")"
    guard let department = person.department, !department.isEmpty, department != "Acting" else {
      return titles
    }
    return "\(department) · \(titles)"
  }

  /// Only a person TMDB identified has a life to show.
  static func hasProfile(_ key: String?) -> Bool {
    key?.lowercased().hasPrefix("tmdb:person:") == true
  }

  /// "Born May 1, 1970 (age 56) in Invented Town", or both dates for someone who died. TMDB writes
  /// dates as YYYY-MM-DD; anything else is left out.
  static func life(_ about: TVPersonAbout?, today: Date = Date(), calendar: Calendar = .current)
    -> String?
  {
    guard let about else { return nil }
    let born = day(about.birthday)
    let died = day(about.deathday)
    let trimmedPlace = about.placeOfBirth?.trimmingCharacters(in: .whitespacesAndNewlines)
    let place = trimmedPlace?.isEmpty == false ? trimmedPlace : nil
    if let born, let died {
      let line = "\(format(born)) – \(format(died)) (aged \(age(from: born, to: died)))"
      return place.map { "\(line) · \($0)" } ?? line
    }
    if let born {
      let parts = calendar.dateComponents([.year, .month, .day], from: today)
      let line = "Born \(format(born)) (age \(age(from: born, to: parts)))"
      return place.map { "\(line) in \($0)" } ?? line
    }
    if let died { return "Died \(format(died))" }
    return place.map { "Born in \($0)" }
  }

  /// A Known For title after this profile wished for it.
  static func wished(_ hit: TVWishSearchHit, wishId: UUID?) -> TVWishSearchHit {
    TVWishSearchHit(
      provider: hit.provider, providerMediaId: hit.providerMediaId, kind: hit.kind,
      title: hit.title,
      year: hit.year, overview: hit.overview, posterPath: hit.posterPath, posterUrl: hit.posterUrl,
      alreadyInLibrary: hit.alreadyInLibrary, existingMediaId: hit.existingMediaId,
      alreadyWished: true, existingWishId: wishId ?? hit.existingWishId, supportedByCaller: true)
  }

  private static func day(_ text: String?) -> DateComponents? {
    guard let text, text.count == 10 else { return nil }
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
      return nil
    }
    return DateComponents(year: parts[0], month: parts[1], day: parts[2])
  }

  private static func age(from born: DateComponents, to day: DateComponents) -> Int {
    guard let bornYear = born.year, let year = day.year else { return 0 }
    let beforeBirthday = (day.month ?? 0, day.day ?? 0) < (born.month ?? 0, born.day ?? 0)
    return max(0, year - bornYear - (beforeBirthday ? 1 : 0))
  }

  private static func format(_ components: DateComponents) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    guard let date = calendar.date(from: components) else { return "" }
    return date.formatted(
      Date.FormatStyle(date: .long, time: .omitted, timeZone: calendar.timeZone)
        .locale(Locale(identifier: "en_US")))
  }
}
