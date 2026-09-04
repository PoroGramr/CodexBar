# Claude External Login Monitor Design

**Date:** 2026-09-04
**Issue:** [#3395](https://github.com/steipete/CodexBar/issues/3395)
**Status:** Proposed

## Summary

CodexBar should recover from a Claude login completed outside the app without waiting for the user to open the menu or manually refresh. While Claude is in a known credential-recovery error state, an independent monitor will check credential metadata every five seconds. A newly discovered or changed credential fingerprint will trigger one targeted Claude refresh that may display the macOS Keychain access prompt.

The monitor must remain narrowly scoped. It will not poll while Claude is healthy, will not refresh other providers, and will not mark a background refresh as a general user interaction. Existing explicit consent for direct Claude Keychain access remains required.

## Context

The existing fix for #3395 retries Claude with user-initiated access when the menu is opened and Claude has a known credential-recovery error. That solves recovery on a real user action, but it does not detect an external `claude` login while CodexBar remains idle.

The current Claude credential implementation already provides no-UI metadata probes for the credential file and Keychain. It also has two distinct protections:

- `keychainAccessAllowed`, the persisted explicit consent for direct Claude Keychain reads.
- `ClaudeOAuthKeychainPromptMode`, which controls whether a direct read may display a system prompt.

Those protections must continue to apply. Allowing an automatic recovery prompt is not permission to silently enable direct Keychain access for users who have not opted in.

## Goals

- Detect an external Claude login within approximately five seconds while Claude is waiting for credential recovery.
- Recover even when the normal refresh frequency is set to Manual.
- Permit the targeted recovery attempt to display the macOS Keychain prompt.
- Trigger at most one prompt-capable recovery attempt for an unchanged credential fingerprint.
- Keep other providers and unrelated user-initiated access gates unaffected.
- Avoid reading or retaining raw credentials in the monitor.
- Keep automated tests free of real Keychain access and macOS prompts.

## Non-goals

- Enabling direct Claude Keychain access without the existing explicit user consent.
- Polling Keychain while Claude is healthy or disabled.
- Refreshing all providers after a Claude credential change.
- Treating automatic recovery as a general user interaction.
- Adding a new user-facing setting in this change.
- Detecting arbitrary Claude account changes when there is no credential-recovery error.

## Proposed Design

### 1. Shared credential-recovery classifier

Move the known Claude credential error classification out of the menu controller into a small shared pure helper. Both menu-open recovery and the background monitor will use the same classifier.

The classifier will match only established missing, expired, invalid, or unavailable Claude credential failures. Credential decoding failures are included because a new external login replaces the malformed credential; API response decoding, network, rate-limit, and other ordinary provider errors must not activate the monitor.

### 2. Independent monitor lifecycle

`UsageStore` will own a cancellable utility-priority task whose lifecycle follows the store's refresh infrastructure. The task starts independently of the configured refresh frequency, so Manual mode does not disable external-login detection.

The loop wakes every five seconds. On each wake it first snapshots the minimum MainActor state required to decide whether probing is appropriate:

- Claude is enabled.
- Claude currently has a known credential-recovery error.
- Claude is not already marked as actively refreshing.

If any condition is false, the iteration performs no credential-file or Keychain query. The task is cancelled when the store is deinitialized or its monitor lifecycle is restarted.

The implementation must avoid sibling `async let` work. Actor state capture, metadata probing, and refresh decisions will be sequenced explicitly so required failures cannot be lost during task teardown.

### 3. Metadata-only fingerprint

When monitoring is active, CodexBar will build a combined fingerprint from metadata that does not expose credential contents:

- The selected Claude profile identifier.
- The credential-file fingerprint already available to the auth gate.
- Keychain creation/modification dates and a one-way hash of the persistent reference.

The Keychain portion uses a no-UI metadata query. It must honor the global Keychain-disabled state and `keychainAccessAllowed`. It must not evaluate or persist the raw OAuth payload.

The monitor keeps the last observed fingerprint in memory. Observation semantics are:

- The first fingerprint containing credential evidence while Claude is in recovery is actionable. This catches a login that completed before the first monitor iteration.
- An unchanged fingerprint is not actionable.
- A changed fingerprint is actionable once.
- The new observation is recorded before starting recovery, so a denied prompt or failed refresh does not cause another prompt every five seconds.

When Claude leaves the credential-recovery state, no further metadata queries occur, but the last observed fingerprint remains in memory for the lifetime of the store. A later recovery episode acts only if the credential evidence differs from that observation. Changing the selected Claude profile naturally changes the combined fingerprint. This prevents a previously accepted or denied credential from producing a fresh automatic prompt merely because the provider re-entered an error state.

### 4. Claude-only automatic recovery authorization

The recovery refresh must not run under `ProviderInteractionContext.userInitiated`. That context is intentionally broad and can enable browser-cookie imports or other providers' user-only behavior.

Instead, add a narrowly scoped TaskLocal automatic-recovery context used only by Claude credential code. During the targeted refresh:

- `ProviderInteractionContext` remains `.background`.
- Claude's direct Keychain prompt gate accepts either a real user interaction or the Claude automatic-recovery scope.
- `keychainAccessAllowed` must still be true.
- Prompt mode `.never` and the global Keychain-disabled state still block access.
- No browser-cookie or non-Claude access gate reads the new context.

This makes the permitted system prompt an explicit Claude recovery capability rather than a fabricated user action.

### 5. Targeted replacement refresh

An actionable fingerprint invokes `refreshProvider(.claude, coalesceIfRefreshing: false)` inside the Claude-only automatic-recovery scope. It does not invoke the full-store refresh path. A request registered just before the monitor decision may still carry the old credential and cannot safely consume the new fingerprint. The replacement path cancels and drains that predecessor before starting the authorized fetch, so only the new Claude credential wins publication.

The existing Keychain prompt cooldown continues to apply. If the direct read succeeds and Claude refresh succeeds, the stale credential error is cleared through the normal provider result path. If the prompt is denied or the refresh still fails, the recorded fingerprint prevents repeated prompt attempts until the credential state changes.

The existing menu-open behavior remains unchanged in principle: opening the menu is a real user action, so that path continues to use `ProviderInteractionContext.userInitiated` for the visible affected provider snapshot.

## State Flow

1. Claude refresh reports a known credential-recovery error.
2. The monitor's next five-second tick performs metadata-only fingerprint probes.
3. No credential evidence or an unchanged fingerprint produces no refresh.
4. First credential evidence or a changed fingerprint is recorded as observed.
5. A targeted Claude refresh runs with the Claude-only automatic-recovery scope.
6. The Claude Keychain read may show the macOS system prompt if existing consent and prompt policy allow it.
7. Success clears the stale error and stops further polling; failure leaves the error but does not repeat for the same fingerprint.

## Concurrency and Isolation

- `UsageStore` state and monitor bookkeeping remain MainActor-isolated.
- Potentially blocking Security framework metadata queries run away from MainActor through an injected probe seam.
- Only value-type fingerprint data crosses back to MainActor.
- Monitor cancellation is checked before probing and again before triggering refresh.
- After a changed fingerprint is recorded, its recovery refresh is detached from monitor lifecycle cancellation so a settings-driven monitor restart cannot consume the only attempt.
- Provider refresh replacement cancels and drains an old-credential predecessor before the recovery fetch starts.

## Test Strategy

Tests will use injected sleepers, fingerprint probes, dictionary-backed settings/defaults, and test credential stores. They must not issue real `SecItem` reads or display Keychain UI.

Focused coverage will verify:

- Known Claude credential errors activate the classifier; ordinary errors do not.
- Healthy, disabled, and non-Claude providers do not invoke the fingerprint probe.
- The monitor remains active in Manual refresh mode.
- First non-empty credential evidence triggers one targeted Claude refresh.
- An unchanged fingerprint does not trigger another refresh or prompt-capable attempt.
- A changed fingerprint triggers one new recovery attempt.
- Recording happens before refresh, including denial and failure cases.
- The automatic-recovery TaskLocal permits only the Claude Keychain prompt gate.
- `ProviderInteractionContext` remains background and browser-cookie access remains locked.
- Existing direct-read consent, prompt mode `.never`, and global Keychain disablement are honored.
- Monitor cancellation prevents later probes and refreshes.
- Existing menu-open recovery tests continue to pass with the shared classifier.

## Security and Privacy

The monitor observes only credential metadata and stores only an in-memory fingerprint. It does not log account identifiers, persistent references, access tokens, refresh tokens, or raw Keychain payloads. Persistent references are hashed before entering the combined fingerprint.

The macOS Keychain prompt is intentionally permitted only during a detected Claude recovery transition and only for users who already granted CodexBar's direct Keychain access consent. Denying the prompt is fail-soft and does not create a prompt loop.

## Operational Notes

- The five-second interval should be a named production constant with a test override.
- The changelog entry for #3395 should describe both menu-open recovery and automatic external-login detection.
- Verification should favor focused unit tests and static checks. Live provider probes and real Keychain reads are excluded unless explicitly requested separately.

## Alternatives Considered

### Poll the full Keychain payload

Rejected because it would repeatedly exercise sensitive direct reads, increase prompt risk, and retain more credential information than detection requires.

### Reuse the normal refresh timer

Rejected because normal intervals are too slow and Manual mode would disable detection.

### Mark the automatic refresh as user-initiated

Rejected because that context authorizes unrelated user-only data sources, including browser-cookie access. The capability must remain Claude-specific.

### Retry continuously while the error remains

Rejected because a denied prompt or persistent credential failure would create repeated system prompts and unnecessary provider traffic.
