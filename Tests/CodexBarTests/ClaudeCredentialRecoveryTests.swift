import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCredentialRecoveryTests {
    @Test(arguments: [
        ClaudeOAuthUnreadableCredentialsError.descriptionPrefix,
        ClaudeOAuthCredentialsError.missingOAuth.localizedDescription,
        ClaudeOAuthCredentialsError.missingAccessToken.localizedDescription,
        ClaudeOAuthCredentialsError.notFound.localizedDescription,
        ClaudeOAuthCredentialsError.keychainAccessRevoked.localizedDescription,
        ClaudeOAuthCredentialsError.noRefreshToken.localizedDescription,
        ClaudeOAuthCredentialsError.decodeFailed.localizedDescription,
        ClaudeOAuthCredentialsError.mcpOAuthOnlyKeychain.localizedDescription,
        ClaudeOAuthCredentialsError.keychainError(-128).localizedDescription,
        ClaudeOAuthFetchError.unauthorized.localizedDescription,
        "Claude OAuth token expired and delegated refresh is cooling down.",
        "Claude OAuth token is still unavailable after delegated Claude CLI refresh.",
        "Claude OAuth token refresh failed: HTTP 400 invalid_grant.",
    ])
    func `known Claude credential failures require recovery`(_ description: String) {
        #expect(ClaudeCredentialRecoveryErrorClassifier.matches(description))
    }

    @Test(arguments: [
        "Temporary Claude API failure",
        ClaudeOAuthFetchError.usageRateLimitDescription,
        ClaudeOAuthFetchError.invalidResponse.localizedDescription,
        "Claude OAuth network error: offline",
        "Claude OAuth error: HTTP 500",
        "",
    ])
    func `ordinary Claude failures do not require credential recovery`(_ description: String) {
        #expect(!ClaudeCredentialRecoveryErrorClassifier.matches(description))
    }

    @Test
    func `automatic Claude recovery authorizes only Claude keychain access`() async throws {
        let payload = Data("external-login".utf8)
        let keychain = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
            data: payload,
            fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 1,
                persistentRefHash: "keychain-ref"))

        try await BrowserCookieAccessGate.withDeniedBrowsersForTesting([.arc]) {
            try await ProviderInteractionContext.$current.withValue(.background) {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
                        try await ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(
                            keychain)
                        {
                            try await ClaudeAutomaticCredentialRecoveryContext.withAuthorization {
                                #expect(ProviderInteractionContext.current == .background)
                                #expect(!BrowserCookieAccessGate.shouldAttempt(.arc))
                                #expect(try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain() == payload)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `background fingerprint changes with external Claude credentials`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentialsURL = directory.appendingPathComponent("credentials.json")
        try Data("file-credential".utf8).write(to: credentialsURL)

        let firstKeychain = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
            data: nil,
            fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 1,
                persistentRefHash: "first-ref"))
        let secondKeychain = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
            data: nil,
            fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 3,
                createdAt: 1,
                persistentRefHash: "second-ref"))

        try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(credentialsURL) {
            try ProviderInteractionContext.$current.withValue(.background) {
                try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
                        let first = try ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(
                            firstKeychain)
                        {
                            ClaudeAutomaticCredentialRecoveryContext.withAuthorization {
                                ClaudeOAuthCredentialsStore
                                    .currentCredentialFingerprintWithoutPromptForBackgroundMonitoring(environment: [:])
                            }
                        }
                        let second = try ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(
                            secondKeychain)
                        {
                            ClaudeAutomaticCredentialRecoveryContext.withAuthorization {
                                ClaudeOAuthCredentialsStore
                                    .currentCredentialFingerprintWithoutPromptForBackgroundMonitoring(environment: [:])
                            }
                        }

                        #expect(first != nil)
                        #expect(second != nil)
                        #expect(first != second)
                        #expect(first?.contains(credentialsURL.path) == false)
                        #expect(first?.contains("first-ref") == false)
                    }
                }
            }
        }
    }

    @Test
    func `background fingerprint honors consent and never prompt mode`() throws {
        let keychain = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
            data: nil,
            fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 1,
                persistentRefHash: "keychain-ref"))
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("credentials.json")

        try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingFile) {
            try ProviderInteractionContext.$current.withValue(.background) {
                try ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(keychain) {
                    let withoutConsent = try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                        ClaudeAutomaticCredentialRecoveryContext.withAuthorization {
                            ClaudeOAuthCredentialsStore
                                .currentCredentialFingerprintWithoutPromptForBackgroundMonitoring(environment: [:])
                        }
                    }
                    let never = try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                            ClaudeAutomaticCredentialRecoveryContext.withAuthorization {
                                ClaudeOAuthCredentialsStore
                                    .currentCredentialFingerprintWithoutPromptForBackgroundMonitoring(environment: [:])
                            }
                        }
                    }

                    #expect(withoutConsent == nil)
                    #expect(never == nil)
                }
            }
        }
    }
}
