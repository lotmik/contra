"use strict";

const DEFAULT_UNLOCK_PHRASE = "I swear to God and to my future self that I don't want to ruin my cognitive abilities";
const DEFAULT_TIMER_PRESETS = [15, 25, 45, 60];
const TIMER_SELECTION_MODE_PRESET = "preset";
const TIMER_SELECTION_MODE_MANUAL_END_TIME = "manualEndTime";
const INPUT_SYNC_DEBOUNCE_MS = 500;
const URL_LIST_SYNC_DEBOUNCE_MS = 250;
const URL_LIST_VALIDATION_DELAY_MS = 500;
const STORAGE_KEYS = [
  "isBlocking",
  "mode",
  "blockList",
  "whiteList",
  "unlockMode",
  "timerMinutes",
  "timerPresets",
  "timerSelectionMode",
  "selectedPresetIndex",
  "manualEndTime",
  // Deprecated keys kept for migration.
  "timerType",
  "timerEndTime",
  "unlockPhrase",
  "lockEndTime",
  "timerExpired",
  "pausePositiveEnabled",
  "pauseUntil",
  "testDisableUntil"
];

const state = {
  isBlocking: false,
  mode: "block",
  blockList: [],
  whiteList: [],
  unlockMode: "timer",
  timerMinutes: DEFAULT_TIMER_PRESETS[1],
  timerPresets: [...DEFAULT_TIMER_PRESETS],
  timerSelectionMode: TIMER_SELECTION_MODE_PRESET,
  selectedPresetIndex: 1,
  manualEndTime: getDefaultTimerEndTime(),
  unlockPhrase: DEFAULT_UNLOCK_PHRASE,
  lockEndTime: 0,
  timerExpired: true,
  pausePositiveEnabled: true,
  pauseUntil: 0,
  testDisableUntil: 0
};

let timerTickId = null;
let presetEndTimeTickId = null;
let isUnlockChallengeOpen = false;
let presetEditState = null;
let urlListSyncTimeoutId = null;
let pendingUrlListSyncDraft = null;
let urlListValidationTimeoutId = null;

const elements = {
  body: document.body,
  statusArea: document.getElementById("status-area"),
  powerSection: document.querySelector(".power-section"),
  powerToggle: document.getElementById("power-toggle"),
  powerToggleAssistiveText: document.querySelector("#power-toggle-label .sr-only"),
  unlockChallenge: document.getElementById("unlock-challenge"),
  unlockPhraseLabel: document.querySelector('label[for="unlock-phrase-input"]'),
  unlockPhraseInput: document.getElementById("unlock-phrase-input"),
  unlockPhraseDisplay: document.getElementById("unlock-phrase-display"),
  unlockPhraseCaret: document.getElementById("unlock-phrase-caret"),
  unlockConfirmButton: document.getElementById("unlock-confirm-btn"),
  settingsDropdown: document.getElementById("settings-dropdown"),
  settingsSummary: document.getElementById("settings-summary"),
  modeSelect: document.getElementById("mode-select"),
  urlList: document.getElementById("url-list"),
  urlListError: document.getElementById("url-list-error"),
  unlockModeSelect: document.getElementById("unlock-mode-select"),
  timerSettingsGroup: document.getElementById("timer-settings-group"),
  timerEndTimeInput: document.getElementById("timer-end-time"),
  timerPresets: document.getElementById("timer-presets"),
  unlockPhraseSettingDropdown: document.getElementById("unlock-phrase-setting-dropdown"),
  unlockPhraseSettingSummary: document.getElementById("unlock-phrase-setting-summary"),
  unlockPhraseSettingInput: document.getElementById("unlock-phrase-setting"),
  timerPresetButtons: Array.from(document.querySelectorAll("#timer-presets .timer-preset-btn"))
};

function sanitizeMode(value) {
  return value === "allow" ? "allow" : "block";
}

function sanitizeUnlockMode(value) {
  return value === "phrase" ? "phrase" : "timer";
}

function sanitizeList(value) {
  if (!Array.isArray(value)) {
    return [];
  }

  const normalized = value
    .map((item) => (typeof item === "string" ? item.trim().toLowerCase() : ""))
    .filter((item) => item.length > 0);

  return [...new Set(normalized)];
}

function clampTimerMinutes(value) {
  if (!Number.isFinite(value)) {
    return DEFAULT_TIMER_PRESETS[1];
  }

  return Math.min(1440, Math.max(1, Math.round(value)));
}

function sanitizeTimerSelectionMode(value) {
  return value === TIMER_SELECTION_MODE_MANUAL_END_TIME
    ? TIMER_SELECTION_MODE_MANUAL_END_TIME
    : TIMER_SELECTION_MODE_PRESET;
}

function sanitizeTimerPresets(value) {
  if (!Array.isArray(value)) {
    return [...DEFAULT_TIMER_PRESETS];
  }

  const presets = [];
  for (let index = 0; index < DEFAULT_TIMER_PRESETS.length; index += 1) {
    const nextValue = value[index];
    if (Number.isFinite(nextValue)) {
      presets.push(clampTimerMinutes(Number(nextValue)));
      continue;
    }

    presets.push(DEFAULT_TIMER_PRESETS[index]);
  }

  return presets;
}

function sanitizeSelectedPresetIndex(value) {
  if (!Number.isInteger(value)) {
    return null;
  }

  if (value < 0 || value >= DEFAULT_TIMER_PRESETS.length) {
    return null;
  }

  return value;
}

function findPresetIndexForMinutes(minutes, presets = state.timerPresets) {
  const target = clampTimerMinutes(minutes);
  const index = presets.findIndex((presetMinutes) => presetMinutes === target);
  return index >= 0 ? index : 1;
}

function formatTimeOfDay(hours, minutes) {
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
}

function getDefaultTimerEndTime() {
  const target = new Date(Date.now() + DEFAULT_TIMER_PRESETS[1] * 60 * 1000);
  return formatTimeOfDay(target.getHours(), target.getMinutes());
}

function isValidTimeOfDayString(value) {
  return /^([01]\d|2[0-3]):([0-5]\d)$/.test(String(value || "").trim());
}

function sanitizeTimerEndTime(value) {
  if (!isValidTimeOfDayString(value)) {
    return getDefaultTimerEndTime();
  }

  return String(value).trim();
}

