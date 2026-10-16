import Foundation

enum DeviceAuthorizationState: String, Decodable, Sendable {
  case pending, approved, denied, cancelled, expired, unknown

  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

struct DeviceAuthorizationStartResponse: Decodable, Sendable {
  let id: UUID
  let code: String
  let secret: String
  let expiresAt: String
  let pollIntervalSeconds: Int
}

struct DeviceAuthorizationPreview: Decodable, Sendable {
  let id: UUID
  let deviceName: String
  let serverId: UUID
  let serverName: String
  let state: DeviceAuthorizationState
  let expiresAt: String
}

struct DeviceAuthorizationStatusResponse: Decodable, Sendable {
  let state: DeviceAuthorizationState
  let expiresAt: String
  let pollIntervalSeconds: Int
  let authentication: AuthenticationResponse?
  let acknowledged: Bool
}
