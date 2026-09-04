# Claude External Login Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect credentials written by an external Claude login within five seconds of a Claude authentication failure and perform one prompt-capable, Claude-only recovery refresh.

**Architecture:** CodexBarCore owns a shared error classifier, a narrowly scoped TaskLocal recovery authorization, and a metadata-only fingerprint API. `UsageStore` owns an independent monitor task that wakes in Manual mode, probes only while Claude needs credential recovery, records changed fingerprints before refreshing, and replaces any old-credential Claude request while the general interaction context remains background.

**Tech Stack:** Swift 6.2, Swift Concurrency/TaskLocal, Observation, Security.framework no-UI queries, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-04-claude-external-login-monitor-design.md`

## Global Constraints

- The production polling interval is exactly five seconds.
- Existing explicit `keychainAccessAllowed` consent remains required for Claude Keychain metadata and payload reads.
- Prompt mode `.never` and global Keychain disablement remain authoritative.
- Automatic recovery must keep `ProviderInteractionContext.current == .background`.
- Automatic recovery may authorize only Claude's Keychain prompt gate; browser-cookie and non-Claude gates remain closed.
- The monitor must not query credential metadata while Claude is healthy, disabled, refreshing, or failing for a non-credential reason.
- The monitor stores no raw credential payload and logs no fingerprint material.
- Tests use injected probes and TaskLocal stores; no test performs a real `SecItem` read or displays Keychain UI.
- Do not introduce dependencies or sibling `async let` tasks.

## File Structure

- Create `Sources/CodexBarCore/Providers/Claude/ClaudeCredentialRecovery.swift`: shared recovery-error classifier and Claude-only TaskLocal authorization.
- Modify `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift`: consume the TaskLocal in the prompt gate and expose a metadata-only combined fingerprint token.
- Modify `Sources/CodexBar/StatusItemController+Menu.swift`: replace its private classifier with the shared Core helper.
- Modify `Sources/CodexBar/UsageStore.swift`: store/cancel monitor state, start it independently of normal refresh cadence, and add test seams.
- Create `Sources/CodexBar/UsageStore+ClaudeCredentialRecovery.swift`: monitor loop, eligibility checks, fingerprint observation, and targeted recovery refresh.
- Create `Tests/CodexBarTests/ClaudeCredentialRecoveryTests.swift`: classifier, TaskLocal authorization, fingerprint privacy/consent, and isolation tests.
- Create `Tests/CodexBarTests/UsageStoreClaudeCredentialRecoveryMonitorTests.swift`: monitor state-machine and lifecycle tests without AppKit or real Keychain access.
- Modify `Tests/CodexBarTests/StatusMenuInstantOpenTests.swift`: keep menu-open coverage using the shared classifier.
- Modify `CHANGELOG.md`: expand the #3395 entry to include automatic external-login detection.

---

### Task 1: Shared Claude Recovery Classification

**Files:**
- Create: `Sources/CodexBarCore/Providers/Claude/ClaudeCredentialRecovery.swift`
- Modify: `Sources/CodexBar/StatusItemController+Menu.swift:1260-1290`
- Test: `Tests/CodexBarTests/ClaudeCredentialRecoveryTests.swift`
- Test: `Tests/CodexBarTests/StatusMenuInstantOpenTests.swift:330-380`

**Interfaces:**
- Produces: `public enum ClaudeCredentialRecoveryErrorClassifier` with `public static func matches(_ description: String) -> Bool`.
- Consumes: `ClaudeOAuthUnreadableCredentialsError.matches(description:)` and the localized descriptions of the five existing `ClaudeOAuthCredentialsError` recovery cases.

- [ ] **Step 1: Write the failing classifier tests**

Add table-driven Swift Testing cases with literal expected booleans:

```swift
@Test(arguments: [
    ClaudeOAuthUnreadableCredentialsError.descriptionPrefix,
    ClaudeOAuthCredentialsError.missingOAuth.localizedDescription,
    ClaudeOAuthCredentialsError.missingAccessToken.localizedDescription,
    ClaudeOAuthCredentialsError.notFound.localizedDescription,
    ClaudeOAuthCredentialsError.keychainAccessRevoked.localizedDescription,
    ClaudeOAuthCredentialsError.noRefreshToken.localizedDescription,
])
func `known Claude credential failures require recovery`(_ description: String) {
    #expect(ClaudeCredentialRecoveryErrorClassifier.matches(description))
}