function minutesFromSelectedPreset() {
  const safeIndex = sanitizeSelectedPresetIndex(state.selectedPresetIndex);
  const resolvedIndex = safeIndex === null ? 1 : safeIndex;
  return clampTimerMinutes(state.timerPresets[resolvedIndex]);
}

function computeEndTimeFromMinutes(minutes, nowMs = Date.now()) {
  const clampedMinutes = clampTimerMinutes(minutes);
  const endDate = new Date(nowMs + clampedMinutes * 60 * 1000);
  return formatTimeOfDay(endDate.getHours(), endDate.getMinutes());
}

function getMinutesUntilEndTime(timeOfDay, nowMs = Date.now()) {
  const match = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(String(timeOfDay || "").trim());
  if (!match) {
    return DEFAULT_TIMER_PRESETS[1];
  }

  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  const target = new Date(nowMs);
  target.setHours(hours, minutes, 0, 0);

  if (target.getTime() <= nowMs) {
    target.setDate(target.getDate() + 1);
  }

  return Math.ceil((target.getTime() - nowMs) / (60 * 1000));
}

function normalizePhrase(value) {
  return String(value || "")
    .trim()
    .replace(/\s+/g, " ");
}

function sanitizeUnlockPhrase(value) {
  const normalized = String(value || "")
    .trim()
    .replace(/\s+/g, " ");
  return normalized.length > 0 ? normalized : DEFAULT_UNLOCK_PHRASE;
}

function autoResizeUnlockPhraseSettingField() {
  const field = elements.unlockPhraseSettingInput;
  if (!field) {
    return;
  }

  field.style.height = "auto";
  field.style.height = `${Math.max(field.scrollHeight, 52)}px`;
}

function getReferencePhraseForTyping() {
  return sanitizeUnlockPhrase(state.unlockPhrase);
}

function sanitizeTypedPhraseInput(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .replace(/^\s+/, "");
}

function charsMatchAtIndex(referenceChar, typedChar) {
  return String(referenceChar) === String(typedChar);
}

function appendTypingCharacter(fragment, character, variant, startOffset) {
  const span = document.createElement("span");
  span.className = `typing-char ${variant}`;
  span.textContent = character;
  span.dataset.start = String(startOffset);
  span.dataset.end = String(startOffset + character.length);
  fragment.appendChild(span);
}

function updateTypingCaretPosition(caretBoundaryOffset) {
  const display = elements.unlockPhraseDisplay;
  const caret = elements.unlockPhraseCaret;
  if (!display || !caret || display.hidden || elements.unlockPhraseInput.hidden) {
    if (caret) {
      caret.hidden = true;
    }
    return;
  }

  const firstAtBoundary = display.querySelector(`.typing-char[data-start="${caretBoundaryOffset}"]`);
  const prevAtBoundary = display.querySelector(`.typing-char[data-end="${caretBoundaryOffset}"]`);
  const sourceChar =
    firstAtBoundary ||
    prevAtBoundary ||
    display.querySelector(".typing-char:last-of-type");

  if (!sourceChar) {
    caret.hidden = true;
    return;
  }

  const displayRect = display.getBoundingClientRect();
  const charRect = sourceChar.getBoundingClientRect();
  const isBeforeChar = Boolean(firstAtBoundary);
  const left = isBeforeChar ? charRect.left - displayRect.left : charRect.right - displayRect.left;
  const top = charRect.top - displayRect.top;
  const lineHeight = charRect.height || parseFloat(getComputedStyle(display).lineHeight) || 20;

  caret.hidden = false;
  caret.style.transform = `translate(${left}px, ${top}px)`;
  caret.style.height = `${lineHeight}px`;
}

function renderPhraseTypingPreview() {
  const display = elements.unlockPhraseDisplay;
  if (!display) {
    return;
  }

  const referencePhrase = getReferencePhraseForTyping();
  const typedInput = sanitizeTypedPhraseInput(elements.unlockPhraseInput.value);
  const referenceWords = referencePhrase.split(" ");
  const inputWords = typedInput.length > 0 ? typedInput.split(" ") : [""];
  const totalWords = Math.max(referenceWords.length, inputWords.length);
  const caretWordIndex = Math.max(0, inputWords.length - 1);
  const caretCharIndex = inputWords[caretWordIndex]?.length || 0;
  const fragment = document.createDocumentFragment();
  let renderedOffset = 0;
  let caretBoundaryOffset = 0;

  for (let wordIndex = 0; wordIndex < totalWords; wordIndex += 1) {
    const referenceWord = referenceWords[wordIndex] || "";
    const inputWord = inputWords[wordIndex] || "";
    const overflowWord = inputWord.length > referenceWord.length ? inputWord.slice(referenceWord.length) : "";
    const totalVisibleWordLength = referenceWord.length + overflowWord.length;
    const isCaretWord = wordIndex === caretWordIndex;
    const clampedCaretIndex = Math.min(caretCharIndex, totalVisibleWordLength);

    for (let charIndex = 0; charIndex < referenceWord.length; charIndex += 1) {
      if (isCaretWord && clampedCaretIndex === charIndex) {
        caretBoundaryOffset = renderedOffset;
      }

      const referenceChar = referenceWord[charIndex];
      const typedChar = inputWord[charIndex];
      if (typedChar === undefined) {
        appendTypingCharacter(fragment, referenceChar, "pending", renderedOffset);
      } else if (charsMatchAtIndex(referenceChar, typedChar)) {
        appendTypingCharacter(fragment, referenceChar, "correct", renderedOffset);
      } else {
        appendTypingCharacter(fragment, referenceChar, "incorrect", renderedOffset);
      }

      renderedOffset += 1;
    }

    for (let overflowIndex = 0; overflowIndex < overflowWord.length; overflowIndex += 1) {
      const charPosition = referenceWord.length + overflowIndex;
      if (isCaretWord && clampedCaretIndex === charPosition) {
        caretBoundaryOffset = renderedOffset;
      }

      appendTypingCharacter(fragment, overflowWord[overflowIndex], "extra", renderedOffset);
      renderedOffset += 1;
    }

    if (isCaretWord && clampedCaretIndex === totalVisibleWordLength) {
      caretBoundaryOffset = renderedOffset;
    }

    if (wordIndex < totalWords - 1) {
      const hasTypedSpaceAfterWord = wordIndex < inputWords.length - 1;
      const hasReferenceSpaceAfterWord = wordIndex < referenceWords.length - 1;
      let spaceVariant = "pending";
      if (hasTypedSpaceAfterWord) {
        spaceVariant = hasReferenceSpaceAfterWord ? "correct" : "extra";
      }

      appendTypingCharacter(fragment, " ", spaceVariant, renderedOffset);
      renderedOffset += 1;
    }
  }

  display.replaceChildren(fragment);
  updateTypingCaretPosition(caretBoundaryOffset);
}

