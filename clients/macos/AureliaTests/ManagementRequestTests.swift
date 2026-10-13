import Foundation
import Testing

@testable import Aurelia

@MainActor
struct ManagementRequestTests {
  @Test func serverRequiredProofIsObtainedWithoutPasswordAndRetriedOnce() async throws {
    var requests: [String?] = []
    var approvals = 0
    let result = try await AdministrationRequestExecutor.execute { proof in
      requests.append(proof)
      if proof == nil { throw missingProof() }
      return Data([42])
    } approve: {
      approvals += 1
      return "synthetic-one-use-proof"
    }
    #expect(result == Data([42]))
    #expect(requests.count == 2)
    #expect(requests.first! == nil)
    #expect(requests.last! == "synthetic-one-use-proof")
    #expect(approvals == 1)
  }

  @Test func ordinaryRequestsNeverRequestAnAdministrationProof() async throws {
    var approvals = 0
    let result = try await AdministrationRequestExecutor.execute { _ in
      Data([1])
    } approve: {
      approvals += 1
      return "not-needed"
    }
    #expect(result == Data([1]))
    #expect(approvals == 0)
  }

  @Test(arguments: [
    APIClientError.serverIdentityMismatch,
    APIClientError.invalidResponse,
    APIClientError.httpFailure(
      status: 401, retryAfter: nil, code: "profile_session_expired", message: nil),
    APIClientError.httpFailure(
      status: 403, retryAfter: nil, code: "management_locked", message: nil),
    APIClientError.httpFailure(status: 403, retryAfter: nil, code: "owner_required", message: nil),
  ])
  func unrelatedFailuresNeverTriggerAnApprovalOrAnAutomaticMutationRetry(failure: APIClientError)
    async throws
  {
    var requests = 0
    var approvals = 0
    do {
      _ = try await AdministrationRequestExecutor.execute { _ in
        requests += 1
        throw failure
      } approve: {
        approvals += 1
        return "not-allowed"
      }
      Issue.record("The original failure must remain visible.")
    } catch let error as APIClientError { #expect(error == failure) }
    #expect(requests == 1)
    #expect(approvals == 0)
  }

  @Test func rejectionAfterProofCannotLoopOrHideManagementExpiry() async throws {
    var requests = 0
    var approvals = 0
    do {
      _ = try await AdministrationRequestExecutor.execute { _ in
        requests += 1
        throw missingProof()
      } approve: {
        approvals += 1
        return "expired-proof"
      }
      Issue.record("A rejected proof must not be retried repeatedly.")
    } catch let error as APIClientError { #expect(error.problemCode == "approval_required") }
    #expect(requests == 2)
    #expect(approvals == 1)
  }

  @Test func actionUsesTheExactEncodedTargetIncludingQuery() throws {
    let action = try AdministrationRequestExecutor.action(
      baseURL: URL(string: "https://server.invalid:43111")!,
      path: "/api/v1/users/a%2Fb/profile?revision=7&name=a%20b", method: "PUT")
    #expect(action == "PUT /api/v1/users/a%2Fb/profile?revision=7&name=a%20b")
    #expect(throws: APIClientError.self) {
      try AdministrationRequestExecutor.action(
        baseURL: URL(string: "https://server.invalid")!, path: "https://other.invalid/private",
        method: "POST")
    }
  }

  @Test func managementLockIsNotAProfileAuthenticationFailure() {
    let locked = APIClientError.httpFailure(
      status: 403, retryAfter: nil, code: "management_locked", message: nil)
    #expect(locked.isManagementLocked)
    #expect(!locked.isAuthenticationFailure)
    #expect(
      APIClientError.httpFailure(
        status: 403, retryAfter: nil, code: "access_rejected", message: nil
      ).isAuthenticationFailure)
  }

  private func missingProof() -> APIClientError {
    .httpFailure(status: 403, retryAfter: nil, code: "approval_required", message: nil)
  }
}
