#if DEBUG
  import Foundation

  // In-memory editor fixtures never contact an installed server or persist user metadata.
  @MainActor enum MetadataEditorUITestFixture {
    private static var documents: [UUID: MediaEditorDocument] = [:]
    private struct Request: Decodable {
      let revision: Int64
      let values: MediaEditorValues
      let overrideFields: [String]
    }

    static func response(path: String, method: String, body: Data?) throws -> Data {
      if path == "/api/v1/metadata/reviews" { return Data("[]".utf8) }
      let segments = path.split(separator: "/")
      guard segments.count == 5, let id = UUID(uuidString: String(segments[3])) else {
        throw APIClientError.invalidResponse
      }
      var document = documents[id] ?? initial(id: id)
      if method == "PUT" {
        guard let body else { throw APIClientError.invalidResponse }
        let request = try JSONDecoder().decode(Request.self, from: body)
        guard document.revision == request.revision else {
          throw APIClientError.serverRejected(
            code: "editor_conflict", message: "The synthetic editor revision changed.")
        }
        document = MediaEditorDocument(
          mediaId: id, libraryId: document.libraryId, kind: document.kind,
          revision: document.revision + 1, values: request.values,
          overrideFields: request.overrideFields,
          sourcePath: document.sourcePath, relativeSourcePath: document.relativeSourcePath,
          automaticValues: document.automaticValues)
        documents[id] = document
      } else if method != "GET" {
        throw APIClientError.invalidResponse
      }
      if path.hasSuffix("/editor") { return try JSONEncoder().encode(document) }
      let value = document.values
      return try JSONSerialization.data(withJSONObject: [
        "mediaId": id.uuidString, "title": value.title, "originalTitle": NSNull(),
        "overview": value.overview as Any? ?? NSNull(), "releaseDate": NSNull(),
        "year": value.releaseYear as Any? ?? NSNull(),
        "runtimeMinutes": value.runtimeMinutes as Any? ?? NSNull(),
        "rating": NSNull(), "contentRating": NSNull(), "genres": value.genres,
        "studios": value.studios,
        "countries": value.country.map { [$0] } ?? [], "credits": [],
        "poster": NSNull(), "backdrop": NSNull(), "still": NSNull(),
        "provider": NSNull(), "providerMediaId": NSNull(), "reviewState": "matched",
        "fskAge": NSNull(),
      ])
    }

    private static func initial(id: UUID) -> MediaEditorDocument {
      let series = id.uuidString.hasPrefix("20000000")
      let episode = id.uuidString.hasSuffix("0010")
      var values = MediaEditorValues()
      values.title = series ? episode ? "Pilot" : "Breaking Bad" : "El Camino"
      values.releaseYear = series ? 2008 : 2019
      values.runtimeMinutes = series ? nil : 122
      values.overview = "Synthetic editor data. No personal library is connected."
      values.genres = ["Drama"]
      values.studios = ["Test Studio"]
      values.country = "US"
      values.credits = [
        EditorCredit(
          id: UUID(), name: "Test Actor", department: "Acting", job: "Actor",
          character: "Main Character")
      ]
      return MediaEditorDocument(
        mediaId: id, libraryId: UUID(), kind: series ? episode ? .episode : .series : .movie,
        revision: 1, values: values, overrideFields: [], sourcePath: "/synthetic/Movies/Test.mkv",
        relativeSourcePath: "Test.mkv", automaticValues: values)
    }
  }
#endif
