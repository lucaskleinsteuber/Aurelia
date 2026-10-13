import Foundation

/// The server, not a client path list, decides whether a mutation needs a proof.
/// A missing proof is rejected before dispatch, so exactly one retry is safe.
enum AdministrationRequestExecutor {
  static func execute(
    isolation: isolated (any Actor)? = #isolation,
    send: (_ approval: String?) async throws -> Data,
    approve: () async throws -> String
  ) async throws -> Data {
    do {
      return try await send(nil)
    } catch let failure as APIClientError
      where failure.httpStatus == 403 && failure.problemCode == "approval_required"
    {
      try Task.checkCancellation()
      let proof = try await approve()
      try Task.checkCancellation()
      return try await send(proof)
    }
  }

  static func action(baseURL: URL, path: String, method: String) throws -> String {
    guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      url.host == baseURL.host, url.scheme == baseURL.scheme, url.port == baseURL.port
    else { throw APIClientError.invalidAddress }
    let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
    return method + " " + components.percentEncodedPath + query
  }
}
