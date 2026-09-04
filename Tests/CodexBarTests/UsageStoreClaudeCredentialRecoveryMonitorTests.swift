import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreClaudeCredentialRecoveryMonitorTests {
    @Test
    func `healthy and ordinary Claude failures do not probe credentials`() async throws {
        let store = try self.makeStore(claudeEnabled: true)
        var probeCount = 0
        store._test_claudeCredentialFingerprintProbeOverride = {
            probeCount += 1
            return "credential"
        }

        await store.checkClaudeCredentialRecovery()
        store._setErrorForTesting("Temporary Claude API failure", provider: .claude)
        await store.checkClaudeCredentialRecovery()

        #expect(probeCount == 0)
    }

    @Test
    func `disabled or refreshing Claude does not probe credentials`() async throws {
        let disabledStore = try self.makeStore(claudeEnabled: false)
        disabledStore._setErrorForTesting(ClaudeOAuthCredentialsError.notFound.localizedDescription, provider: .claude)
        var disabledProbeCount = 0
        disabledStore._test_claudeCredentialFingerprintProbeOverride = {
            disabledProbeCount += 1
            return "credential"
        }

        await disabledStore.checkClaudeCredentialRecovery()

        let refreshingStore = try self.makeStore(claudeEnabled: true)
        refreshingStore._setErrorForTesting(
            ClaudeOAuthCredentialsError.notFound.localizedDescription,
            provider: .claude)
        refreshingStore.refreshingProviders.insert(.claude)
        var refreshingProbeCount = 0
        refreshingStore._test_claudeCredentialFingerprintProbeOverride = {
            refreshingProbeCount += 1
            return "credential"
        }

        await refreshingStore.checkClaudeCredentialRecovery()

        #expect(disabledProbeCount == 0)
        #expect(refreshingProbeCount == 0)
    }

    @Test
    func `new Claude credential fingerprint refreshes once while unchanged fingerprint does not`() async throws {
        let store = try self.makeStore(claudeEnabled: true)
        store._setErrorForTesting(ClaudeOAuthCredentialsError.notFound.localizedDescription, provider: .claude)
        var fingerprint: String? = "first"
        store._test_claudeCredentialFingerprintProbeOverride = { fingerprint }
        var refreshes: [(UsageProvider, ProviderInteraction, Bool, Bool)] = []
        store._test_providerRefreshOverride = { provider in
            refreshes.append((
                provider,
                ProviderInteractionContext.current,
                ClaudeAutomaticCredentialRecoveryContext.isActive,
                BrowserCookieAccessGate.shouldAttempt(.arc)))
        }

        await BrowserCookieAccessGate.withDeniedBrowsersForTesting([.arc]) {
            await store.checkClaudeCredentialRecovery()
            await store.checkClaudeCredentialRecovery()
            fingerprint = "second"
            await store.checkClaudeCredentialRecovery()
        }

        #expect(refreshes.count == 2)
        #expect(refreshes.allSatisfy { $0.0 == .claude })
        #expect(refreshes.allSatisfy { $0.1 == .background })
        #expect(refreshes.allSatisfy(\.2))
        #expect(refreshes.allSatisfy { !$0.3 })
    }

    @Test
    func `nil Claude credential fingerprint does not refresh`() async throws {
        let store = try self.makeStore(claudeEnabled: true)
        store._setErrorForTesting(ClaudeOAuthCredentialsError.notFound.localizedDescription, provider: .claude)
        store._test_claudeCredentialFingerprintProbeOverride = { nil }
        var refreshCount = 0
        store._test_providerRefreshOverride = { _ in refreshCount += 1 }

        await store.checkClaudeCredentialRecovery()

        #expect(refreshCount == 0)
    }

    @Test
    func `registered background refresh cannot consume automatic recovery fingerprint`() async throws {
        let store = try self.makeStore(claudeEnabled: true)
        store._setErrorForTesting(ClaudeOAuthCredentialsError.notFound.localizedDescription, provider: .claude)
        store._test_claudeCredentialFingerprintProbeOverride = { "external-login" }
        var refreshContexts: [(ProviderInteraction, Bool)] = []
        store._test_providerRefreshOverride = { _ in
            refreshContexts.append((
                ProviderInteractionContext.current,
                ClaudeAutomaticCredentialRecoveryContext.isActive))
        }
        let registeredBackground = store.providerRefreshCoordinator.beginReplacingRequest(for: .claude)

        await store.checkClaudeCredentialRecovery()
        store.providerRefreshCoordinator.complete(
            registeredBackground.state,
            for: .claude,
            retryRequired: false)

        #expect(refreshContexts.count == 1)
        #expect(refreshContexts.first?.0 == .background)
        #expect(refreshContexts.first?.1 == true)
    }

    @Test
    func `monitor cancellation after observation does not cancel authorized recovery`() async throws {
        let store = try self.makeStore(claudeEnabled: true)
        store._setErrorForTesting(ClaudeOAuthCredentialsError.notFound.localizedDescription, provider: .claude)
        store._test_claudeCredentialFingerprintProbeOverride = { "external-login" }
        var refreshContexts: [(ProviderInteraction, Bool)] = []
        store._test_providerRefreshOverride = { _ in
            refreshContexts.append((
                ProviderInteractionContext.current,
                ClaudeAutomaticCredentialRecoveryContext.isActive))
        }

        var predecessorContinuation: CheckedContinuation<Void, Never>?
        let predecessorTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                predecessorContinuation = continuation
            }
        }
        let predecessor = store.providerRefreshCoordinator.beginReplacingRequest(for: .claude)
        predecessor.state.install(task: predecessorTask)
        while predecessorContinuation == nil {
            await Task.yield()
        }

        let check = Task { @MainActor in
            await store.checkClaudeCredentialRecovery()
        }
        while store.providerRefreshCoordinator.coalescingState(for: .claude)?.generation == predecessor.generation {
            await Task.yield()
        }
        check.cancel()
        predecessorContinuation?.resume()
        await check.value
        store.providerRefreshCoordinator.complete(
            predecessor.state,
            for: .claude,
            retryRequired: false)

        #expect(refreshContexts.count == 1)
        #expect(refreshContexts.first?.0 == .background)
        #expect(refreshContexts.first?.1 == true)
    }

    @Test
    func `cancelled credential check does not refresh after suspended probe returns`() async throws {
        let store = try self.makeStore(claudeEnabled: true)
        store._setErrorForTesting(ClaudeOAuthCredentialsError.notFound.localizedDescription, provider: .claude)
        var probeContinuation: CheckedContinuation<String?, Never>?
        store._test_claudeCredentialFingerprintProbeOverride = {
            await withCheckedContinuation { continuation in
                probeContinuation = continuation
            }
        }
        var refreshCount = 0
        store._test_providerRefreshOverride = { _ in refreshCount += 1 }

        let check = Task { @MainActor in
            await store.checkClaudeCredentialRecovery()
        }
        while probeContinuation == nil {
            await Task.yield()
        }
        check.cancel()
        probeContinuation?.resume(returning: "credential")
        await check.value

        #expect(refreshCount == 0)
    }

    @Test
    func `manual refresh mode still runs independent Claude credential monitor`() async throws {
        let store = try self.makeStore(claudeEnabled: true)
        store._setErrorForTesting(ClaudeOAuthCredentialsError.notFound.localizedDescription, provider: .claude)
        var probeCount = 0
        store._test_claudeCredentialFingerprintProbeOverride = {
            probeCount += 1
            return "credential"
        }
        var refreshCount = 0
        store._test_providerRefreshOverride = { _ in refreshCount += 1 }

        store.restartTimersForClaudeCredentialRecoveryTesting(credentialSleep: .milliseconds(1))
        for _ in 0..<100 where refreshCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        await store.cancelClaudeCredentialRecoveryMonitorForTesting()
        let countAfterCancellation = refreshCount
        let probesAfterCancellation = probeCount
        try await Task.sleep(for: .milliseconds(5))

        #expect(refreshCount == 1)
        #expect(refreshCount == countAfterCancellation)
        #expect(probeCount == probesAfterCancellation)
    }

    private func makeStore(claudeEnabled: Bool) throws -> UsageStore {
        let settings = SettingsStore(
            userDefaults: InMemoryUserDefaults(),
            configStore: testConfigStore(suiteName: "ClaudeCredentialMonitor-\(UUID().uuidString)"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.providerDetectionCompleted = true
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(ProviderRegistry.shared.metadata[provider]),
                enabled: claudeEnabled && provider == .claude)
        }
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}
