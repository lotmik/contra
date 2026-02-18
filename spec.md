# Spec: Firefox Policy Lock Deployment for `contra`

## Goal
Enforce non-removable extension behavior for non-sudo users in Firefox by using enterprise policies, while keeping extension-side anti-tamper logic as a defense-in-depth layer.

## Scope
- Add operational tooling to build an XPI package.
- Add operational tooling to install and verify Firefox root-owned policies.
- Add policy template for force-installing `contra@local`.
- Add popup status for managed lock visibility.
- Keep anti-tamper blocking of extension-management pages active.

## Out of Scope
- Defending against users with sudo/root access.
- Supporting Flatpak/Snap Firefox policy paths in this iteration.

## Implementation
1. `scripts/build-xpi.sh`
   - Deterministically package required extension files into `dist/contra.xpi`.
2. `deploy/firefox/policies.json`
   - Template with strict hardening and a placeholder install URL.
3. `scripts/install-firefox-policy.sh`
   - Build package, install root-owned XPI to `/opt/contra/contra.xpi`, write `/etc/firefox/policies/policies.json`, keep rollback backup in `/opt/contra/releases/`.
4. `scripts/verify-firefox-policy.sh`
   - Validate required files, ownership/permissions, and policy content expectations.
5. `scripts/uninstall-firefox-policy.sh`
   - Remove policy lock and revert managed XPI using latest backup when available.
6. `scripts/dev-local-firefox.sh`
   - Launch a dedicated local-dev Firefox profile with unsigned-addon preference for persistent local testing on Developer Edition/Nightly.
7. Popup status
   - Add managed-lock badge and guidance text backed by `browser.management.getSelf()` checks in background worker.

## Verification
- `node --check background.js`
- `node --check popup.js`
- `bash -n scripts/build-xpi.sh`
- `bash -n scripts/install-firefox-policy.sh`
- `bash -n scripts/verify-firefox-policy.sh`
- `bash -n scripts/dev-local-firefox.sh`
- `scripts/build-xpi.sh` successful
- `scripts/verify-firefox-policy.sh` run (expected warnings/failures before sudo install are acceptable in dev state)

## Addendum: Phrase Typing UX (Monkeytype-style)

### Goal
Make unlock/pause phrase entry visibly guided and deterministic:
- The user sees the reference phrase they must type.
- The confirm button stays blurred and unclickable until phrase input matches.
- Typing feedback follows Monkeytype-like per-character rendering.

### Scope
- Replace visible phrase input UI with:
  - Hidden real text input used for capturing typing/focus.
  - Separate visual rendering container for the reference phrase and typed-state colors.
- Add per-character render states:
  - Pending: `#646669`
  - Correct: `#d1d0c5`
  - Incorrect: `#ca4754`
  - Overflow/extra chars: `#7e2a33`
- Add a blinking vertical caret that moves with typing progress.
- Add full-button blur lock while phrase is not valid.

### Rendering Rules
1. Split reference phrase and user input into words by spaces.
2. Compare each input word against the corresponding reference word.
3. Render reference characters one-to-one with correct/incorrect/pending state.
4. If an input word exceeds reference length, render the extra chars before the inter-word space as overflow chars.
5. Typing a space advances caret/rendering to next word.

### Verification
- `node --check popup.js`
- Manual popup check:
  - Phrase is visible before typing.
  - Button is blurred + disabled before match.
  - Button becomes sharp + enabled after exact phrase match.
  - Overflow chars render as dark red before the next word's space.

## Addendum: Configurable Unlock Phrase in Settings

### Goal
Allow users to define the unlock/pause phrase directly in popup settings.

### Scope
- Add a settings text input for unlock phrase configuration.
- Persist configured phrase to extension local storage.
- Use configured phrase in challenge rendering and phrase validation.
- Normalize phrase by trimming and collapsing spaces; fallback to default if empty.

### Verification
- `node --check popup.js`
- Manual popup check:
  - Changing phrase in Settings persists after popup reopen.
  - Lock challenge displays the configured phrase.
  - Confirm remains locked until the configured phrase is typed correctly.