@Test(arguments: ["Temporary Claude API failure", "rate limited", ""])
func `ordinary Claude failures do not require credential recovery`(_ description: String) {
    #expect(!ClaudeCredentialRecoveryErrorClassifier.matches(description))
}
```

The production mutation caught is deleting or broadening one classifier branch.

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `swift test --filter ClaudeCredentialRecoveryTests`

Expected: compile failure because `ClaudeCredentialRecoveryErrorClassifier` does not exist. If the known local SDK/compiler mismatch prevents test compilation first, record that exact environment failure and continue under the user's approved local-toolchain exception.

- [ ] **Step 3: Add the minimal shared helper and migrate the menu path**

Implement the public pure helper with the existing exact allowlist. Replace `StatusItemController.isClaudeAuthenticationRecoveryError(_:)` with `ClaudeCredentialRecoveryErrorClassifier.matches(_:)` and delete the private duplicate.

- [ ] **Step 4: Re-run focused classifier and menu tests**

Run:

```bash
swift test --filter ClaudeCredentialRecoveryTests
swift test --filter StatusMenuTests
```

Expected: PASS, including menu-open `.userInitiated` behavior and hidden refresh-all `.background` behavior, or only the already-documented toolchain failure.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexBarCore/Providers/Claude/ClaudeCredentialRecovery.swift Sources/CodexBar/StatusItemController+Menu.swift Tests/CodexBarTests/ClaudeCredentialRecoveryTests.swift Tests/CodexBarTests/StatusMenuInstantOpenTests.swift
git commit -m "Share Claude recovery classification"
```

---

### Task 2: Claude-only Prompt Authorization and Metadata Fingerprint

**Files:**
- Modify: `Sources/CodexBarCore/Providers/Claude/ClaudeCredentialRecovery.swift`
- Modify: `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift:90-125, 2090-2165, 2990-3080`
- Test: `Tests/CodexBarTests/ClaudeCredentialRecoveryTests.swift`
- Test: `Tests/CodexBarTests/ClaudeOAuthCredentialsStoreTests.swift`

**Interfaces:**
- Produces: `public enum ClaudeAutomaticCredentialRecoveryContext` with `@TaskLocal public static var isActive = false` and async/synchronous `withAuthorization` helpers.
- Produces: `public static func currentCredentialFingerprintWithoutPromptForBackgroundMonitoring(environment: [String: String]) -> String?` on `ClaudeOAuthCredentialsStore`.
- Consumes: `credentialsProfileIdentifier(environment:)`, `currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment:)`, and `probeClaudeKeychainFingerprintWithoutPrompt()`.

- [ ] **Step 1: Write failing authorization-isolation tests**

Add a test that enters `ProviderInteractionContext.background`, then `ClaudeAutomaticCredentialRecoveryContext.withAuthorization`, and performs a Claude credential load using the existing mutable Keychain override store with prompt mode `.onlyOnUserAction`. Assert the override credential is returned while `ProviderInteractionContext.current` observed inside the scope remains `.background`.

In the same scope, place `.arc` in `BrowserCookieAccessGate.withDeniedBrowsersForTesting([.arc])` and assert `BrowserCookieAccessGate.shouldAttempt(.arc) == false`. The production mutations caught are omitting the Claude TaskLocal gate or replacing it with general `.userInitiated` interaction.

- [ ] **Step 2: Write failing metadata-fingerprint tests**

Use `withCredentialsURLOverrideForTesting`, `withCredentialsProfileIdentifierOverrideForTesting`, `withMutableClaudeKeychainOverrideStoreForTesting`, `withKeychainAccessOverrideForTesting`, and prompt preference TaskLocal overrides. Assert:

```swift
#expect(fingerprintWithFileAndKeychain != nil)
#expect(fingerprintWithChangedKeychain != fingerprintWithFileAndKeychain)
#expect(fingerprintWithoutEvidence == nil)
#expect(fingerprintWithoutConsentExcludesKeychain)
```

Use synthetic paths and fingerprints only. Also assert `.never` prevents Keychain evidence from entering the fingerprint while file evidence remains observable. The production mutations caught are retaining only file metadata, bypassing consent/`.never`, or treating an empty observation as actionable.

- [ ] **Step 3: Run the focused tests and confirm RED**

Run: `swift test --filter ClaudeCredentialRecoveryTests`

Expected: compile failures for the missing context and fingerprint API, or only the documented local toolchain failure.

- [ ] **Step 4: Implement the narrow authorization**

Add the TaskLocal context. Change only Claude's `shouldAllowClaudeCodeKeychainAccess` `.onlyOnUserAction` branch to:

