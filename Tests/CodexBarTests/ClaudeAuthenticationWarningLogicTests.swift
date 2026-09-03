import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct ClaudeAuthenticationWarningLogicTests {
    @Test
    func `missing Claude OAuth credentials require a warning`() {
        #expect(ClaudeAuthenticationWarningLogic.shouldNotify(
            provider: .claude,
            error: ClaudeOAuthCredentialsError.notFound))
        #expect(ClaudeAuthenticationWarningLogic.shouldNotify(
            provider: .claude,
            error: ClaudeOAuthCredentialsError.missingAccessToken))
        #expect(ClaudeAuthenticationWarningLogic.shouldNotify(
            provider: .claude,
            error: ClaudeOAuthCredentialsError.noRefreshToken))
    }

    @Test
    func `unrelated errors do not require a warning`() {
        #expect(!ClaudeAuthenticationWarningLogic.shouldNotify(
            provider: .codex,
            error: ClaudeOAuthCredentialsError.notFound))
        #expect(!ClaudeAuthenticationWarningLogic.shouldNotify(
            provider: .claude,
            error: ClaudeOAuthCredentialsError.keychainAccessRevoked))
        #expect(!ClaudeAuthenticationWarningLogic.shouldNotify(
            provider: .claude,
            error: URLError(.notConnectedToInternet)))
    }

    @Test
    func `warning copy follows Korean app language`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("ko") {
            let copy = ClaudeAuthenticationWarningLogic.notificationCopy()

            #expect(copy.title == "Claude 인증 필요")
            #expect(copy.body.contains("claude auth login --claudeai"))
        }
    }
}
