# AGENTS.md

This file defines project context and execution rules for agents working in this repository.

## 1) Project Docs (Contra Firefox Add-on)

### Purpose
`contra.` is a Firefox MV3 extension for strict distraction blocking, with:
- blocklist / allowlist modes
- timer-based lock mode
- phrase-based unlock mode
- adult-content blocking

### Core Files
- `manifest.json`: extension metadata, permissions, popup wiring, background script.
- `background.js`: blocking engine and state authority.
- `popup.html`: popup structure/UI.
- `popup.css`: popup styling.
- `popup.js`: popup state sync, interactions, and rendering.
- `data/adult-domains.txt`: local adult domain list.
- `scripts/build-xpi.sh`: deterministic XPI packaging script.

### Runtime Architecture
- **Background-first state**:
  - `background.js` is the source of truth for active blocking behavior.
  - `popup.js` reads/writes state via `browser.storage.local` + runtime messages.
- **Message contract** (popup -> background):
  - `START_BLOCKING`
  - `STOP_BLOCKING`
  - `REQUEST_PAUSE_POSITIVE`
  - `RESUME_PAUSE_POSITIVE`
- **Background events -> popup refresh**:
  - `UNLOCK_TIMER_EXPIRED`
  - `PAUSE_POSITIVE_STARTED`
  - `PAUSE_POSITIVE_ENDED`
  - `TEST_DISABLE_STARTED`
  - `TEST_DISABLE_EXPIRED`

### Blocking Model
- `isBlocking` controls active block enforcement.
- `unlockMode`:
  - `timer`: user cannot stop until timer expires.
  - `phrase`: user must type unlock phrase to stop.
- `pauseUntil` gates temporary 2-minute pause flow.
- Timer alarm + pause alarm are managed in `background.js`.
- During pause in timer mode, timer lock must be effectively paused (lock end reconciliation logic exists in background).

### Popup UI Notes
- Popup has compact constrained-height layout with internal scroll regions.
- Site list editor is custom row-based (not visible textarea), synced into hidden `#url-list`.
- In blocked state, settings are hidden; unlock challenge UI is shown.
- Timer settings include presets and inline editable end-time.

### Build & Validation Commands
- Syntax checks:
  - `node --check popup.js`
  - `node --check background.js`
- Package:
  - `bash scripts/build-xpi.sh`
- Output:
  - `dist/contra.xpi`

## 2) Agent Workflow Rules

These are mandatory for all agents in this repo.

### After implementing any change
1. Design and run relevant checks (at minimum syntax checks).
2. Debug/fix issues immediately if checks fail.
3. Re-run checks until green.
4. Build XPI using:
   - `bash scripts/build-xpi.sh`

### Debugging expectation
- If behavior is wrong, reproduce, inspect affected path, patch minimally, and verify with checks/build.
- Do not stop at code edits without verification.

### "git flow" command meaning
If user says **`git flow`**, interpret it as:
1. Commit current changes (only what should ship).
2. Push current branch state to `main` on `origin`.

Default sequence:
1. `git add -A`
2. `git commit -m "<clear summary>"`
3. `git push origin main`

If there are blockers (conflicts, rejected push, missing auth), report exact blocker and next action.