function setUnlockConfirmButtonState({ disabled, phraseLocked }) {
  elements.unlockConfirmButton.disabled = disabled;
  elements.unlockConfirmButton.classList.toggle("is-phrase-locked", disabled && phraseLocked === true);
}

function getUrlListValidationError(text = elements.urlList.value) {
  return buildUrlListValidationError(String(text || ""));
}

function updatePowerToggleAvailability() {
  const hasUrlErrors = getUrlListValidationError().length > 0;
  const shouldDisableStart = !state.isBlocking && hasUrlErrors;

  elements.powerSection?.classList.toggle("has-url-errors", shouldDisableStart);
  elements.powerToggle.disabled = shouldDisableStart;
  if (shouldDisableStart) {
    elements.powerToggle.checked = false;
  }
}

function splitUrlListLines(text) {
  return String(text || "").split(/\r?\n/);
}

function isValidIpv4Hostname(hostname) {
  if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(hostname)) {
    return false;
  }

  return hostname.split(".").every((segment) => {
    const value = Number(segment);
    return Number.isInteger(value) && value >= 0 && value <= 255;
  });
}

function isValidUrlHostname(hostname) {
  if (typeof hostname !== "string" || hostname.length === 0) {
    return false;
  }

  if (hostname === "localhost") {
    return true;
  }

  if (hostname.includes(":")) {
    return true;
  }

  if (isValidIpv4Hostname(hostname)) {
    return true;
  }

  return hostname.includes(".") && !hostname.startsWith(".") && !hostname.endsWith(".");
}

function normalizeUrlRule(rawValue) {
  const trimmed = String(rawValue || "").trim().toLowerCase();
  if (trimmed.length === 0 || /\s/.test(trimmed)) {
    return null;
  }

  const hasScheme = /^[a-z][a-z\d+.-]*:\/\//i.test(trimmed);
  if (hasScheme && !/^https?:\/\//i.test(trimmed)) {
    return null;
  }

  const candidate = hasScheme ? trimmed : `https://${trimmed}`;
  try {
    const parsed = new URL(candidate);
    return isValidUrlHostname(parsed.hostname.toLowerCase()) ? trimmed : null;
  } catch {
    return null;
  }
}

function parseUrls(text) {
  return sanitizeList(splitUrlListLines(text));
}

function formatUrls(list) {
  return sanitizeList(list).join("\n");
}

function buildUrlListValidationError(text) {
  const lines = splitUrlListLines(text);
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const rawLine = String(lines[lineIndex] || "").trim();
    if (rawLine.length === 0) {
      continue;
    }

    if (/\s/.test(rawLine)) {
      return `Line ${lineIndex + 1}: one link only`;
    }

    if (!normalizeUrlRule(rawLine)) {
      return `Line ${lineIndex + 1}: invalid link`;
    }
  }

  return "";
}

function setUrlListValidationError(message = "") {
  const text = String(message || "").trim();
  const hasError = text.length > 0;

  elements.urlList.classList.toggle("is-invalid", hasError);
  if (hasError) {
    elements.urlList.setAttribute("aria-invalid", "true");
  } else {
    elements.urlList.removeAttribute("aria-invalid");
  }

  if (!elements.urlListError) {
    updatePowerToggleAvailability();
    return;
  }

  elements.urlListError.textContent = text;
  elements.urlListError.hidden = !hasError;
  updatePowerToggleAvailability();
}

function clearPendingUrlListValidation() {
  if (urlListValidationTimeoutId !== null) {
    clearTimeout(urlListValidationTimeoutId);
    urlListValidationTimeoutId = null;
  }
}

function scheduleUrlListValidation(text) {
  const draftText = String(text || "");
  clearPendingUrlListValidation();
  urlListValidationTimeoutId = window.setTimeout(() => {
    urlListValidationTimeoutId = null;
    setUrlListValidationError(buildUrlListValidationError(draftText));
  }, URL_LIST_VALIDATION_DELAY_MS);
}

function buildUrlListSyncDraft() {
  return {
    mode: sanitizeMode(elements.modeSelect.value),
    text: String(elements.urlList.value || "")
  };
}

function applyUrlListDraftToState(draft) {
  const safeDraft = draft ?? buildUrlListSyncDraft();
  const mode = sanitizeMode(safeDraft.mode);
  const parsedUrls = parseUrls(safeDraft.text);
  if (mode === "allow") {
    state.whiteList = parsedUrls;
    return mode;
  }

  state.blockList = parsedUrls;
  return mode;
}

function persistUrlListDraft(draft, errorLabel = "Failed to save URL list") {
  const mode = applyUrlListDraftToState(draft);
  const payload = mode === "allow" ? { whiteList: state.whiteList } : { blockList: state.blockList };
  void browser.storage.local.set(payload).catch((error) => {
    console.error(errorLabel, error);
  });
}

function clearPendingUrlListSync() {
  if (urlListSyncTimeoutId !== null) {
    clearTimeout(urlListSyncTimeoutId);
    urlListSyncTimeoutId = null;
  }
  pendingUrlListSyncDraft = null;
}

function scheduleUrlListSync() {
  pendingUrlListSyncDraft = buildUrlListSyncDraft();
  setUrlListValidationError("");
  clearPendingUrlListValidation();
  updatePowerToggleAvailability();
  if (urlListSyncTimeoutId !== null) {
    clearTimeout(urlListSyncTimeoutId);
  }

  urlListSyncTimeoutId = window.setTimeout(() => {
    const draft = pendingUrlListSyncDraft;
    urlListSyncTimeoutId = null;
    pendingUrlListSyncDraft = null;
    if (!draft) {
      return;
    }

    persistUrlListDraft(draft);
    scheduleUrlListValidation(draft.text);
  }, URL_LIST_SYNC_DEBOUNCE_MS);
}