```swift
return ProviderInteractionContext.current == .userInitiated ||
    ClaudeAutomaticCredentialRecoveryContext.isActive
```

Do not reference the new context from `BrowserCookieAccessGate` or provider-generic code. Keep `.never`, `.always`, `keychainAccessAllowed`, cooldown, and no-UI query behavior unchanged.

- [ ] **Step 5: Implement the combined metadata token**

Inside the explicit Claude automatic-recovery scope, collect the hashed profile identifier, optional file fingerprint, and optional Keychain fingerprint fields. Return `nil` when both credential sources have no evidence. Encode the value deterministically and hash the combined representation before returning it so neither the credentials path nor persistent reference enters `UsageStore` state. Never read the raw OAuth payload.

- [ ] **Step 6: Re-run Core credential tests**

Run:

```bash
swift test --filter ClaudeCredentialRecoveryTests
swift test --filter ClaudeOAuthCredentialsStoreTests
```

Expected: PASS with no Security.framework calls outside test overrides, or only the documented toolchain failure.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodexBarCore/Providers/Claude/ClaudeCredentialRecovery.swift Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift Tests/CodexBarTests/ClaudeCredentialRecoveryTests.swift Tests/CodexBarTests/ClaudeOAuthCredentialsStoreTests.swift
git commit -m "Authorize Claude automatic credential recovery"
```

---

### Task 3: UsageStore Recovery State Machine

**Files:**
- Create: `Sources/CodexBar/UsageStore+ClaudeCredentialRecovery.swift`
- Modify: `Sources/CodexBar/UsageStore.swift:260-365, 500-575, 895-970`
- Create: `Tests/CodexBarTests/UsageStoreClaudeCredentialRecoveryMonitorTests.swift`

**Interfaces:**
- Produces: `nonisolated static let claudeCredentialRecoveryPollInterval: Duration = .seconds(5)`.
- Produces: `func checkClaudeCredentialRecovery() async` on MainActor-isolated `UsageStore`.
- Produces: `private func startClaudeCredentialRecoveryMonitor()` and a DEBUG restart/cancel seam with an injected sleep duration.
- Consumes: `ClaudeCredentialRecoveryErrorClassifier.matches(_:)`, `ClaudeOAuthCredentialsStore.currentCredentialFingerprintWithoutPromptForBackgroundMonitoring(environment:)`, and `refreshProvider(.claude, coalesceIfRefreshing: false)`.

- [ ] **Step 1: Write failing state-machine tests**

Construct stores with `StartupBehavior.testing`, Manual refresh, dictionary-backed settings, and `_test_claudeCredentialFingerprintProbeOverride`. Invoke `checkClaudeCredentialRecovery()` directly and assert consumer-visible refresh behavior through the existing `_test_providerRefreshOverride`:

- Disabled Claude: zero probe invocations and zero refreshes.
- Healthy Claude: zero probe invocations and zero refreshes.
- Ordinary Claude error: zero probe invocations and zero refreshes.
- Claude already refreshing: zero probe invocations and zero recovery refreshes.
- Credential error plus first nonnil fingerprint: one targeted `.claude` refresh.
- Same fingerprint on another check: no second refresh.
- Changed fingerprint: exactly one additional refresh.
- `nil` fingerprint: no refresh.

Inside the refresh override record both `ProviderInteractionContext.current` and `ClaudeAutomaticCredentialRecoveryContext.isActive`; expect `.background` and `true`. Also deny `.arc` through `BrowserCookieAccessGate` and expect it remains denied. These tests catch wrong eligibility branches, recording after refresh, full-store refreshes, and general user-interaction elevation.

- [ ] **Step 2: Run the state-machine tests and confirm RED**

Run: `swift test --filter UsageStoreClaudeCredentialRecoveryMonitorTests`

Expected: compile failure because the recovery check and probe seam do not exist, or only the documented toolchain failure.

- [ ] **Step 3: Implement one recovery check**

Add stored in-memory state:

```swift
@ObservationIgnored var claudeCredentialRecoveryMonitorTask: Task<Void, Never>?
@ObservationIgnored var lastClaudeCredentialRecoveryFingerprint: String?
#if DEBUG
@ObservationIgnored var _test_claudeCredentialFingerprintProbeOverride: (@MainActor () async -> String?)?
#endif
```

Implement `checkClaudeCredentialRecovery()` with sequential guards, probe work, a post-await cancellation/eligibility recheck, assignment of `lastClaudeCredentialRecoveryFingerprint` before refresh, and this exact authorization shape:

```swift
await ProviderInteractionContext.$current.withValue(.background) {
    await ClaudeAutomaticCredentialRecoveryContext.withAuthorization {
        await self.refreshProvider(.claude, coalesceIfRefreshing: false)
    }
}
```

The production fingerprint probe runs in `Task.detached(priority: .utility)` with a copied environment value. The DEBUG override runs without any real Keychain access.

- [ ] **Step 4: Re-run the state-machine tests**

Run: `swift test --filter UsageStoreClaudeCredentialRecoveryMonitorTests`

Expected: PASS or only the documented toolchain failure.

- [ ] **Step 5: Write failing lifecycle tests**

Use the DEBUG monitor restart seam with a zero-duration sleep, Manual refresh, and a credential error. Wait cooperatively until one refresh is observed, cancel the monitor, yield again, and assert the count remains one for the unchanged fingerprint. Add a second test that cancels before a suspended test probe returns and assert no refresh occurs.

The production mutations caught are placing monitor startup after the `.manual` early return or omitting the cancellation check after probing.

- [ ] **Step 6: Implement monitor lifecycle**

Start/restart the independent monitor before `startTimer`'s Manual-frequency guard. Its detached utility task sleeps five seconds, checks cancellation, calls the MainActor recovery check, and repeats. Cancel it in `deinit`. The DEBUG seam changes only sleep duration and must never alter eligibility or polling semantics.

- [ ] **Step 7: Re-run monitor tests and commit**

Run: `swift test --filter UsageStoreClaudeCredentialRecoveryMonitorTests`

Expected: PASS or only the documented toolchain failure.

```bash
git add Sources/CodexBar/UsageStore.swift Sources/CodexBar/UsageStore+ClaudeCredentialRecovery.swift Tests/CodexBarTests/UsageStoreClaudeCredentialRecoveryMonitorTests.swift
git commit -m "Monitor Claude external login credentials"
```

---

### Task 4: Documentation and Verification

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-09-04-claude-external-login-monitor.md`

