import Foundation

public enum ClaudeCredentialRecoveryErrorClassifier {
    public static func matches(_ description: String) -> Bool {
        if ClaudeOAuthUnreadableCredentialsError.matches(description: description) {
            return true
        }
        if [
            ClaudeOAuthCredentialsError.missingOAuth.localizedDescription,
            ClaudeOAuthCredentialsError.missingAccessToken.localizedDescription,
            ClaudeOAuthCredentialsError.notFound.localizedDescription,
            ClaudeOAuthCredentialsError.keychainAccessRevoked.localizedDescription,
            ClaudeOAuthCredentialsError.noRefreshToken.localizedDescription,
            ClaudeOAuthCredentialsError.decodeFailed.localizedDescription,
            ClaudeOAuthCredentialsError.mcpOAuthOnlyKeychain.localizedDescription,
            ClaudeOAuthFetchError.unauthorized.localizedDescription,
        ].contains(description) {
            return true
        }
        if description.hasPrefix("Claude Keychain access was denied.") ||
            description.hasPrefix("Claude OAuth token expired") ||
            description.hasPrefix("Claude OAuth token is still unavailable after delegated Claude CLI refresh.")
        {
            return true
        }
        return description.hasPrefix("Claude OAuth token refresh failed:") &&
            description.localizedCaseInsensitiveContains("invalid_grant")
    }
}

public enum ClaudeAutomaticCredentialRecoveryContext {
    @TaskLocal public static var isActive = false

    public static func withAuthorization<T>(_ operation: () throws -> T) rethrows -> T {
        try self.$isActive.withValue(true, operation: operation)
    }

    public static func withAuthorization<T>(
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$isActive.withValue(true, operation: operation)
    }
}