function flushPendingUrlListSync() {
  if (urlListSyncTimeoutId !== null) {
    clearTimeout(urlListSyncTimeoutId);
    urlListSyncTimeoutId = null;
  }

  const draft = pendingUrlListSyncDraft ?? buildUrlListSyncDraft();
  pendingUrlListSyncDraft = null;
  persistUrlListDraft(draft);
  setUrlListValidationError("");
  scheduleUrlListValidation(draft.text);
  updatePowerToggleAvailability();
}

function formatDuration(totalMs) {
  const totalSeconds = Math.ceil(Math.max(0, totalMs) / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

function getActiveListKey() {
  return state.mode === "allow" ? "whiteList" : "blockList";
}

function getRemainingMs() {
  return Math.max(0, (state.lockEndTime || 0) - Date.now());
}

function getPauseRemainingMs() {
  return Math.max(0, (state.pauseUntil || 0) - Date.now());
}

function updatePresetButtons() {
  for (const button of elements.timerPresetButtons) {
    const presetIndex = sanitizeSelectedPresetIndex(Number(button.dataset.presetIndex));
    if (presetIndex === null) {
      continue;
    }

    const presetMinutes = clampTimerMinutes(state.timerPresets[presetIndex]);
    const isActive =
      state.timerSelectionMode === TIMER_SELECTION_MODE_PRESET &&
      state.selectedPresetIndex === presetIndex;

    button.classList.toggle("is-active", isActive);
    button.dataset.minutes = String(presetMinutes);

    if (!presetEditState || presetEditState.index !== presetIndex) {
      button.textContent = `${presetMinutes}m`;
    }
  }
}

function updateTimerEndTimeInputFromState() {
  if (state.timerSelectionMode === TIMER_SELECTION_MODE_PRESET) {
    if (document.activeElement === elements.timerEndTimeInput) {
      return;
    }
    elements.timerEndTimeInput.value = computeEndTimeFromMinutes(minutesFromSelectedPreset());
    return;
  }

  if (isValidTimeOfDayString(state.manualEndTime)) {
    elements.timerEndTimeInput.value = state.manualEndTime;
  } else {
    elements.timerEndTimeInput.value = sanitizeTimerEndTime(state.manualEndTime);
  }
}

function stopPresetEndTimeTicker() {
  if (presetEndTimeTickId !== null) {
    clearInterval(presetEndTimeTickId);
    presetEndTimeTickId = null;
  }
}

function reconcilePresetEndTimeTicker() {
  stopPresetEndTimeTicker();
  if (state.timerSelectionMode !== TIMER_SELECTION_MODE_PRESET) {
    return;
  }

  presetEndTimeTickId = window.setInterval(() => {
    updateTimerEndTimeInputFromState();
  }, 1000);
}

function syncTimerControlsFromState() {
  state.timerSelectionMode = sanitizeTimerSelectionMode(state.timerSelectionMode);
  state.timerPresets = sanitizeTimerPresets(state.timerPresets);
  state.selectedPresetIndex = sanitizeSelectedPresetIndex(state.selectedPresetIndex);
  state.manualEndTime = sanitizeTimerEndTime(state.manualEndTime);

  if (state.timerSelectionMode === TIMER_SELECTION_MODE_PRESET) {
    if (state.selectedPresetIndex === null) {
      state.selectedPresetIndex = findPresetIndexForMinutes(state.timerMinutes, state.timerPresets);
    }
    state.timerMinutes = minutesFromSelectedPreset();
  } else {
    state.selectedPresetIndex = null;
    state.timerMinutes = clampTimerMinutes(getMinutesUntilEndTime(state.manualEndTime));
  }

  updatePresetButtons();
  updateTimerEndTimeInputFromState();
  reconcilePresetEndTimeTicker();
}

function updateStatus(text) {
  elements.statusArea.textContent = text;
}

function setChallengeVisibility(isVisible) {
  elements.body.classList.toggle("is-unlock-pending", isVisible);
  elements.unlockChallenge.setAttribute("aria-hidden", String(!isVisible));
  if (!isVisible) {
    elements.unlockPhraseInput.blur();
  }
}

function setSettingsBlocked(isBlocked) {
  elements.settingsDropdown.classList.toggle("is-blocked", isBlocked);
  elements.settingsSummary.setAttribute("aria-disabled", String(isBlocked));

  if (isBlocked) {
    elements.settingsDropdown.open = false;
    elements.settingsDropdown.setAttribute("inert", "");
    elements.settingsSummary.tabIndex = -1;
    if (document.activeElement === elements.settingsSummary) {
      elements.settingsSummary.blur();
    }
    return;
  }

  elements.settingsDropdown.removeAttribute("inert");
  elements.settingsSummary.removeAttribute("tabindex");
}

function updateTimerSettingsVisibility() {
  const showTimerSettings = state.unlockMode === "timer";
  elements.timerSettingsGroup.hidden = !showTimerSettings;
  elements.timerEndTimeInput.disabled = !showTimerSettings;

  if (elements.unlockPhraseSettingDropdown) {
    elements.unlockPhraseSettingDropdown.open = state.unlockMode === "phrase";
  }

  if (elements.unlockPhraseSettingSummary) {
    elements.unlockPhraseSettingSummary.textContent =
      state.unlockMode === "timer" ? "Pause phrase" : "Unlock phrase";
  }
}

function setPhraseControls({ visible, label, disabled }) {
  elements.unlockPhraseLabel.hidden = !visible;
  elements.unlockPhraseDisplay.hidden = !visible;
  elements.unlockPhraseInput.hidden = !visible;
  elements.unlockPhraseInput.disabled = disabled;
  if (!visible || disabled) {
    elements.unlockPhraseInput.blur();
  }
  if (label) {
    elements.unlockPhraseLabel.textContent = label;
  }

  renderPhraseTypingPreview();
}

function focusUnlockControl() {
  window.requestAnimationFrame(() => {
    if (!state.isBlocking || !isUnlockChallengeOpen) {
      return;
    }

    const canType =
      !elements.unlockPhraseInput.hidden &&
      !elements.unlockPhraseInput.disabled &&
      elements.unlockPhraseInput.offsetParent !== null;

    if (canType) {
      elements.unlockPhraseInput.focus();
      return;
    }

    if (!elements.unlockConfirmButton.disabled && elements.unlockConfirmButton.offsetParent !== null) {
      elements.unlockConfirmButton.focus();
    }
  });
}

function openUnlockChallenge() {
  if (!state.isBlocking) {
    return;
  }

  isUnlockChallengeOpen = true;
  setChallengeVisibility(true);
  updateLockedChallenge();
  focusUnlockControl();
}

function syncFormFromState() {
  elements.modeSelect.value = state.mode;
  const formattedActiveList = formatUrls(state[getActiveListKey()]);
  if (document.activeElement !== elements.urlList) {
    elements.urlList.value = formattedActiveList;
  }
  setUrlListValidationError(getUrlListValidationError(elements.urlList.value));
  elements.unlockModeSelect.value = state.unlockMode;
  updateTimerSettingsVisibility();
  elements.unlockPhraseSettingInput.value = sanitizeUnlockPhrase(state.unlockPhrase);
  autoResizeUnlockPhraseSettingField();
  syncTimerControlsFromState();
}

function applyFormToState() {
  state.mode = sanitizeMode(elements.modeSelect.value);
  state.unlockMode = sanitizeUnlockMode(elements.unlockModeSelect.value);
  state.unlockPhrase = sanitizeUnlockPhrase(elements.unlockPhraseSettingInput.value);

  if (state.timerSelectionMode === TIMER_SELECTION_MODE_PRESET) {
    state.timerMinutes = minutesFromSelectedPreset();
  } else {
    state.manualEndTime = sanitizeTimerEndTime(elements.timerEndTimeInput.value);
    state.timerMinutes = clampTimerMinutes(getMinutesUntilEndTime(state.manualEndTime));
  }

  const parsedUrls = parseUrls(elements.urlList.value);
  if (state.mode === "allow") {
    state.whiteList = parsedUrls;
  } else {
    state.blockList = parsedUrls;
  }
}

async function saveStateToStorage() {
  await browser.storage.local.set({
    isBlocking: state.isBlocking,
    mode: state.mode,
    blockList: state.blockList,
    whiteList: state.whiteList,
    unlockMode: state.unlockMode,
    timerMinutes: state.timerMinutes,
    timerPresets: state.timerPresets,
    timerSelectionMode: state.timerSelectionMode,
    selectedPresetIndex: state.selectedPresetIndex,
    manualEndTime: state.manualEndTime,
    unlockPhrase: state.unlockPhrase,
    lockEndTime: state.lockEndTime,
    timerExpired: state.timerExpired,
    pausePositiveEnabled: state.pausePositiveEnabled,
    pauseUntil: state.pauseUntil,
    testDisableUntil: state.testDisableUntil
  });
}

async function loadStateFromStorage() {
  const stored = await browser.storage.local.get(STORAGE_KEYS);

  state.isBlocking = stored.isBlocking === true;
  state.mode = sanitizeMode(stored.mode);
  state.blockList = sanitizeList(stored.blockList);
  state.whiteList = sanitizeList(stored.whiteList);
  state.unlockMode = sanitizeUnlockMode(stored.unlockMode);

  const storedTimerMinutes = clampTimerMinutes(Number(stored.timerMinutes));
  state.timerPresets = sanitizeTimerPresets(stored.timerPresets);

  const migratedSelectionMode =
    stored.timerType === "endTime" ? TIMER_SELECTION_MODE_MANUAL_END_TIME : TIMER_SELECTION_MODE_PRESET;
  state.timerSelectionMode = sanitizeTimerSelectionMode(stored.timerSelectionMode ?? migratedSelectionMode);

  const fallbackPresetIndex = findPresetIndexForMinutes(storedTimerMinutes, state.timerPresets);
  state.selectedPresetIndex = sanitizeSelectedPresetIndex(stored.selectedPresetIndex);
  if (state.timerSelectionMode === TIMER_SELECTION_MODE_PRESET && state.selectedPresetIndex === null) {
    state.selectedPresetIndex = fallbackPresetIndex;
  }

  const migratedManualEndTime =
    typeof stored.timerEndTime === "string"
      ? sanitizeTimerEndTime(stored.timerEndTime)
      : computeEndTimeFromMinutes(state.timerPresets[fallbackPresetIndex]);
  state.manualEndTime = sanitizeTimerEndTime(stored.manualEndTime ?? migratedManualEndTime);

  if (state.timerSelectionMode === TIMER_SELECTION_MODE_PRESET) {
    state.timerMinutes = minutesFromSelectedPreset();
  } else {
    state.selectedPresetIndex = null;
    state.timerMinutes = clampTimerMinutes(getMinutesUntilEndTime(state.manualEndTime));
  }

  state.unlockPhrase =
    typeof stored.unlockPhrase === "string"
      ? sanitizeUnlockPhrase(stored.unlockPhrase)
      : DEFAULT_UNLOCK_PHRASE;
  state.lockEndTime = Number.isFinite(stored.lockEndTime) ? stored.lockEndTime : 0;
  state.timerExpired = typeof stored.timerExpired === "boolean" ? stored.timerExpired : true;
  state.pausePositiveEnabled =
    typeof stored.pausePositiveEnabled === "boolean" ? stored.pausePositiveEnabled : true;
  state.pauseUntil = Number.isFinite(stored.pauseUntil) ? stored.pauseUntil : 0;
  state.testDisableUntil = Number.isFinite(stored.testDisableUntil) ? stored.testDisableUntil : 0;
}

function updateLockedChallenge() {
  renderPhraseTypingPreview();

  const isTimerMode = state.unlockMode === "timer";
  const phraseInput = normalizePhrase(elements.unlockPhraseInput.value);
  const expectedPhrase = normalizePhrase(state.unlockPhrase);

  if (isTimerMode) {
    const pauseRemaining = getPauseRemainingMs();
    if (pauseRemaining > 0) {
      setPhraseControls({ visible: false, label: "Unlock phrase", disabled: true });
      setUnlockConfirmButtonState({ disabled: true, phraseLocked: false });
      elements.unlockConfirmButton.textContent = "Paused";
      updateStatus(`Pause active: ${formatDuration(pauseRemaining)}`);
      return;
    }

    if (state.timerExpired) {
      setPhraseControls({ visible: false, label: "Unlock phrase", disabled: true });
      setUnlockConfirmButtonState({ disabled: true, phraseLocked: false });
      elements.unlockConfirmButton.textContent = "Confirm";
      updateStatus("Timer complete");
      return;
    }

    const remaining = getRemainingMs();
    updateStatus(`Locked: ${formatDuration(remaining)}`);

    if (state.pausePositiveEnabled) {
      setPhraseControls({
        visible: true,
        label: "Pause phrase",
        disabled: false
      });
      const phraseMatches = phraseInput === expectedPhrase;
      setUnlockConfirmButtonState({ disabled: !phraseMatches, phraseLocked: !phraseMatches });
      elements.unlockConfirmButton.textContent = "Pause 2 min";
      return;
    }

    setPhraseControls({ visible: false, label: "Unlock phrase", disabled: true });
    setUnlockConfirmButtonState({ disabled: true, phraseLocked: false });
    elements.unlockConfirmButton.textContent = "Wait for timer";
    return;
  }

  setPhraseControls({ visible: true, label: "Unlock phrase", disabled: false });
  const phraseMatches = phraseInput === expectedPhrase;
  setUnlockConfirmButtonState({ disabled: !phraseMatches, phraseLocked: !phraseMatches });
  elements.unlockConfirmButton.textContent = "Confirm";
  updateStatus("Locked: phrase required");
}

function stopTimerTick() {
  if (timerTickId !== null) {
    clearInterval(timerTickId);
    timerTickId = null;
  }
}

function startTimerTick() {
  stopTimerTick();
  if (!state.isBlocking || state.unlockMode !== "timer") {
    return;
  }

  timerTickId = window.setInterval(() => {
    updateLockedChallenge();
  }, 1000);
}

function renderUi() {
  elements.powerToggle.checked = state.isBlocking;
  updatePowerToggleAvailability();
  elements.powerToggleAssistiveText.textContent = state.isBlocking
    ? "Stop blocking"
    : "Start blocking";

  if (state.isBlocking) {
    if (state.unlockMode === "timer" && state.timerExpired) {
      isUnlockChallengeOpen = false;
    }
    setSettingsBlocked(true);
    setChallengeVisibility(isUnlockChallengeOpen);
    updateLockedChallenge();
    startTimerTick();
    return;
  }

  stopTimerTick();
  setSettingsBlocked(false);
  isUnlockChallengeOpen = false;
  setChallengeVisibility(false);
  elements.unlockPhraseInput.value = "";
  setPhraseControls({ visible: true, label: "Unlock phrase", disabled: false });
  setUnlockConfirmButtonState({ disabled: false, phraseLocked: false });
  elements.unlockConfirmButton.textContent = "Confirm";
  updateStatus("");
}

function collectPayloadFromState() {
  return {
    mode: state.mode,
    blockList: state.blockList,
    whiteList: state.whiteList,
    unlockMode: state.unlockMode,
    timerMinutes: state.timerMinutes,
    unlockPhrase: state.unlockPhrase,
    pausePositiveEnabled: state.pausePositiveEnabled
  };
}

async function startBlocking() {
  if (presetEditState) {
    stopPresetEditing(true, false);
  }

  applyFormToState();

  if (state.unlockMode === "timer") {
    state.timerExpired = false;
    state.lockEndTime = Date.now() + state.timerMinutes * 60 * 1000;
  } else {
    state.timerExpired = true;
    state.lockEndTime = 0;
  }
  state.pauseUntil = 0;
  state.isBlocking = true;
  renderUi();

  try {
    await saveStateToStorage();
    const response = await browser.runtime.sendMessage({
      type: "START_BLOCKING",
      payload: collectPayloadFromState()
    });

    if (!response || response.ok !== true) {
      throw new Error(response?.error || "START_BLOCKING_FAILED");
    }

    if (Number.isFinite(response.lockEndTime)) {
      state.lockEndTime = response.lockEndTime;
    }

    if (typeof response.timerExpired === "boolean") {
      state.timerExpired = response.timerExpired;
    }

    if (Number.isFinite(response.pauseUntil)) {
      state.pauseUntil = response.pauseUntil;
    }

    await saveStateToStorage();
    renderUi();
  } catch (error) {
    state.isBlocking = false;
    state.timerExpired = true;
    state.pauseUntil = 0;
    elements.powerToggle.checked = false;
    updateStatus("Could not start blocking");
    renderUi();
    console.error("START_BLOCKING failed", error);
  }
}

async function stopBlocking() {
  try {
    const response = await browser.runtime.sendMessage({ type: "STOP_BLOCKING" });
    if (!response || response.ok !== true) {
      if (response?.error === "TIMER_NOT_EXPIRED") {
        updateStatus("Timer still active");
      } else {
        updateStatus("Could not stop blocking");
      }
      elements.powerToggle.checked = state.isBlocking;
      return;
    }

    state.isBlocking = false;
    state.timerExpired = true;
    state.pauseUntil = 0;
    state.lockEndTime = 0;
    await saveStateToStorage();
    renderUi();
  } catch (error) {
    updateStatus("Could not stop blocking");
    elements.powerToggle.checked = state.isBlocking;
    console.error("STOP_BLOCKING failed", error);
  }
}

async function requestPausePositive() {
  const phrase = normalizePhrase(elements.unlockPhraseInput.value);
  const expectedPhrase = normalizePhrase(state.unlockPhrase);
  if (phrase !== expectedPhrase) {
    updateStatus("Phrase does not match");
    return;
  }

  try {
    const response = await browser.runtime.sendMessage({
      type: "REQUEST_PAUSE_POSITIVE",
      payload: { phrase: elements.unlockPhraseInput.value }
    });

    if (!response || response.ok !== true) {
      if (response?.error === "PAUSE_POSITIVE_DISABLED") {
        updateStatus("Pause mode is disabled");
      } else {
        updateStatus("Could not start pause");
      }
      return;
    }

    if (Number.isFinite(response.pauseUntil)) {
      state.pauseUntil = response.pauseUntil;
    }

    elements.unlockPhraseInput.value = "";
    renderUi();
  } catch (error) {
    updateStatus("Could not start pause");
    console.error("REQUEST_PAUSE_POSITIVE failed", error);
  }
}

async function handlePowerToggleChange() {
  if (!state.isBlocking && elements.powerToggle.checked) {
    const validationError = getUrlListValidationError(elements.urlList.value);
    if (validationError) {
      clearPendingUrlListValidation();
      setUrlListValidationError(validationError);
      elements.powerToggle.checked = false;
      return;
    }

    await startBlocking();
    return;
  }

  if (state.isBlocking && !elements.powerToggle.checked) {
    if (state.unlockMode === "timer" && state.timerExpired) {
      await stopBlocking();
      return;
    }

    elements.powerToggle.checked = true;
    openUnlockChallenge();
    return;
  }

  elements.powerToggle.checked = state.isBlocking;
}

async function handleUnlockConfirmClick() {
  if (!state.isBlocking) {
    return;
  }

  if (state.unlockMode === "timer") {
    if (state.timerExpired) {
      await stopBlocking();
      return;
    }

    if (state.pausePositiveEnabled) {
      await requestPausePositive();
      return;
    }

    updateLockedChallenge();
    return;
  }

  const expectedPhrase = normalizePhrase(state.unlockPhrase);
  const actualPhrase = normalizePhrase(elements.unlockPhraseInput.value);
  if (actualPhrase !== expectedPhrase) {
    updateStatus("Phrase does not match");
    return;
  }

  await stopBlocking();
}

function handleModeChange() {
  clearPendingUrlListSync();
  clearPendingUrlListValidation();
  setUrlListValidationError("");
  state[getActiveListKey()] = parseUrls(elements.urlList.value);
  state.mode = sanitizeMode(elements.modeSelect.value);
  elements.urlList.value = formatUrls(state[getActiveListKey()]);
  setUrlListValidationError(getUrlListValidationError(elements.urlList.value));
  updatePowerToggleAvailability();

  void browser.storage.local
    .set({
      mode: state.mode,
      blockList: state.blockList,
      whiteList: state.whiteList
    })
    .catch((error) => {
      console.error("Failed to save list mode change", error);
    });
}

function handleUrlListInput() {
  updatePowerToggleAvailability();
  scheduleUrlListSync();
}

function handleUrlListBlur() {
  flushPendingUrlListSync();
}

function persistTimerSettings(errorLabel) {
  void browser.storage.local
    .set({
      timerMinutes: state.timerMinutes,
      timerPresets: state.timerPresets,
      timerSelectionMode: state.timerSelectionMode,
      selectedPresetIndex: state.selectedPresetIndex,
      manualEndTime: state.manualEndTime
    })
    .catch((error) => {
      console.error(errorLabel, error);
    });
}

function applyEditedPresetMinutes(index, rawValue) {
  const presetIndex = sanitizeSelectedPresetIndex(index);
  if (presetIndex === null) {
    return false;
  }

  const parsedMinutes = Number(String(rawValue || "").trim());
  const isValidMinutes = Number.isInteger(parsedMinutes) && parsedMinutes >= 1 && parsedMinutes <= 1440;
  if (!isValidMinutes) {
    return false;
  }

  state.timerPresets[presetIndex] = clampTimerMinutes(parsedMinutes);
  state.timerSelectionMode = TIMER_SELECTION_MODE_PRESET;
  state.selectedPresetIndex = presetIndex;
  state.timerMinutes = minutesFromSelectedPreset();
  return true;
}

function schedulePresetEditingSync() {
  if (!presetEditState) {
    return;
  }

  if (presetEditState.syncTimeoutId !== null) {
    clearTimeout(presetEditState.syncTimeoutId);
  }

  presetEditState.syncTimeoutId = window.setTimeout(() => {
    if (!presetEditState) {
      return;
    }

    const didApply = applyEditedPresetMinutes(presetEditState.index, presetEditState.input.value);
    if (!didApply) {
      return;
    }

    syncTimerControlsFromState();
    persistTimerSettings("Failed to save edited timer preset");
  }, INPUT_SYNC_DEBOUNCE_MS);
}

function selectTimerPreset(index) {
  const presetIndex = sanitizeSelectedPresetIndex(index);
  if (presetIndex === null) {
    return;
  }

  state.timerSelectionMode = TIMER_SELECTION_MODE_PRESET;
  state.selectedPresetIndex = presetIndex;
  state.timerMinutes = minutesFromSelectedPreset();
  syncTimerControlsFromState();
  persistTimerSettings("Failed to save timer preset");
}

function stopPresetEditing(commit, shouldPersist = true) {
  if (!presetEditState) {
    return;
  }

  const { index, button, input, syncTimeoutId } = presetEditState;
  if (syncTimeoutId !== null) {
    clearTimeout(syncTimeoutId);
  }
  const shouldApply = commit === true && applyEditedPresetMinutes(index, input.value);

  presetEditState = null;
  button.classList.remove("is-editing");
  button.replaceChildren();

  syncTimerControlsFromState();
  if (shouldApply && shouldPersist) {
    persistTimerSettings("Failed to save edited timer preset");
  }
}

function beginPresetEditing(index, button) {
  const presetIndex = sanitizeSelectedPresetIndex(index);
  if (presetIndex === null) {
    return;
  }

  if (presetEditState) {
    stopPresetEditing(false);
  }

  const input = document.createElement("input");
  input.type = "text";
  input.inputMode = "numeric";
  input.className = "timer-preset-editor";
  input.value = String(clampTimerMinutes(state.timerPresets[presetIndex]));

  button.classList.add("is-editing");
  button.replaceChildren(input);
  presetEditState = { index: presetIndex, button, input, syncTimeoutId: null };

  input.addEventListener("input", () => {
    input.value = input.value.replace(/[^\d]/g, "");
    schedulePresetEditingSync();
  });
  input.addEventListener("keydown", (event) => {
    event.stopPropagation();
    if (event.key === "Enter") {
      event.preventDefault();
      stopPresetEditing(true);
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      stopPresetEditing(false);
    }
  });
  input.addEventListener("blur", () => {
    stopPresetEditing(true);
  });

  input.focus();
  input.select();
}

function handleTimerPresetClick(event) {
  const presetButton = event.target.closest("[data-preset-index]");
  if (!presetButton) {
    return;
  }

  if (presetEditState) {
    return;
  }

  selectTimerPreset(Number(presetButton.dataset.presetIndex));
}

function handleTimerPresetDoubleClick(event) {
  const presetButton = event.target.closest("[data-preset-index]");
  if (!presetButton) {
    return;
  }

  beginPresetEditing(Number(presetButton.dataset.presetIndex), presetButton);
}

function handleTimerEndTimeInput() {
  const rawValue = String(elements.timerEndTimeInput.value || "").trim();
  if (!isValidTimeOfDayString(rawValue)) {
    return;
  }

  state.manualEndTime = rawValue;
  state.timerSelectionMode = TIMER_SELECTION_MODE_MANUAL_END_TIME;
  state.selectedPresetIndex = null;
  state.timerMinutes = clampTimerMinutes(getMinutesUntilEndTime(state.manualEndTime));
  syncTimerControlsFromState();
  persistTimerSettings("Failed to save timer end time");
}

function handleTimerEndTimeChange() {
  state.manualEndTime = sanitizeTimerEndTime(elements.timerEndTimeInput.value);
  state.timerSelectionMode = TIMER_SELECTION_MODE_MANUAL_END_TIME;
  state.selectedPresetIndex = null;
  state.timerMinutes = clampTimerMinutes(getMinutesUntilEndTime(state.manualEndTime));
  syncTimerControlsFromState();
  persistTimerSettings("Failed to save timer end time");
}

function handleUnlockModeChange() {
  state.unlockMode = sanitizeUnlockMode(elements.unlockModeSelect.value);
  updateTimerSettingsVisibility();
  if (state.isBlocking) {
    updateLockedChallenge();
    startTimerTick();
  }

  void saveStateToStorage().catch((error) => {
    console.error("Failed to save unlock mode", error);
  });
}

function handleUnlockPhraseSettingInput() {
  const sanitized = sanitizeUnlockPhrase(elements.unlockPhraseSettingInput.value);
  if (elements.unlockPhraseSettingInput.value !== sanitized) {
    elements.unlockPhraseSettingInput.value = sanitized;
  }

  autoResizeUnlockPhraseSettingField();
  state.unlockPhrase = sanitized;
  renderPhraseTypingPreview();
  void saveStateToStorage().catch((error) => {
    console.error("Failed to save unlock phrase", error);
  });
}

function handleUnlockPhraseSettingTyping() {
  autoResizeUnlockPhraseSettingField();
}

function handleUnlockPhraseSettingDropdownToggle() {
  if (!elements.unlockPhraseSettingDropdown?.open) {
    return;
  }

  autoResizeUnlockPhraseSettingField();
}

function handlePhraseInput() {
  const sanitized = sanitizeTypedPhraseInput(elements.unlockPhraseInput.value);
  if (sanitized !== elements.unlockPhraseInput.value) {
    elements.unlockPhraseInput.value = sanitized;
  }

  if (state.isBlocking) {
    updateLockedChallenge();
    return;
  }

  renderPhraseTypingPreview();
}

function handlePhraseInputFocus() {
  elements.unlockPhraseDisplay.classList.add("is-focus-visible");
}

function handlePhraseInputBlur() {
  elements.unlockPhraseDisplay.classList.remove("is-focus-visible");
}

function handleUnlockPhraseKeydown(event) {
  if (event.key !== "Enter") {
    return;
  }

  const canSubmit =
    state.isBlocking &&
    !elements.unlockConfirmButton.disabled &&
    !elements.unlockConfirmButton.classList.contains("is-phrase-locked") &&
    elements.unlockConfirmButton.offsetParent !== null;

  if (!canSubmit) {
    return;
  }

  event.preventDefault();
  void handleUnlockConfirmClick();
}

function refreshFromStorage() {
  void loadStateFromStorage()
    .then(() => {
      syncFormFromState();
      renderUi();
    })
    .catch((error) => {
      console.error("Failed to refresh popup state", error);
    });
}

function handleStorageChanged(changes, areaName) {
  if (areaName !== "local") {
    return;
  }

  for (const key of STORAGE_KEYS) {
    if (key in changes) {
      refreshFromStorage();
      return;
    }
  }
}

function handleRuntimeMessage(message = {}) {
  if (
    message.type === "UNLOCK_TIMER_EXPIRED" ||
    message.type === "PAUSE_POSITIVE_STARTED" ||
    message.type === "PAUSE_POSITIVE_ENDED" ||
    message.type === "TEST_DISABLE_STARTED" ||
    message.type === "TEST_DISABLE_EXPIRED"
  ) {
    refreshFromStorage();
  }
}

async function initializePopup() {
  await loadStateFromStorage();
  syncFormFromState();
  renderUi();

  elements.powerToggle.addEventListener("change", () => {
    void handlePowerToggleChange();
  });
  elements.unlockConfirmButton.addEventListener("click", () => {
    void handleUnlockConfirmClick();
  });
  elements.modeSelect.addEventListener("change", handleModeChange);
  elements.urlList.addEventListener("input", handleUrlListInput);
  elements.urlList.addEventListener("blur", handleUrlListBlur);
  elements.urlList.addEventListener("change", handleUrlListBlur);
  elements.unlockModeSelect.addEventListener("change", handleUnlockModeChange);
  elements.unlockPhraseSettingInput.addEventListener("input", handleUnlockPhraseSettingTyping);
  elements.unlockPhraseSettingInput.addEventListener("change", handleUnlockPhraseSettingInput);
  elements.unlockPhraseSettingInput.addEventListener("blur", handleUnlockPhraseSettingInput);
  elements.unlockPhraseSettingDropdown?.addEventListener("toggle", handleUnlockPhraseSettingDropdownToggle);
  elements.timerEndTimeInput.addEventListener("input", handleTimerEndTimeInput);
  elements.timerEndTimeInput.addEventListener("change", handleTimerEndTimeChange);
  elements.timerPresets.addEventListener("click", handleTimerPresetClick);
  elements.timerPresets.addEventListener("dblclick", handleTimerPresetDoubleClick);
  elements.unlockPhraseInput.addEventListener("input", handlePhraseInput);
  elements.unlockPhraseInput.addEventListener("keydown", handleUnlockPhraseKeydown);
  elements.unlockPhraseInput.addEventListener("focus", handlePhraseInputFocus);
  elements.unlockPhraseInput.addEventListener("blur", handlePhraseInputBlur);
  window.addEventListener("resize", renderPhraseTypingPreview);
  window.addEventListener("beforeunload", () => {
    flushPendingUrlListSync();
    clearPendingUrlListValidation();
    stopPresetEndTimeTicker();
    if (presetEditState) {
      stopPresetEditing(true);
    }
  });

  browser.storage.onChanged.addListener(handleStorageChanged);
  browser.runtime.onMessage.addListener(handleRuntimeMessage);
}

void initializePopup().catch((error) => {
  updateStatus("Initialization failed");
  console.error("Popup initialization failed", error);
});
