import Foundation

struct ArtworkCrop: Codable, Equatable, Sendable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var rotation: Int = 0
}
struct EditorArtwork: Codable, Equatable, Sendable {
  var assetId: UUID?
  var uploadId: UUID?
  var crop: ArtworkCrop?
}
struct EditorCredit: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var department: String
  var job: String?
  var character: String?
  var profile: EditorArtwork?
  var personKey: String? = nil
}
struct MediaEditorValues: Codable, Equatable, Sendable {
  var title = ""
  var releaseYear: Int?
  var overview: String?
  var runtimeMinutes: Int?
  var fskAge: Int?
  var genres: [String] = []
  var studios: [String] = []
  var country: String?
  var credits: [EditorCredit] = []
  var poster: EditorArtwork?
  var backdrop: EditorArtwork?
}
struct MediaEditorDocument: Codable, Sendable {
  let mediaId: UUID
  let libraryId: UUID
  let kind: MediaKind
  let revision: Int64
  let values: MediaEditorValues
  let overrideFields: [String]
  let sourcePath: String
  let relativeSourcePath: String
  let automaticValues: MediaEditorValues
}
struct SaveMediaEditorRequest: Encodable, Sendable {
  let revision: Int64
  let values: MediaEditorValues
  let overrideFields: [String]
  let relativeSourcePath: String?
}
struct EditorUploadSummary: Decodable, Sendable {
  let id: UUID
  let path: String
  let width: Int
  let height: Int
}
struct ServerFileEntry: Decodable, Identifiable, Sendable {
  let name: String
  let relativePath: String
  let isDirectory: Bool
  let bytes: Int64?
  var id: String { relativePath }
}
struct ServerFileListing: Decodable, Sendable {
  let libraryId: UUID
  let relativePath: String
  let entries: [ServerFileEntry]
}
struct ExcludedMediaSummary: Decodable, Identifiable, Sendable {
  let id: UUID
  let libraryId: UUID
  let relativePath: String
  let isDirectory: Bool
}
struct ResetLibraryRequest: Encodable, Sendable {
  let libraryIds: [UUID]
  let revision: String
}
struct ResetLibraryPreview: Decodable, Sendable {
  let libraryIds: [UUID]
  let revision: String
  let titles: Int
  let files: Int
  let artwork: Int
  let storageLocations: Int
}
struct LibraryMutationResult: Decodable, Sendable {
  let id: UUID
  let state: String
  let removedItems: Int
  let error: String?
}
