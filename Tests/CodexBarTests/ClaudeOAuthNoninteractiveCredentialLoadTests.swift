import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeOAuthNoninteractiveCredentialLoadTests {
    @Test(arguments: [
        ClaudeOAuthKeychainPromptMode.never,
        ClaudeOAuthKeychainPromptMode.onlyOnUserAction,
        ClaudeOAuthKeychainPromptMode.always,
    ])
    func `oauth credential loads are noninteractive under every prompt mode`(
        mode: ClaudeOAuthKeychainPromptMode) async throws
    {
        final class FlagBox: @unchecked Sendable {
            var values: [Bool] = []
        }

        for interaction in [ProviderInteraction.background, .userInitiated] {
            let flags = FlagBox()
            let usageResponse = try Self.makeOAuthUsageResponse()
            let fetcher = ClaudeUsageFetcher(
                browserDetection: BrowserDetection(cacheTTL: 0),
                environment: [:],
                dataSource: .oauth,
                oauthKeychainPromptCooldownEnabled: true)
            let fetchUsage: (@Sendable (String, Bool) async throws -> OAuthUsageResponse)? = { _, _ in
                usageResponse
            }
            let loadCredentials: @Sendable ([String: String], Bool, Bool) async throws
                -> ClaudeOAuthCredentials = { _, allowKeychainPrompt, _ in
                    flags.values.append(allowKeychainPrompt)
                    return ClaudeOAuthCredentials(
                        accessToken: "explicit-token",
                        refreshToken: nil,
                        expiresAt: Date(timeIntervalSinceNow: 3600),
                        scopes: ["user:profile"],
                        rateLimitTier: nil)
                }

            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(mode) {
                try await ProviderInteractionContext.$current.withValue(interaction) {
                    try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(
                        fetchUsage,
                        operation: {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                                loadCredentials,
                                operation: {
                                    try await fetcher.loadLatestUsage(model: "sonnet")
                                })
                        })
                }
            }

            #expect(flags.values == [false])
        }
    }

    @Test
    func `automatic Claude recovery makes the real OAuth credential load prompt capable`() async throws {
        final class FlagBox: @unchecked Sendable {
            var values: [Bool] = []
        }

        let flags = FlagBox()
        let usageResponse = try Self.makeOAuthUsageResponse()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)
        let fetchUsage: (@Sendable (String, Bool) async throws -> OAuthUsageResponse)? = { _, _ in
            usageResponse
        }
        let loadCredentials: @Sendable ([String: String], Bool, Bool) async throws
            -> ClaudeOAuthCredentials = { _, allowKeychainPrompt, _ in
                flags.values.append(allowKeychainPrompt)
                return ClaudeOAuthCredentials(
                    accessToken: "external-login-token",
                    refreshToken: nil,
                    expiresAt: Date(timeIntervalSinceNow: 3600),
                    scopes: ["user:profile"],
                    rateLimitTier: nil)
            }

        _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            try await ProviderInteractionContext.$current.withValue(.background) {
                try await ClaudeAutomaticCredentialRecoveryContext.withAuthorization {
                    try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchUsage) {
                        try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredentials) {
                            try await fetcher.loadLatestUsage(model: "sonnet")
                        }
                    }
                }
            }
        }

        #expect(flags.values == [true])
    }

    private static func makeOAuthUsageResponse() throws -> OAuthUsageResponse {
        let json = """
        {
          "five_hour": { "utilization": 7, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 21, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        return try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
    }
}
