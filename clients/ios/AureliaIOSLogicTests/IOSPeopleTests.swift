import Foundation
import Testing

/// People on iPhone and iPad ("people-v1"): the same words as on the Mac. Invented people only.
struct IOSPeopleTests {
  private func about(born: String?, died: String? = nil, place: String? = nil) -> IOSPersonAbout {
    IOSPersonAbout(
      biography: nil, birthday: born, deathday: died, placeOfBirth: place,
      knownForDepartment: "Acting",
      provider: "tmdb", providerPersonId: "17")
  }

  private var today: Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16))!
  }

  @Test func theLifeLineSaysBirthAgeAndPlace() {
    #expect(
      IOSPeoplePresentation.life(about(born: "1970-05-01", place: "Invented Town"), today: today)
        == "Born May 1, 1970 (age 56) in Invented Town")
    #expect(
      IOSPeoplePresentation.life(about(born: "1970-12-24"), today: today)
        == "Born December 24, 1970 (age 55)")
    #expect(
      IOSPeoplePresentation.life(
        about(born: "1931-02-08", died: "1955-09-30", place: "Invented Town"), today: today)
        == "February 8, 1931 – September 30, 1955 (aged 24) · Invented Town")
    #expect(
      IOSPeoplePresentation.life(about(born: nil, died: "2001-03-04"), today: today)
        == "Died March 4, 2001")
    #expect(IOSPeoplePresentation.life(about(born: "sometime"), today: today) == nil)
    #expect(IOSPeoplePresentation.life(nil, today: today) == nil)
  }

  @Test func aCardSaysTheJobOnlyForPeopleBehindTheCamera() {
    let actor = IOSPersonSummary(
      name: "Morgan Vale", personKey: "tmdb:person:17", profile: nil, titleCount: 3,
      department: "Acting")
    let director = IOSPersonSummary(
      name: "Theo Brandt", personKey: "tmdb:person:18", profile: nil, titleCount: 1,
      department: "Director")
    #expect(IOSPeoplePresentation.role(actor) == "3 titles")
    #expect(IOSPeoplePresentation.role(director) == "Director · 1 title")
    #expect(IOSPeoplePresentation.hasProfile("tmdb:person:17"))
    #expect(!IOSPeoplePresentation.hasProfile("unidentified:3"))
    #expect(!IOSPeoplePresentation.hasProfile(nil))
  }

  @Test func aProfileReadsAsTheServerWritesItAndAWishShowsAtOnce() throws {
    let profile = try JSONDecoder().decode(
      IOSPersonProfile.self,
      from: Data(
        #"{"about":{"biography":"An invented actor.","birthday":"1970-05-01","deathday":null,"placeOfBirth":"Invented Town","knownForDepartment":"Acting","provider":"tmdb","providerPersonId":"17"},"knownFor":[{"provider":"tmdb","providerMediaId":"200","kind":"movie","title":"Distant Shore","year":2018,"overview":null,"posterPath":"/shore.jpg","posterUrl":null,"alreadyInLibrary":false,"existingMediaId":null,"alreadyWished":false,"existingWishId":null,"supportedByCaller":false}]}"#
          .utf8))
    #expect(profile.about?.biography == "An invented actor.")
    let hit = try #require(profile.knownFor.first)
    let wishId = UUID()
    let wished = IOSPeoplePresentation.wished(hit, wishId: wishId)
    #expect(wished.alreadyWished && wished.supportedByCaller)
    #expect(wished.existingWishId == wishId)
    #expect(wished.title == "Distant Shore")
    let page = try JSONDecoder().decode(
      IOSPeoplePage.self,
      from: Data(
        #"{"items":[{"name":"Morgan Vale","personKey":"tmdb:person:17","profile":null,"titleCount":3,"department":"Acting"}],"total":1,"offset":0,"limit":60}"#
          .utf8))
    #expect(page.items.map(\.name) == ["Morgan Vale"])
  }
}
