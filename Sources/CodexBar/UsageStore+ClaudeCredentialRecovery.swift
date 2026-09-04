import CodexBarCore
import Foundation

extension UsageStore {
    nonisolated static let claudeCredentialRecoveryPollInterval: Duration = .seconds(5)

    func checkClaudeCredentialRecovery() async {
        guard self.shouldMonitorClaudeCredentialRecovery else { return }
        let fingerprint = await self.currentClaudeCredentialRecoveryFingerprint()
        guard !Task.isCancelled,
              self.shouldMonitorClaudeCredentialRecovery,
              let fingerprint,
              fingerprint != self.lastClaudeCredentialRecoveryFingerprint
        else {
            return
        }

        // Record before the prompt-capable refresh so denial or another failure cannot create a five-second loop.
        self.lastClaudeCredentialRecoveryFingerprint = fingerprint
        // Once recorded, recovery must outlive polling-task cancellation. Settings changes restart the monitor,
        // but must not cancel the only authorized attempt for this fingerprint while it drains a predecessor.
        let recovery = Task { @MainActor [weak self] in
            guard let self else { return }
            await ProviderInteractionContext.$current.withValue(.background) {
                await ClaudeAutomaticCredentialRecoveryContext.withAuthorization {
                    // A newly observed credential supersedes any request registered with the old credential.
                    // Replacing cancels and drains that predecessor before the authorized fetch starts.
                    await self.refreshProvider(.claude, coalesceIfRefreshing: false)
                }
            }
        }
        await recovery.value
    }

    func startClaudeCredentialRecoveryMonitor() {
        self.claudeCredentialRecoveryMonitorTask?.cancel()
        #if DEBUG
        let sleepDuration = self.claudeCredentialRecoverySleepOverrideForTesting ??
            Self.claudeCredentialRecoveryPollInterval
        #else
        let sleepDuration = Self.claudeCredentialRecoveryPollInterval
        #endif

        self.claudeCredentialRecoveryMonitorTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: sleepDuration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.checkClaudeCredentialRecovery()
            }
        }
    }

    private var shouldMonitorClaudeCredentialRecovery: Bool {
        guard self.enabledProvidersForDisplay().contains(.claude),
              !self.refreshingProviders.contains(.claude),
              let error = self.errors[.claude]
        else {
            return false
        }
        return ClaudeCredentialRecoveryErrorClassifier.matches(error)
    }

    private func currentClaudeCredentialRecoveryFingerprint() async -> String? {
        #if DEBUG
        if let override = self._test_claudeCredentialFingerprintProbeOverride {
            return await override()
        }
        #endif
        let environment = self.environmentBase
        return await Task.detached(priority: .utility) {
            ProviderInteractionContext.$current.withValue(.background) {
                ClaudeAutomaticCredentialRecoveryContext.withAuthorization {
                    ClaudeOAuthCredentialsStore
                        .currentCredentialFingerprintWithoutPromptForBackgroundMonitoring(environment: environment)
                }
            }
        }.value
    }

    #if DEBUG
    func cancelClaudeCredentialRecoveryMonitorForTesting() async {
        let task = self.claudeCredentialRecoveryMonitorTask
        task?.cancel()
        await task?.value
        self.claudeCredentialRecoveryMonitorTask = nil
    }
    #endif
}
