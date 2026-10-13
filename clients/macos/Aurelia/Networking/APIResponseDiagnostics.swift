import Foundation
import OSLog

/// Records only fixed categories and static Swift response types, never payloads.
enum APIResponseDiagnostics {
  private static let logger = Logger(subsystem: "com.lucas.aurelia.media", category: "APIContract")

  static func decodingFailure<Value>(_ type: Value.Type, error: Error) {
    let kind: String
    switch error {
    case DecodingError.keyNotFound: kind = "missing_field"
    case DecodingError.valueNotFound: kind = "missing_value"
    case DecodingError.typeMismatch: kind = "type_mismatch"
    case DecodingError.dataCorrupted: kind = "invalid_encoding"
    default: kind = "invalid_contract"
    }
    let contract = String(describing: type)
    logger.error(
      "response_contract_failed contract=\(contract, privacy: .public) kind=\(kind, privacy: .public)"
    )
  }
}