**Interfaces:**
- Consumes: all prior task behavior.
- Produces: final #3395 changelog wording and recorded verification evidence.

- [ ] **Step 1: Update the changelog**

Revise the existing #3395 bullet to state that CodexBar retries visible Claude authentication recovery on menu open and automatically detects externally written Claude credentials while the provider is awaiting login.

- [ ] **Step 2: Run focused and static verification**

Run:

```bash
swift test --filter ClaudeCredentialRecoveryTests
swift test --filter UsageStoreClaudeCredentialRecoveryMonitorTests
swift test --filter StatusMenuTests
swiftc -frontend -parse Sources/CodexBarCore/Providers/Claude/ClaudeCredentialRecovery.swift
swiftc -frontend -parse Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift
swiftc -frontend -parse Sources/CodexBar/UsageStore.swift
swiftc -frontend -parse Sources/CodexBar/UsageStore+ClaudeCredentialRecovery.swift
swiftc -frontend -parse Sources/CodexBar/StatusItemController+Menu.swift
git diff --check
```

Expected: focused tests PASS when the toolchain is usable; all parse and whitespace checks PASS. Record any test blockage using the exact SDK/compiler diagnostics.

- [ ] **Step 3: Run repository checks**

Run:

```bash
swiftformat Sources Tests
make test
make check
```

Expected: PASS. If the known Command Line Tools mismatch, missing `Testing`/`PreviewsMacros`, SourceKit failure, or Python `waitid` issue recurs, report each exact blocker and rely only on checks that actually completed; do not claim the full suite passed.

- [ ] **Step 4: Review security mutations**

Inspect the final diff and verify these mutations are caught by tests: removing consent checks, allowing `.never`, setting general `.userInitiated`, probing while healthy, recording after refresh, refreshing all providers, and repeating an unchanged fingerprint. Confirm no log statement prints fingerprint values.

- [ ] **Step 5: Request code review, apply valid findings, and re-verify**

Use `superpowers:requesting-code-review` against the branch diff from `392310c665485f8d57c93881e7416c5ebf69d8ef`. Apply `superpowers:receiving-code-review` to findings, adding a failing regression test before every behavioral fix. Re-run Step 2 and Step 3 after changes.

- [ ] **Step 6: Commit final documentation**

```bash
git add CHANGELOG.md docs/superpowers/plans/2026-09-04-claude-external-login-monitor.md
git commit -m "Document Claude external login recovery"
```
