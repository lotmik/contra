# Spec: Firefox Policy Lock Deployment for `contra`

## Goal
Enforce non-removable extension behavior for non-sudo users in Firefox by using enterprise policies, while keeping extension-side anti-tamper logic as a defense-in-depth layer.

## Scope
- Add operational tooling to build an XPI package.
- Add operational tooling to install and verify Firefox root-owned policies.
- Add policy template for force-installing `contra@local`.
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
- Add a settings multiline textarea for unlock phrase configuration with auto-grow behavior.
- Persist configured phrase to extension local storage.
- Use configured phrase in challenge rendering and phrase validation.
- Normalize phrase by trimming and collapsing spaces; fallback to default if empty.

### Verification
- `node --check popup.js`
- Manual popup check:
  - Changing phrase in Settings persists after popup reopen.
  - Lock challenge displays the configured phrase.
  - Confirm remains locked until the configured phrase is typed correctly.

## Addendum: Restore Initially Closed Forbidden Tabs

### Goal
When blocking starts, automatically closed forbidden tabs from that initial sweep should be reopened after a successful unblock.

### Scope
- Capture only forbidden tabs that were already open at the moment `START_BLOCKING` runs.
- Do not capture tabs opened (and auto-closed) later during active blocking.
- Persist startup-captured tab snapshots in local storage so recovery survives worker restarts.
- On `STOP_BLOCKING`, restore startup-captured tabs best-effort, then clear recovery state.

### Verification
- `node --check background.js`
- Manual flow:
  - Open at least one forbidden URL, then start blocking and confirm it is auto-closed.
  - Open another forbidden URL during blocking and confirm it is also auto-closed.
  - Unblock (phrase mode success or timer-complete stop) and verify only the initially closed forbidden tabs are restored.

## Addendum: Minimal Timer UX (Presets + End Time)

### Goal
Replace timer mode switching with a single minimal model:
- Four preset buttons that are selectable and editable.
- One always-visible end-time input in 24-hour format.

### Scope
- Popup settings:
  - Presets row with 4 buttons.
  - Single-click preset selects it.
  - Double-click preset opens inline numeric editor.
  - Pressing `Enter` commits edited preset value (`1..1440`), invalid values are rejected.
  - End-time input (`input[type="time"]`) is always visible and uses 24h `HH:MM`.
- Interaction model:
  - Preset mode: selected preset is highlighted and end time is derived as `now + preset minutes`.
  - While popup is open in preset mode, end-time display updates dynamically over time.
  - Manual end-time edit switches to manual mode; no preset is highlighted.
- Persistence model:
  - `timerPresets`: array of 4 integers.
  - `timerSelectionMode`: `preset | manualEndTime`.
  - `selectedPresetIndex`: `0..3 | null`.
  - `manualEndTime`: `HH:MM`.
  - `timerMinutes` remains the effective derived value used for blocking payload.
- Backward compatibility:
  - Read deprecated `timerType` and `timerEndTime` for migration only.
  - Do not write deprecated keys.

### Verification
- `node --check popup.js`
- `node --check background.js`
- Manual flow:
  - Single-click a preset and confirm highlight + end-time updates.
  - Keep popup open and verify end-time keeps moving with clock in preset mode.
  - Double-click preset, edit value, press `Enter`, verify label updates and persists after reopen.
  - Enter end time manually and verify preset highlight clears.
  - Start blocking from preset mode and manual end-time mode; verify `timerMinutes` behaves correctly.

## Addendum: Tab Survival Guard + System-Tab Allowance

### Goal
Prevent browser self-lockout loops during blocking by ensuring at least one non-blocked tab survives, while still aggressively blocking anti-tamper pages used to disable/remove the extension.

### Scope
- Always allow browser/system tabs that should not be treated as distractions (for example: `about:newtab`, `about:blank`, `about:home`, `about:privatebrowsing`, extension pages like `moz-extension://...`).
- Continue blocking anti-tamper pages even though they are internal URLs:
  - `about:addons`
  - `about:debugging`
  - `about:config`
  - `about:policies`
  - extension-management equivalents on Chromium-family browsers
- Before force-closing any tab, detect whether that close would leave only tabs that are also about to be closed; if so, create a fallback tab first.
- Apply the same guard in:
  - event-driven tab enforcement (`onUpdated`, `onBeforeNavigate`, activation checks)
  - startup sweep at `START_BLOCKING`
  - aggressive anti-tamper interval sweep

### Verification
- `node --check background.js`
- Manual flow:
  - In whitelist mode, keep only non-whitelisted tabs open and start blocking; verify Firefox is not left with zero tabs.
  - Keep only blocked/tamper tabs open and start blocking; verify at least one fallback tab survives.
  - Open `about:addons` or `about:debugging` while blocking; verify these pages are still closed immediately.
  - Open `about:newtab` during blocking; verify it is not force-closed.

## Addendum: Debounced Settings Sync for URLs and Editable Timer Presets

### Goal
Make URL list and editable timer preset updates resilient and predictable, so typed values persist even if focus changes immediately.

### Scope
- Add debounced (`500ms`) autosave for URL textarea edits in both Blocklist and Whitelist modes.
- Flush pending URL sync on blur/change/unload to reduce loss when focus leaves quickly.
- Add debounced (`500ms`) autosave while editing preset timer buttons (double-click editor).
- Commit valid timer preset edits on blur/unload/start-blocking without requiring `Enter`.
- Keep existing fallback behavior for invalid/empty preset input (do not overwrite previous preset value).

### Verification
- `node --check popup.js`
- Manual flow:
  - Type in URL list and stop typing for at least `500ms`; reopen popup and verify value persisted.
  - Type in URL list and click away immediately; verify list remains persisted.
  - Double-click a timer preset, type a valid number, click away; verify preset value persists.
  - Double-click preset, clear the editor and blur; verify previous preset value remains unchanged.

## Addendum: Blocked Settings Summary Lock

### Goal
When blocking is active, lock the main popup `Settings` dropdown row itself instead of blurring the full settings content.

### Scope
- Make the `Settings` summary row non-interactive while blocked.
- Apply blur to the whole summary row (chevron + label) while blocked.
- Prevent copying/selecting the visible `Settings` label in blocked mode.

### Verification
- `node --check popup.js`
- Manual popup flow:
  - Start blocking and verify the `Settings` summary row appears blurred.
  - Verify clicking the `Settings` summary row does not open/close the dropdown while blocked.
  - Verify selecting/copying the visible `Settings` label is not possible while blocked.
