import Foundation
import XCTest

@testable import Aurelia

/// People on the Mac ("people-v1"): what a person's card and page say. Invented people only.
final class PeopleTextTests: XCTestCase {
  private func about(born: String?, died: String? = nil, place: String? = nil) -> PersonAbout {
    PersonAbout(
      biography: nil, birthday: born, deathday: died, placeOfBirth: place, knownForDepartment: "Acting",
      provider: "tmdb", providerPersonId: "17")
  }

  private var today: Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))!
  }

  func testTheLifeLineSaysBirthAgeAndPlace() {
    XCTAssertEqual(
      PeoplePresentation.life(about(born: "1970-05-01", place: "Invented Town"), today: today),
      "Born May 1, 1970 (age 56) in Invented Town")
    // The birthday later in the year has not come yet.
    XCTAssertEqual(PeoplePresentation.life(about(born: "1970-12-24"), today: today), "Born December 24, 1970 (age 55)")
    XCTAssertEqual(
      PeoplePresentation.life(about(born: "1931-02-08", died: "1955-09-30", place: "Invented Town"), today: today),
      "February 8, 1931 – September 30, 1955 (aged 24) · Invented Town")
    XCTAssertEqual(PeoplePresentation.life(about(born: nil, died: "2001-03-04"), today: today), "Died March 4, 2001")
    XCTAssertEqual(PeoplePresentation.life(about(born: nil, place: "Invented Town"), today: today), "Born in Invented Town")
    XCTAssertNil(PeoplePresentation.life(about(born: "sometime"), today: today))
    XCTAssertNil(PeoplePresentation.life(nil, today: today))
  }

  func testACardSaysTheJobOnlyForPeopleBehindTheCamera() {
    let actor = PersonSummary(name: "Morgan Vale", personKey: "tmdb:person:17", profile: nil, titleCount: 3, department: "Acting")
    let director = PersonSummary(name: "Theo Brandt", personKey: "tmdb:person:18", profile: nil, titleCount: 1, department: "Director")
    XCTAssertEqual(PeoplePresentation.role(actor), "3 titles")
    XCTAssertEqual(PeoplePresentation.role(director), "Director · 1 title")
    XCTAssertEqual(director.selection.personKey, "tmdb:person:18")
  }

  func testAPeoplePageAndAProfileReadAsTheServerWritesThem() throws {
    let page = try JSONDecoder().decode(
      PeoplePageResponse.self,
      from: Data(
        #"{"items":[{"name":"Morgan Vale","personKey":"tmdb:person:17","profile":null,"titleCount":3,"department":"Acting"}],"total":1,"offset":0,"limit":60}"#
          .utf8))
    XCTAssertEqual(page.items.first?.name, "Morgan Vale")
    let profile = try JSONDecoder().decode(
      PersonProfileResponse.self,
      from: Data(
        #"{"about":{"biography":"An invented actor.","birthday":"1970-05-01","deathday":null,"placeOfBirth":"Invented Town","knownForDepartment":"Acting","provider":"tmdb","providerPersonId":"17"},"knownFor":[{"provider":"tmdb","providerMediaId":"200","kind":"movie","title":"Distant Shore","year":2018,"overview":null,"posterPath":"/shore.jpg","posterUrl":null,"alreadyInLibrary":false,"existingMediaId":null,"alreadyWished":false,"existingWishId":null,"supportedByCaller":false}]}"#
          .utf8))
    XCTAssertEqual(profile.about?.placeOfBirth, "Invented Town")
    XCTAssertEqual(profile.knownFor.map(\.title), ["Distant Shore"])
  }
}
