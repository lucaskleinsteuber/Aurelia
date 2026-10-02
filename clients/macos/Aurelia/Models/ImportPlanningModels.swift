import Foundation

enum ImportPreviewItemStatus: String, Codable, CaseIterable, Sendable {
  case recognized, pending, ignored, error
}

struct ImportAssignmentUpdate: Codable, Equatable, Sendable {
  var relativePath: String
  var isDirectory: Bool
  var kind: MediaKind?
  var parentRelativePath: String?
  var seasonNumber: Int?
  var episodeNumber: Int?
  var category: String?
  var title: String?
  var useAutomaticDetection = false
}

struct ImportAssignmentsRequest: Encodable, Sendable {
  let revision: String
  let assignments: [ImportAssignmentUpdate]
}

struct ImportAssignmentsSummary: Decodable, Sendable {
  let revision: String
  let assignments: [ImportAssignmentUpdate]
}

struct ConfirmImportPreviewRequest: Encodable, Sendable {
  let revision: String
}

struct ImportPreviewCounts: Codable, Equatable, Sendable {
  let files: Int
  let movies: Int
  let series: Int
  let episodes: Int
  let extras: Int
  let trailers: Int
  let pending: Int
  let ignored: Int
  let errors: Int
}

struct ImportPreviewTarget: Codable, Identifiable, Equatable, Sendable {
  let relativePath: String
  let title: String
  let kind: MediaKind
  let seasonNumbers: [Int]
  var id: String { relativePath }
}

struct ImportPreviewItem: Codable, Identifiable, Equatable, Sendable {
  let relativePath: String
  let title: String
  let kind: MediaKind?
  let parentRelativePath: String?
  let seasonNumber: Int?
  let episodeNumber: Int?
  let category: String?
  let status: ImportPreviewItemStatus
  let reason: String
  let isDirectory: Bool
  var id: String { "\(isDirectory ? "directory" : "file"):\(relativePath)" }
}

struct ImportPreviewSummary: Codable, Identifiable, Equatable, Sendable {
  let previewId: UUID
  let libraryId: UUID
  let revision: String
  let state: String
  let counts: ImportPreviewCounts
  let issues: [LibraryScanIssueSummary]
  let targets: [ImportPreviewTarget]
  var id: UUID { previewId }
}

struct ImportPreviewPage: Decodable, Sendable {
  let summary: ImportPreviewSummary
  let items: [ImportPreviewItem]
  let totalCount: Int
  let offset: Int
  let limit: Int
}
