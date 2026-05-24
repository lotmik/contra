"use strict";

const DEFAULT_UNLOCK_PHRASE = "I swear to God and to my future self that my internet usage will not ruin my cognitive abilities or stop me from achieving my life goals";
const DEFAULT_TIMER_PRESETS = [15, 25, 45, 60];
const TIMER_SELECTION_MODE_PRESET = "preset";
const TIMER_SELECTION_MODE_MANUAL_END_TIME = "manualEndTime";
const TIMER_PRESET_SHORTCUT_DOUBLE_PRESS_MS = 400;
const TIMER_END_TIME_WARNING_MINUTES = 4 * 60;
const TIMER_END_TIME_WARNING_TEXT = "Timer exceeds 4 hours. Proceed if desired";
const INPUT_SYNC_DEBOUNCE_MS = 500;
const URL_LIST_SYNC_DEBOUNCE_MS = 250;
const URL_LIST_VALIDATION_DELAY_MS = 500;
const UNLOCK_PHRASE_SETTING_MIN_HEIGHT = 0;
const PAUSE_POSITIVE_MS = 2 * 60 * 1000;
const COLLAPSED_CURRENT_TAB_SAVED_FEEDBACK_MS = 5000;
const CURRENT_TAB_RULE_LABELS = {
  block: "add this site",
  allow: "add this page"
};
const COLLAPSED_CURRENT_TAB_LABELS = {
  block: "add to blocklist",
  allow: "add to allowlist"
};
const COLLAPSED_CURRENT_TAB_ICON_PATHS = {
  add: "M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z",
  saved: "M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"
};
const CURRENT_TAB_SUPPORTED_PROTOCOLS = new Set(["http:", "https:"]);
const MANAGED_POLICY_FORCE_ADULT_KEYS = ["forceAdultBlock", "forceAdultBlocking", "adultBlockForced", "adult"];
const STORAGE_KEYS = [
  "isBlocking",
  "mode",
  "blockList",
  "whiteList",
  "adultContentBlockingEnabled",
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
  adultContentBlockingEnabled: true,
  adultContentForcedByPolicy: false,
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
let lastPresetShortcut = { index: null, timestamp: 0 };
let urlListSyncTimeoutId = null;
let pendingUrlListSyncDraft = null;
let urlListValidationTimeoutId = null;
let isSiteAddFormVisible = false;
let isSiteImportPopoverVisible = false;
let isSyncingSettingsAccordion = false;
let isMeasuringUnlockModeSettingsHeight = false;
let skipNextUnlockPhraseSettingBlurSave = false;
let currentTabUrl = "";
let canAddCurrentTab = false;
let collapsedCurrentTabSavedFeedbackTimeoutId = null;

const elements = {
  body: document.body,
  popupShell: document.getElementById("popup-shell"),
  popupRoot: document.getElementById("popup-root"),
  progressLine: document.getElementById("progress-line"),
  powerSection: document.querySelector(".power-section"),
  powerToggle: document.getElementById("power-toggle"),
  powerToggleAssistiveText: document.querySelector("#power-toggle-label .sr-only"),
  unlockChallenge: document.getElementById("unlock-challenge"),
  unlockTimerPanel: document.getElementById("unlock-timer-panel"),
  unlockTimerCountdown: document.getElementById("unlock-timer-countdown"),
  unlockTimerCaption: document.getElementById("unlock-timer-caption"),
  unlockPhraseLabel: document.querySelector('label[for="unlock-phrase-input"]'),
  unlockTypingSurface: document.getElementById("unlock-typing-surface"),
  unlockPhraseInput: document.getElementById("unlock-phrase-input"),
  unlockPhraseDisplay: document.getElementById("unlock-phrase-display"),
  unlockPhraseCaret: document.getElementById("unlock-phrase-caret"),
  unlockActionRow: document.getElementById("unlock-action-row"),
  unlockBreakButton: document.getElementById("unlock-break-btn"),
  unlockConfirmButton: document.getElementById("unlock-confirm-btn"),
  settingsDropdown: document.getElementById("settings-dropdown"),
  settingsSummary: document.getElementById("settings-summary"),
  collapsedSiteCurrentButton: document.getElementById("collapsed-site-current-button"),
  collapsedSiteCurrentButtonLabel: document.getElementById("collapsed-site-current-button-label"),
  collapsedSiteCurrentButtonIconPath: document.getElementById("collapsed-site-current-button-icon-path"),
  websiteSettingsDropdown: document.getElementById("website-settings-dropdown"),
  websiteSettingsSummary: document.getElementById("website-settings-summary"),
  modeSelect: document.getElementById("mode-select"),
  modeSegment: document.getElementById("mode-segment"),
  urlList: document.getElementById("url-list"),
  urlListError: document.getElementById("url-list-error"),
  siteListEditor: document.getElementById("site-list-editor"),
  siteRowScroll: document.getElementById("site-row-scroll"),
  siteAddButton: document.getElementById("site-add-button"),
  siteCurrentButton: document.getElementById("site-current-button"),
  siteCurrentButtonLabel: document.getElementById("site-current-button-label"),
  siteImportButton: document.getElementById("site-import-button"),
  siteImportPanel: document.getElementById("site-import-panel"),
  siteImportInput: document.getElementById("site-import-input"),
  siteImportApply: document.getElementById("site-import-apply"),
  siteImportClose: document.getElementById("site-import-close"),
  siteAddForm: document.getElementById("site-add-form"),
  siteAddInput: document.getElementById("site-add-input"),
  siteAddConfirm: document.getElementById("site-add-confirm"),
  adultContentControl: document.getElementById("adult-content-control"),
  adultContentToggle: document.getElementById("adult-content-toggle"),
  adultContentStatus: document.getElementById("adult-content-status"),
  unlockModeSelect: document.getElementById("unlock-mode-select"),
  unlockModeSegment: document.getElementById("unlock-mode-segment"),
  unlockModeSettingsStack: document.getElementById("unlock-mode-settings-stack"),
  timerSettingsGroup: document.getElementById("timer-settings-group"),
  timerEndTimeInput: document.getElementById("timer-end-time"),
  timerEndTimeError: document.getElementById("timer-end-time-error"),
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

function sanitizeList(value, mode = "block") {
  if (!Array.isArray(value)) {
    return [];
  }

  const normalized = value
    .map((item) => normalizeUrlRule(item, mode))
    .filter((item) => typeof item === "string" && item.length > 0);

  return [...new Set(normalized)];
}

function resolveManagedAdultPolicyFlag(value) {
  if (!value || typeof value !== "object") {
    return false;
  }

  return MANAGED_POLICY_FORCE_ADULT_KEYS.some((key) => value[key] === true);
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

  if (field.getClientRects().length === 0) {
    field.style.height = "";
    return;
  }

  const currentValue = field.value;
  const selectionStart = field.selectionStart;
  const selectionEnd = field.selectionEnd;
  const selectionDirection = field.selectionDirection;
  field.style.height = "auto";
  const currentContentHeight = field.scrollHeight;
  field.value = DEFAULT_UNLOCK_PHRASE;
  field.style.height = "auto";
  const defaultPhraseHeight = field.scrollHeight;
  field.value = currentValue;
  if (document.activeElement === field) {
    field.setSelectionRange(selectionStart, selectionEnd, selectionDirection);
  }
  const targetHeight = Math.max(
    UNLOCK_PHRASE_SETTING_MIN_HEIGHT,
    Math.min(currentContentHeight, defaultPhraseHeight)
  );
  field.style.height = `${targetHeight}px`;
  field.style.overflowY = currentContentHeight > defaultPhraseHeight ? "auto" : "hidden";
}

function scheduleUnlockPhraseSettingResize() {
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(autoResizeUnlockPhraseSettingField);
  });
}

function measureUnlockModeSettingsHeight({ showTimer, openPhrase, phraseValue = null }) {
  const stack = elements.unlockModeSettingsStack;
  const timerGroup = elements.timerSettingsGroup;
  const phraseDropdown = elements.unlockPhraseSettingDropdown;
  const phraseField = elements.unlockPhraseSettingInput;
  if (!stack || !timerGroup || !phraseDropdown) {
    return 0;
  }

  const previousTimerGroupHidden = timerGroup.hidden;
  const previousPhraseOpen = phraseDropdown.open;
  const wasTimerMode = elements.body.classList.contains("is-unlock-mode-timer");
  const previousPhraseValue = phraseField?.value ?? "";
  const previousPhraseSelectionStart = phraseField?.selectionStart ?? null;
  const previousPhraseSelectionEnd = phraseField?.selectionEnd ?? null;
  const previousPhraseSelectionDirection = phraseField?.selectionDirection ?? "none";
  const previousMinHeight = stack.style.getPropertyValue("--unlock-mode-settings-min-height");

  isMeasuringUnlockModeSettingsHeight = true;
  stack.style.setProperty("--unlock-mode-settings-min-height", "0px");

  if (showTimer) {
    elements.body.classList.add("is-unlock-mode-timer");
  } else {
    elements.body.classList.remove("is-unlock-mode-timer");
  }

  timerGroup.hidden = !showTimer;
  phraseDropdown.open = openPhrase;

  if (phraseField && phraseValue !== null) {
    phraseField.value = phraseValue;
  }

  if (openPhrase && phraseField) {
    autoResizeUnlockPhraseSettingField();
  }

  const height = Math.ceil(stack.getBoundingClientRect().height);

  timerGroup.hidden = previousTimerGroupHidden;
  phraseDropdown.open = previousPhraseOpen;
  if (phraseField) {
    phraseField.value = previousPhraseValue;
    if (document.activeElement === phraseField && previousPhraseSelectionStart !== null && previousPhraseSelectionEnd !== null) {
      phraseField.setSelectionRange(
        previousPhraseSelectionStart,
        previousPhraseSelectionEnd,
        previousPhraseSelectionDirection
      );
    }
    autoResizeUnlockPhraseSettingField();
  }

  if (wasTimerMode) {
    elements.body.classList.add("is-unlock-mode-timer");
  } else {
    elements.body.classList.remove("is-unlock-mode-timer");
  }

  if (previousMinHeight) {
    stack.style.setProperty("--unlock-mode-settings-min-height", previousMinHeight);
  } else {
    stack.style.removeProperty("--unlock-mode-settings-min-height");
  }
  isMeasuringUnlockModeSettingsHeight = false;
  return height;
}

function syncUnlockModeSettingsMinHeight() {
  const stack = elements.unlockModeSettingsStack;
  if (!stack) {
    return;
  }

  const timerHeight = measureUnlockModeSettingsHeight({ showTimer: true, openPhrase: false });
  const defaultPhraseHeight = measureUnlockModeSettingsHeight({
    showTimer: false,
    openPhrase: true,
    phraseValue: DEFAULT_UNLOCK_PHRASE
  });
  const currentPhraseHeight = measureUnlockModeSettingsHeight({
    showTimer: false,
    openPhrase: true
  });
  const defaultHeight = Math.max(timerHeight, defaultPhraseHeight);
  const phraseHeightDelta = currentPhraseHeight - defaultPhraseHeight;
  const minHeight = Math.max(0, defaultHeight + phraseHeightDelta);
  stack.style.setProperty("--unlock-mode-settings-min-height", minHeight > 0 ? `${minHeight}px` : "0px");
}

function scheduleUnlockModeSettingsMinHeightSync() {
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(syncUnlockModeSettingsMinHeight);
  });
}

function reconcileUnlockPhraseSettingLayout() {
  if (
    !elements.settingsDropdown?.open ||
    elements.settingsDropdown.hidden ||
    elements.settingsDropdown.hasAttribute("inert") ||
    !elements.unlockPhraseSettingDropdown?.open
  ) {
    return;
  }

  scheduleUnlockPhraseSettingResize();
}

function getReferencePhraseForTyping() {
  return sanitizeUnlockPhrase(state.unlockPhrase);
}

function sanitizeTypedPhraseInput(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .replace(/^\s+/, "");
}

function getSanitizedCursorOffset(rawValue, rawSelectionStart) {
  const safeValue = String(rawValue || "");
  const safeSelection = Number.isInteger(rawSelectionStart) ? rawSelectionStart : safeValue.length;
  const clampedSelection = Math.max(0, Math.min(safeValue.length, safeSelection));
  const prefix = safeValue.slice(0, clampedSelection);
  return sanitizeTypedPhraseInput(prefix).length;
}

function getCaretWordLocation(typedInput, cursorOffset) {
  const safeInput = String(typedInput || "");
  const clampedOffset = Math.max(0, Math.min(safeInput.length, Number(cursorOffset) || 0));
  const prefix = safeInput.slice(0, clampedOffset);
  const splitPrefix = prefix.split(" ");
  return {
    wordIndex: Math.max(0, splitPrefix.length - 1),
    charIndex: splitPrefix[splitPrefix.length - 1]?.length || 0
  };
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
  const rawTypedInput = String(elements.unlockPhraseInput.value || "");
  const typedInput = sanitizeTypedPhraseInput(rawTypedInput);
  const cursorOffset = getSanitizedCursorOffset(rawTypedInput, elements.unlockPhraseInput.selectionStart);
  const caretLocation = getCaretWordLocation(typedInput, cursorOffset);
  const referenceWords = referencePhrase.split(" ");
  const inputWords = typedInput.length > 0 ? typedInput.split(" ") : [""];
  const totalWords = Math.max(referenceWords.length, inputWords.length);
  const caretWordIndex = caretLocation.wordIndex;
  const caretCharIndex = caretLocation.charIndex;
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
  updateProgressLine();
}

function setUnlockActionButtonState(button, { disabled, phraseLocked }) {
  button.disabled = disabled;
  button.classList.toggle("is-phrase-locked", disabled && phraseLocked === true);
}

function setUnlockConfirmButtonState({ disabled, phraseLocked }) {
  setUnlockActionButtonState(elements.unlockConfirmButton, { disabled, phraseLocked });
}

function setUnlockBreakButtonState({ visible, disabled, phraseLocked }) {
  elements.unlockBreakButton.hidden = !visible;
  elements.unlockActionRow.classList.toggle("has-secondary-action", visible);
  setUnlockActionButtonState(elements.unlockBreakButton, {
    disabled: !visible || disabled,
    phraseLocked: visible && phraseLocked
  });
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

function getTimerEndTimeWarning(timeOfDay = elements.timerEndTimeInput.value) {
  const normalized = String(timeOfDay || "").trim();
  if (!isValidTimeOfDayString(normalized)) {
    return "";
  }

  const minutesUntil = getMinutesUntilEndTime(normalized);
  if (minutesUntil > TIMER_END_TIME_WARNING_MINUTES) {
    return TIMER_END_TIME_WARNING_TEXT;
  }

  return "";
}

function setTimerEndTimeWarning(message = "") {
  const text = String(message || "").trim();
  const hasWarning = text.length > 0;

  elements.timerEndTimeInput.classList.toggle("is-warning", hasWarning);
  elements.timerEndTimeInput.classList.remove("is-invalid");
  elements.timerEndTimeInput.removeAttribute("aria-invalid");

  if (!elements.timerEndTimeError) {
    return;
  }

  elements.timerEndTimeError.textContent = text;
  elements.timerEndTimeError.hidden = !hasWarning;
}

function refreshTimerEndTimeWarning() {
  const shouldEvaluate =
    state.unlockMode === "timer" && state.timerSelectionMode === TIMER_SELECTION_MODE_MANUAL_END_TIME;
  if (!shouldEvaluate) {
    setTimerEndTimeWarning("");
    return;
  }

  setTimerEndTimeWarning(getTimerEndTimeWarning(elements.timerEndTimeInput.value));
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

function normalizeRulePathname(pathname) {
  const normalized = String(pathname || "/").replace(/\/+$/, "");
  return normalized.length > 0 ? normalized : "/";
}

function normalizeHostname(hostname) {
  return String(hostname || "").toLowerCase().replace(/\.+$/, "");
}

function normalizeBlocklistHostname(hostname) {
  const normalized = normalizeHostname(hostname);
  if (normalized.startsWith("www.") && normalized.length > 4) {
    return normalized.slice(4);
  }

  return normalized;
}

function normalizeUrlRule(rawValue, mode = "block") {
  const trimmed = String(rawValue || "").trim();
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
    const hostname =
      sanitizeMode(mode) === "allow"
        ? normalizeHostname(parsed.hostname)
        : normalizeBlocklistHostname(parsed.hostname);
    if (!isValidUrlHostname(hostname)) {
      return null;
    }

    const pathname = normalizeRulePathname(parsed.pathname);
    if (sanitizeMode(mode) !== "allow") {
      return pathname === "/" ? hostname : `${hostname}${pathname}`;
    }

    const search = parsed.search || "";
    return pathname === "/" && search.length === 0
      ? hostname
      : `${hostname}${pathname}${search}`;
  } catch {
    return null;
  }
}

function parseUrls(text, mode = state.mode) {
  return sanitizeList(splitUrlListLines(text), mode);
}

function formatUrls(list, mode = state.mode) {
  return sanitizeList(list, mode).join("\n");
}

function getCurrentTabButtonLabel(mode = state.mode) {
  return CURRENT_TAB_RULE_LABELS[sanitizeMode(mode)];
}

function getCollapsedCurrentTabButtonLabel(mode = state.mode) {
  return COLLAPSED_CURRENT_TAB_LABELS[sanitizeMode(mode)];
}

function currentTabRuleExistsInEditor(mode = state.mode) {
  const nextRule = getCurrentTabRuleForMode(mode);
  if (!nextRule) {
    return false;
  }

  return getTrimmedUrlEditorLines().some((line) => normalizeUrlRule(line, mode) === nextRule);
}

function isCollapsedCurrentTabSavedFeedbackActive() {
  return collapsedCurrentTabSavedFeedbackTimeoutId !== null;
}

function setCollapsedCurrentTabButtonSavedState(isSaved) {
  if (!elements.collapsedSiteCurrentButtonIconPath) {
    return;
  }

  elements.collapsedSiteCurrentButtonIconPath.setAttribute(
    "d",
    isSaved ? COLLAPSED_CURRENT_TAB_ICON_PATHS.saved : COLLAPSED_CURRENT_TAB_ICON_PATHS.add
  );
}

function clearCollapsedCurrentTabSavedFeedback() {
  if (collapsedCurrentTabSavedFeedbackTimeoutId !== null) {
    clearTimeout(collapsedCurrentTabSavedFeedbackTimeoutId);
    collapsedCurrentTabSavedFeedbackTimeoutId = null;
  }

  setCollapsedCurrentTabButtonSavedState(false);
}

function showCollapsedCurrentTabSavedFeedback() {
  clearCollapsedCurrentTabSavedFeedback();
  setCollapsedCurrentTabButtonSavedState(true);
  collapsedCurrentTabSavedFeedbackTimeoutId = window.setTimeout(() => {
    collapsedCurrentTabSavedFeedbackTimeoutId = null;
    setCollapsedCurrentTabButtonSavedState(false);
    updateCurrentTabButton();
  }, COLLAPSED_CURRENT_TAB_SAVED_FEEDBACK_MS);
  updateCurrentTabButton();
}

function updateCurrentTabButton() {
  if (!elements.siteCurrentButton && !elements.collapsedSiteCurrentButton) {
    return;
  }

  const label = getCurrentTabButtonLabel();
  const isDuplicate = currentTabRuleExistsInEditor();
  const isSavedFeedbackActive = isCollapsedCurrentTabSavedFeedbackActive();
  if (elements.siteCurrentButtonLabel) {
    elements.siteCurrentButtonLabel.textContent = label;
  }
  elements.siteCurrentButton.setAttribute("aria-label", label);
  elements.siteCurrentButton.disabled = !canAddCurrentTab || isDuplicate;
  elements.siteCurrentButton.title = !canAddCurrentTab
    ? "Only regular websites can be added"
    : isDuplicate
      ? state.mode === "allow"
        ? "This page is already added"
        : "This site is already added"
      : "";

  if (elements.collapsedSiteCurrentButtonLabel) {
    elements.collapsedSiteCurrentButtonLabel.textContent = getCollapsedCurrentTabButtonLabel();
  }
  if (elements.collapsedSiteCurrentButton) {
    const collapsedLabel = getCollapsedCurrentTabButtonLabel();
    elements.collapsedSiteCurrentButton.setAttribute(
      "aria-label",
      isSavedFeedbackActive
        ? state.mode === "allow"
          ? "added to allowlist"
          : "added to blocklist"
        : collapsedLabel
    );
    elements.collapsedSiteCurrentButton.disabled = !canAddCurrentTab || isSavedFeedbackActive || isDuplicate;
    elements.collapsedSiteCurrentButton.title = isSavedFeedbackActive ? "" : elements.siteCurrentButton?.title || "";
    elements.collapsedSiteCurrentButton.hidden =
      !isSavedFeedbackActive &&
      (
        !canAddCurrentTab ||
        isDuplicate ||
        state.isBlocking ||
        elements.settingsDropdown?.open === true ||
        elements.settingsDropdown?.hidden === true ||
        elements.settingsDropdown?.hasAttribute("inert") === true
      );
  }
}

function buildCurrentTabRule(url, mode = state.mode) {
  try {
    const parsed = new URL(String(url || "").trim());
    if (!CURRENT_TAB_SUPPORTED_PROTOCOLS.has(parsed.protocol)) {
      return null;
    }

    const candidate =
      sanitizeMode(mode) === "allow"
        ? `${parsed.hostname}${normalizeRulePathname(parsed.pathname)}${parsed.search || ""}`
        : parsed.hostname;

    return normalizeUrlRule(candidate, mode);
  } catch {
    return null;
  }
}

function getCurrentTabRuleForMode(mode = state.mode) {
  if (!canAddCurrentTab || !currentTabUrl) {
    return null;
  }

  return buildCurrentTabRule(currentTabUrl, mode);
}

async function refreshCurrentTabState() {
  clearCollapsedCurrentTabSavedFeedback();
  currentTabUrl = "";
  canAddCurrentTab = false;

  try {
    const tabs = await browser.tabs.query({ active: true, currentWindow: true });
    const activeTab = Array.isArray(tabs) ? tabs[0] : null;
    const nextUrl = String(activeTab?.url || "").trim();
    const nextRule = buildCurrentTabRule(nextUrl);
    currentTabUrl = nextUrl;
    canAddCurrentTab = typeof nextRule === "string" && nextRule.length > 0;
  } catch (error) {
    console.error("Failed to read current tab", error);
  }

  updateCurrentTabButton();
}

function getTrimmedUrlEditorLines() {
  if (!elements.siteRowScroll) {
    return splitUrlListLines(elements.urlList.value)
      .map((line) => String(line || "").trim())
      .filter((line) => line.length > 0);
  }

  return Array.from(elements.siteRowScroll.querySelectorAll(".site-row-input"))
    .map((input) => String(input.value || "").trim())
    .filter((line) => line.length > 0);
}

function syncUrlListFromSiteRows() {
  if (!elements.siteRowScroll) {
    return;
  }

  elements.urlList.value = getTrimmedUrlEditorLines().join("\n");
}

function createSiteRow(value) {
  const row = document.createElement("div");
  row.className = "site-row";

  const input = document.createElement("input");
  input.type = "text";
  input.inputMode = "url";
  input.autocomplete = "off";
  input.autocapitalize = "off";
  input.autocorrect = "off";
  input.spellcheck = false;
  input.className = "site-row-input";
  input.value = value;
  input.placeholder = "example.com";
  input.setAttribute("aria-label", "Site URL");

  const removeButton = document.createElement("button");
  removeButton.type = "button";
  removeButton.className = "site-remove-button";
  removeButton.textContent = "\u00d7";
  removeButton.setAttribute("aria-label", `Remove ${value || "site"}`);

  row.append(input, removeButton);
  return row;
}

function renderSiteRowsFromTextarea() {
  if (!elements.siteRowScroll) {
    return;
  }

  const lines = splitUrlListLines(elements.urlList.value)
    .map((line) => String(line || "").trim())
    .filter((line) => line.length > 0);
  const fragment = document.createDocumentFragment();

  for (const line of lines) {
    fragment.appendChild(createSiteRow(line));
  }

  elements.siteRowScroll.replaceChildren(fragment);
}

function focusSiteAddInput() {
  window.requestAnimationFrame(() => {
    elements.siteAddInput.focus();
  });
}

function focusSiteImportInput() {
  window.requestAnimationFrame(() => {
    elements.siteImportInput.focus();
  });
}

function setSiteImportInputInvalid(isInvalid) {
  elements.siteImportInput.classList.toggle("is-invalid", isInvalid);
}

function setSiteImportPopoverVisible(isVisible) {
  isSiteImportPopoverVisible = isVisible === true;
  elements.popupShell.classList.toggle("is-import-open", isSiteImportPopoverVisible);
  elements.popupRoot.classList.toggle("is-import-window-open", isSiteImportPopoverVisible);
  elements.siteImportPanel.hidden = !isSiteImportPopoverVisible;
  elements.siteImportButton.classList.toggle("is-active", isSiteImportPopoverVisible);
  elements.siteImportButton.setAttribute("aria-pressed", String(isSiteImportPopoverVisible));

  if (!isSiteImportPopoverVisible) {
    elements.siteImportInput.value = "";
    setSiteImportInputInvalid(false);
    return;
  }

  setSiteAddFormVisible(false);
  setSiteImportInputInvalid(false);
  focusSiteImportInput();
}

function countNonEmptyUrlLines(text) {
  return splitUrlListLines(text)
    .map((line) => String(line || "").trim())
    .filter((line) => line.length > 0)
    .length;
}

function importSiteListFromPanel() {
  const lineCount = countNonEmptyUrlLines(elements.siteImportInput.value);
  if (lineCount === 0) {
    setSiteImportInputInvalid(true);
    return;
  }

  const existingLines = sanitizeList(getTrimmedUrlEditorLines(), state.mode);
  const mergedLines = [...existingLines];
  const existingSet = new Set(existingLines);
  let addedCount = 0;
  let duplicateCount = 0;
  let invalidCount = 0;

  for (const rawLine of splitUrlListLines(elements.siteImportInput.value)) {
    const trimmedLine = String(rawLine || "").trim();
    if (trimmedLine.length === 0) {
      continue;
    }

    const normalizedLine = normalizeUrlRule(trimmedLine, state.mode);
    if (!normalizedLine) {
      invalidCount += 1;
      continue;
    }

    if (existingSet.has(normalizedLine)) {
      duplicateCount += 1;
      continue;
    }

    existingSet.add(normalizedLine);
    mergedLines.push(normalizedLine);
    addedCount += 1;
  }

  if (addedCount === 0 && duplicateCount === 0) {
    setSiteImportInputInvalid(true);
    return;
  }

  elements.urlList.value = mergedLines.join("\n");
  renderSiteRowsFromTextarea();
  scrollSiteRowsToLatest();
  handleUrlListInput();
  flushPendingUrlListSync();
  setSiteImportPopoverVisible(false);
}

function scrollSiteRowsToLatest() {
  window.requestAnimationFrame(() => {
    elements.siteRowScroll.scrollTop = elements.siteRowScroll.scrollHeight;
  });
}

function setSiteAddFormVisible(isVisible) {
  if (isVisible && isSiteImportPopoverVisible) {
    setSiteImportPopoverVisible(false);
  }

  isSiteAddFormVisible = isVisible;
  elements.siteAddButton.classList.toggle("is-active", isVisible);
  elements.siteAddButton.setAttribute("aria-pressed", String(isVisible));
  elements.siteAddForm.hidden = !isVisible;

  if (!isVisible) {
    elements.siteAddInput.value = "";
    return;
  }

  focusSiteAddInput();
}

function commitSiteAddInput() {
  const nextValue = String(elements.siteAddInput.value || "").trim();
  if (nextValue.length === 0) {
    setSiteAddFormVisible(false);
    return;
  }

  const existingLines = getTrimmedUrlEditorLines();
  existingLines.push(nextValue);
  elements.urlList.value = existingLines.join("\n");
  renderSiteRowsFromTextarea();
  scrollSiteRowsToLatest();
  handleUrlListInput();
  flushPendingUrlListSync();
  elements.siteAddInput.value = "";
  focusSiteAddInput();
}

async function commitCurrentTabRule(options = {}) {
  const { showCollapsedSavedFeedback = false } = options;
  const nextRule = getCurrentTabRuleForMode();
  if (!nextRule) {
    return;
  }

  const existingLines = getTrimmedUrlEditorLines();
  const hasDuplicate = existingLines.some((line) => normalizeUrlRule(line, state.mode) === nextRule);
  if (hasDuplicate) {
    return;
  }

  existingLines.push(nextRule);
  elements.urlList.value = existingLines.join("\n");
  renderSiteRowsFromTextarea();
  scrollSiteRowsToLatest();
  handleUrlListInput();
  await flushPendingUrlListSync({
    errorLabel: "Failed to save current tab rule",
    rethrow: true
  });
  if (showCollapsedSavedFeedback) {
    showCollapsedCurrentTabSavedFeedback();
  }
}


function updateSegmentedControl(segment, value) {
  if (!segment) {
    return;
  }

  const buttons = Array.from(segment.querySelectorAll(".segment-option"));
  let hasActiveButton = false;

  for (const button of buttons) {
    const isActive = button.dataset.value === value;
    button.classList.toggle("is-active", isActive);
    button.setAttribute("aria-checked", String(isActive));
    button.tabIndex = isActive ? 0 : -1;
    hasActiveButton = hasActiveButton || isActive;
  }

  if (!hasActiveButton && buttons[0]) {
    buttons[0].tabIndex = 0;
  }
}

function syncSegmentedControlsFromState() {
  updateSegmentedControl(elements.modeSegment, elements.modeSelect.value);
  updateSegmentedControl(elements.unlockModeSegment, elements.unlockModeSelect.value);
}

function selectModeFromSegment(value) {
  const nextMode = sanitizeMode(value);
  if (elements.modeSelect.value === nextMode) {
    return;
  }

  syncUrlListFromSiteRows();
  elements.modeSelect.value = nextMode;
  handleModeChange();
  syncSegmentedControlsFromState();
}

function selectUnlockModeFromSegment(value) {
  const nextMode = sanitizeUnlockMode(value);
  if (elements.unlockModeSelect.value === nextMode) {
    return;
  }

  elements.unlockModeSelect.value = nextMode;
  handleUnlockModeChange();
  syncSegmentedControlsFromState();
}

function getSegmentOptionButtons(segment) {
  if (!segment) {
    return [];
  }

  return Array.from(segment.querySelectorAll(".segment-option"));
}

function activateSegmentOption(button) {
  if (!button) {
    return;
  }

  if (button.closest("#mode-segment")) {
    selectModeFromSegment(button.dataset.value);
    return;
  }

  if (button.closest("#unlock-mode-segment")) {
    selectUnlockModeFromSegment(button.dataset.value);
  }
}

function handleSegmentOptionKeydown(event) {
  const button = event.target.closest(".segment-option");
  if (!button) {
    return;
  }

  const segment = button.closest(".segmented-control");
  const buttons = getSegmentOptionButtons(segment);
  const currentIndex = buttons.indexOf(button);
  if (currentIndex < 0) {
    return;
  }

  let targetIndex = currentIndex;
  if (event.key === "ArrowRight" || event.key === "ArrowDown") {
    targetIndex = (currentIndex + 1) % buttons.length;
  } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
    targetIndex = (currentIndex - 1 + buttons.length) % buttons.length;
  } else if (event.key === "Home") {
    targetIndex = 0;
  } else if (event.key === "End") {
    targetIndex = buttons.length - 1;
  } else if (event.key === " " || event.key === "Spacebar") {
    event.preventDefault();
    activateSegmentOption(button);
    return;
  } else {
    return;
  }

  event.preventDefault();
  const targetButton = buttons[targetIndex];
  targetButton?.focus();
  activateSegmentOption(targetButton);
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

    if (!normalizeUrlRule(rawLine, state.mode)) {
      return `Line ${lineIndex + 1}: invalid link`;
    }
  }

  return "";
}

function setUrlListValidationError(message = "") {
  const text = String(message || "").trim();
  const hasError = text.length > 0;

  elements.urlList.classList.toggle("is-invalid", hasError);
  elements.siteListEditor?.classList.toggle("is-invalid", hasError);
  if (hasError) {
    elements.urlList.setAttribute("aria-invalid", "true");
    elements.siteListEditor?.setAttribute("aria-invalid", "true");
  } else {
    elements.urlList.removeAttribute("aria-invalid");
    elements.siteListEditor?.removeAttribute("aria-invalid");
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
  const parsedUrls = parseUrls(safeDraft.text, mode);
  if (mode === "allow") {
    state.whiteList = parsedUrls;
    return mode;
  }

  state.blockList = parsedUrls;
  return mode;
}

function persistUrlListDraft(draft, errorLabel = "Failed to save URL list", options = {}) {
  const { rethrow = false } = options;
  const mode = applyUrlListDraftToState(draft);
  const payload = mode === "allow" ? { whiteList: state.whiteList } : { blockList: state.blockList };
  return browser.storage.local.set(payload).catch((error) => {
    console.error(errorLabel, error);
    if (rethrow) {
      throw error;
    }
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

function flushPendingUrlListSync(options = {}) {
  if (urlListSyncTimeoutId !== null) {
    clearTimeout(urlListSyncTimeoutId);
    urlListSyncTimeoutId = null;
  }

  const draft = pendingUrlListSyncDraft ?? buildUrlListSyncDraft();
  pendingUrlListSyncDraft = null;
  const persistPromise = persistUrlListDraft(
    draft,
    options.errorLabel || "Failed to save URL list",
    options
  );
  setUrlListValidationError("");
  scheduleUrlListValidation(draft.text);
  updatePowerToggleAvailability();
  return persistPromise;
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

function formatClockTime(timestamp) {
  if (!Number.isFinite(timestamp) || timestamp <= 0) {
    return "";
  }

  const date = new Date(timestamp);
  return formatTimeOfDay(date.getHours(), date.getMinutes());
}

function getTimerProgressPercent() {
  if (!state.isBlocking || state.unlockMode !== "timer") {
    return 0;
  }

  if (state.timerExpired) {
    return 100;
  }

  const totalMs = clampTimerMinutes(state.timerMinutes) * 60 * 1000;
  if (totalMs <= 0) {
    return 0;
  }

  const elapsedMs = totalMs - getRemainingMs();
  return Math.max(0, Math.min(100, (elapsedMs / totalMs) * 100));
}

function getPhraseProgressPercent() {
  if (!state.isBlocking || state.unlockMode !== "phrase") {
    return 0;
  }

  const expectedPhrase = normalizePhrase(state.unlockPhrase);
  if (expectedPhrase.length === 0) {
    return 0;
  }

  const typedPhrase = normalizePhrase(elements.unlockPhraseInput.value);
  return Math.max(0, Math.min(100, (typedPhrase.length / expectedPhrase.length) * 100));
}

function updateProgressLine() {
  if (!elements.progressLine) {
    return;
  }

  let progressPercent = 0;
  const pauseRemaining = getPauseRemainingMs();
  if (pauseRemaining > 0) {
    const pauseElapsed = PAUSE_POSITIVE_MS - pauseRemaining;
    progressPercent = Math.max(0, Math.min(100, (pauseElapsed / PAUSE_POSITIVE_MS) * 100));
  } else if (state.isBlocking && state.unlockMode === "timer") {
    progressPercent = getTimerProgressPercent();
  } else if (state.isBlocking && state.unlockMode === "phrase") {
    progressPercent = getPhraseProgressPercent();
  }

  elements.progressLine.style.width = `${progressPercent}%`;
}

function updateTimerDisplay() {
  if (!elements.unlockTimerPanel || !elements.unlockTimerCountdown || !elements.unlockTimerCaption) {
    return;
  }

  const shouldShowTimer = state.isBlocking && state.unlockMode === "timer";
  elements.unlockTimerPanel.hidden = !shouldShowTimer;
  if (!shouldShowTimer) {
    return;
  }

  const pauseRemaining = getPauseRemainingMs();
  if (pauseRemaining > 0) {
    elements.unlockTimerCountdown.textContent = formatDuration(pauseRemaining);
    elements.unlockTimerCaption.textContent = "pause remaining";
    return;
  }

  if (state.timerExpired) {
    elements.unlockTimerCountdown.textContent = "00:00";
    elements.unlockTimerCaption.textContent = "timer complete";
    return;
  }

  const remaining = getRemainingMs();
  const unlockTime = formatClockTime(state.lockEndTime);
  elements.unlockTimerCountdown.textContent = formatDuration(remaining);
  elements.unlockTimerCaption.textContent = unlockTime ? `unlocks at ${unlockTime}` : "locked";
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
  refreshTimerEndTimeWarning();
  reconcilePresetEndTimeTicker();
}

function updatePopupBottomPaddingState() {
  const isSettingsExpanded =
    Boolean(elements.settingsDropdown) &&
    !elements.settingsDropdown.hidden &&
    !elements.settingsDropdown.hasAttribute("inert") &&
    elements.settingsDropdown.open;
  const isPhraseSectionExpanded =
    isSettingsExpanded &&
    Boolean(elements.unlockPhraseSettingDropdown?.open);

  elements.popupRoot?.classList.toggle("is-settings-expanded", isSettingsExpanded);
  elements.popupRoot?.classList.toggle("is-phrase-settings-expanded", isPhraseSectionExpanded);
}

function setTimerModeSettingsAccordion(activeSection) {
  if (!elements.websiteSettingsDropdown || !elements.unlockPhraseSettingDropdown) {
    return;
  }

  isSyncingSettingsAccordion = true;
  elements.websiteSettingsDropdown.open = activeSection === "website";
  elements.unlockPhraseSettingDropdown.open = activeSection === "phrase";
  isSyncingSettingsAccordion = false;
  if (activeSection === "phrase") {
    scheduleUnlockPhraseSettingResize();
  } else {
    autoResizeUnlockPhraseSettingField();
  }
  updatePopupBottomPaddingState();
}

function syncSettingsAccordionForMode(preferredSection = null) {
  if (!elements.websiteSettingsDropdown || !elements.unlockPhraseSettingDropdown) {
    return;
  }

  if (state.unlockMode !== "timer") {
    isSyncingSettingsAccordion = true;
    elements.websiteSettingsDropdown.open = true;
    elements.unlockPhraseSettingDropdown.open = state.unlockMode === "phrase";
    isSyncingSettingsAccordion = false;
    updatePopupBottomPaddingState();
    reconcileUnlockPhraseSettingLayout();
    return;
  }

  const activeSection =
    preferredSection ||
    (elements.unlockPhraseSettingDropdown.open ? "phrase" : "website");
  setTimerModeSettingsAccordion(activeSection);
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
  elements.settingsDropdown.hidden = isBlocked;

  if (isBlocked) {
    elements.settingsDropdown.open = false;
    elements.settingsDropdown.setAttribute("inert", "");
    elements.settingsSummary.tabIndex = -1;
    if (document.activeElement === elements.settingsSummary) {
      elements.settingsSummary.blur();
    }
    updatePopupBottomPaddingState();
    return;
  }

  elements.settingsDropdown.removeAttribute("inert");
  elements.settingsSummary.removeAttribute("tabindex");
  updatePopupBottomPaddingState();
}

function updateTimerSettingsVisibility() {
  const showTimerSettings = state.unlockMode === "timer";
  elements.body.classList.toggle("is-unlock-mode-timer", showTimerSettings);
  elements.timerSettingsGroup.hidden = !showTimerSettings;
  elements.timerEndTimeInput.disabled = !showTimerSettings;
  refreshTimerEndTimeWarning();

  if (elements.unlockPhraseSettingSummary) {
    elements.unlockPhraseSettingSummary.textContent =
      state.unlockMode === "timer" ? "pause phrase" : "unlock phrase";
  }

  syncSettingsAccordionForMode("website");
  scheduleUnlockModeSettingsMinHeightSync();
  updatePopupBottomPaddingState();
}

function setPhraseControls({ visible, label, disabled }) {
  elements.unlockPhraseLabel.hidden = !visible;
  elements.unlockTypingSurface.hidden = !visible;
  elements.unlockPhraseDisplay.hidden = !visible;
  elements.unlockPhraseInput.hidden = !visible;
  elements.unlockPhraseCaret.hidden = !visible;
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
  const tryFocusUnlockControl = () => {
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
  };

  window.requestAnimationFrame(tryFocusUnlockControl);
  window.setTimeout(tryFocusUnlockControl, 50);
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

function syncAdultContentControlFromState() {
  if (!elements.adultContentControl || !elements.adultContentToggle) {
    return;
  }

  const isEnabled = state.adultContentBlockingEnabled === true;
  const isHidden = state.adultContentForcedByPolicy || state.isBlocking || !elements.settingsDropdown?.open;
  elements.adultContentControl.hidden = isHidden;
  elements.adultContentToggle.checked = isEnabled;
  elements.adultContentToggle.disabled = state.adultContentForcedByPolicy || state.isBlocking;

  if (elements.adultContentStatus) {
    elements.adultContentStatus.textContent = isEnabled
      ? "block nsfw sites enabled"
      : "block nsfw sites disabled";
  }
}

function syncFormFromState() {
  elements.modeSelect.value = state.mode;
  const formattedActiveList = formatUrls(state[getActiveListKey()], state.mode);
  const isEditingSiteRows = elements.siteListEditor?.contains(document.activeElement) === true;
  if (document.activeElement !== elements.urlList && !isEditingSiteRows) {
    elements.urlList.value = formattedActiveList;
    renderSiteRowsFromTextarea();
  }
  setUrlListValidationError(getUrlListValidationError(elements.urlList.value));
  syncAdultContentControlFromState();
  elements.unlockModeSelect.value = state.unlockMode;
  syncSegmentedControlsFromState();
  updateTimerSettingsVisibility();
  updateCurrentTabButton();
  elements.unlockPhraseSettingInput.value = sanitizeUnlockPhrase(state.unlockPhrase);
  autoResizeUnlockPhraseSettingField();
  syncTimerControlsFromState();
}

function applyFormToState() {
  syncUrlListFromSiteRows();
  state.mode = sanitizeMode(elements.modeSelect.value);
  state.adultContentBlockingEnabled = state.adultContentForcedByPolicy
    ? true
    : elements.adultContentToggle.checked === true;
  state.unlockMode = sanitizeUnlockMode(elements.unlockModeSelect.value);
  state.unlockPhrase = sanitizeUnlockPhrase(elements.unlockPhraseSettingInput.value);

  if (state.timerSelectionMode === TIMER_SELECTION_MODE_PRESET) {
    state.timerMinutes = minutesFromSelectedPreset();
  } else {
    state.manualEndTime = sanitizeTimerEndTime(elements.timerEndTimeInput.value);
    state.timerMinutes = clampTimerMinutes(getMinutesUntilEndTime(state.manualEndTime));
  }

  const parsedUrls = parseUrls(elements.urlList.value, state.mode);
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
    adultContentBlockingEnabled: state.adultContentBlockingEnabled,
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
  state.blockList = sanitizeList(stored.blockList, "block");
  state.whiteList = sanitizeList(stored.whiteList, "allow");
  state.adultContentBlockingEnabled =
    stored.adultContentBlockingEnabled === undefined
      ? true
      : stored.adultContentBlockingEnabled === true;
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

  if (state.adultContentForcedByPolicy) {
    state.adultContentBlockingEnabled = true;
  }
}

async function loadManagedPolicyFromStorage() {
  try {
    if (!browser?.storage?.managed?.get) {
      state.adultContentForcedByPolicy = false;
      return;
    }

    const managed = await browser.storage.managed.get(null);
    state.adultContentForcedByPolicy = resolveManagedAdultPolicyFlag(managed);
  } catch {
    state.adultContentForcedByPolicy = false;
  }

  if (state.adultContentForcedByPolicy) {
    state.adultContentBlockingEnabled = true;
  }
}

function updateLockedChallenge() {
  elements.body.classList.toggle("is-timer-mode", state.unlockMode === "timer");
  elements.body.classList.toggle("is-phrase-mode", state.unlockMode === "phrase");
  elements.body.classList.toggle("is-timer-complete", state.unlockMode === "timer" && state.timerExpired);
  elements.body.classList.toggle("is-paused", getPauseRemainingMs() > 0);
  updateTimerDisplay();
  updateProgressLine();
  renderPhraseTypingPreview();

  const isTimerMode = state.unlockMode === "timer";
  const phraseInput = normalizePhrase(elements.unlockPhraseInput.value);
  const expectedPhrase = normalizePhrase(state.unlockPhrase);
  const pauseRemaining = getPauseRemainingMs();

  if (pauseRemaining > 0) {
    setPhraseControls({ visible: false, label: "Unlock phrase", disabled: true });
    setUnlockBreakButtonState({ visible: false, disabled: true, phraseLocked: false });
    elements.unlockConfirmButton.hidden = false;
    setUnlockConfirmButtonState({ disabled: false, phraseLocked: false });
    elements.unlockConfirmButton.textContent = "Resume";
    return;
  }

  if (isTimerMode) {
    if (state.timerExpired) {
      setPhraseControls({ visible: false, label: "Unlock phrase", disabled: true });
      setUnlockBreakButtonState({ visible: false, disabled: true, phraseLocked: false });
      elements.unlockConfirmButton.hidden = true;
      return;
    }

    if (state.pausePositiveEnabled) {
      setPhraseControls({
        visible: true,
        label: "Type phrase to pause",
        disabled: false
      });
      const phraseMatches = phraseInput === expectedPhrase;
      setUnlockBreakButtonState({ visible: false, disabled: true, phraseLocked: false });
      elements.unlockConfirmButton.hidden = false;
      setUnlockConfirmButtonState({ disabled: !phraseMatches, phraseLocked: !phraseMatches });
      elements.unlockConfirmButton.textContent = "Pause 2 min";
      return;
    }

    setPhraseControls({ visible: false, label: "Unlock phrase", disabled: true });
    setUnlockBreakButtonState({ visible: false, disabled: true, phraseLocked: false });
    elements.unlockConfirmButton.hidden = false;
    setUnlockConfirmButtonState({ disabled: true, phraseLocked: false });
    elements.unlockConfirmButton.textContent = "Wait for timer";
    return;
  }

  setPhraseControls({ visible: true, label: "Type to unlock", disabled: false });
  const phraseMatches = phraseInput === expectedPhrase;
  setUnlockBreakButtonState({
    visible: true,
    disabled: !phraseMatches,
    phraseLocked: !phraseMatches
  });
  elements.unlockConfirmButton.hidden = false;
  setUnlockConfirmButtonState({ disabled: !phraseMatches, phraseLocked: !phraseMatches });
  elements.unlockConfirmButton.textContent = "Stop";
}

function stopTimerTick() {
  if (timerTickId !== null) {
    clearInterval(timerTickId);
    timerTickId = null;
  }
}

function startTimerTick() {
  stopTimerTick();
  if (!state.isBlocking) {
    return;
  }

  if (state.unlockMode !== "timer" && getPauseRemainingMs() <= 0) {
    return;
  }

  timerTickId = window.setInterval(() => {
    updateLockedChallenge();
    if (state.unlockMode !== "timer" && getPauseRemainingMs() <= 0) {
      stopTimerTick();
    }
  }, 1000);
}

function renderUi() {
  elements.body.classList.toggle("is-blocking", state.isBlocking);
  elements.powerToggle.checked = state.isBlocking;
  updatePowerToggleAvailability();
  syncAdultContentControlFromState();
  elements.powerToggleAssistiveText.textContent = state.isBlocking
    ? "Stop blocking"
    : "Start blocking";

  if (state.isBlocking) {
    isUnlockChallengeOpen = true;
    setSettingsBlocked(true);
    setChallengeVisibility(true);
    updateLockedChallenge();
    startTimerTick();
    focusUnlockControl();
    return;
  }

  stopTimerTick();
  setSettingsBlocked(false);
  elements.body.classList.remove("is-timer-mode", "is-phrase-mode", "is-timer-complete", "is-paused");
  updateProgressLine();
  isUnlockChallengeOpen = false;
  setChallengeVisibility(false);
  elements.unlockPhraseInput.value = "";
  setPhraseControls({ visible: true, label: "Unlock phrase", disabled: false });
  setUnlockBreakButtonState({ visible: false, disabled: true, phraseLocked: false });
  elements.unlockConfirmButton.hidden = false;
  setUnlockConfirmButtonState({ disabled: false, phraseLocked: false });
  elements.unlockConfirmButton.textContent = "Confirm";
}

function collectPayloadFromState() {
  return {
    mode: state.mode,
    blockList: state.blockList,
    whiteList: state.whiteList,
    adultContentBlockingEnabled: state.adultContentBlockingEnabled,
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
    renderUi();
    console.error("START_BLOCKING failed", error);
  }
}

async function stopBlocking() {
  try {
    const response = await browser.runtime.sendMessage({ type: "STOP_BLOCKING" });
    if (!response || response.ok !== true) {
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
    elements.powerToggle.checked = state.isBlocking;
    console.error("STOP_BLOCKING failed", error);
  }
}

async function requestPausePositive() {
  const phrase = normalizePhrase(elements.unlockPhraseInput.value);
  const expectedPhrase = normalizePhrase(state.unlockPhrase);
  if (phrase !== expectedPhrase) {
    return;
  }

  try {
    const response = await browser.runtime.sendMessage({
      type: "REQUEST_PAUSE_POSITIVE",
      payload: { phrase: elements.unlockPhraseInput.value }
    });

    if (!response || response.ok !== true) {
      return;
    }

    if (Number.isFinite(response.pauseUntil)) {
      state.pauseUntil = response.pauseUntil;
    }

    if (Number.isFinite(response.lockEndTime)) {
      state.lockEndTime = response.lockEndTime;
    }

    if (typeof response.timerExpired === "boolean") {
      state.timerExpired = response.timerExpired;
    }

    elements.unlockPhraseInput.value = "";
    renderUi();
  } catch (error) {
    console.error("REQUEST_PAUSE_POSITIVE failed", error);
  }
}

async function resumePausePositive() {
  try {
    const response = await browser.runtime.sendMessage({
      type: "RESUME_PAUSE_POSITIVE"
    });

    if (!response || response.ok !== true) {
      return;
    }

    state.pauseUntil = 0;
    if (Number.isFinite(response.lockEndTime)) {
      state.lockEndTime = response.lockEndTime;
    }

    if (typeof response.timerExpired === "boolean") {
      state.timerExpired = response.timerExpired;
    }

    await saveStateToStorage();
    renderUi();
  } catch (error) {
    console.error("RESUME_PAUSE_POSITIVE failed", error);
  }
}

async function handlePowerToggleChange() {
  if (!state.isBlocking && elements.powerToggle.checked) {
    const validationError = getUrlListValidationError(elements.urlList.value);
    if (validationError) {
      clearPendingUrlListValidation();
      setUrlListValidationError(validationError);
      elements.powerToggle.checked = false;
      elements.powerToggle.blur();
      return;
    }

    await startBlocking();
    elements.powerToggle.blur();
    return;
  }

  if (state.isBlocking && !elements.powerToggle.checked) {
    const expectedPhrase = normalizePhrase(state.unlockPhrase);
    const actualPhrase = normalizePhrase(elements.unlockPhraseInput.value);
    const canStopBlocking =
      (state.unlockMode === "timer" && state.timerExpired) ||
      (state.unlockMode === "phrase" && actualPhrase === expectedPhrase);

    if (canStopBlocking) {
      await stopBlocking();
      elements.powerToggle.blur();
      return;
    }

    elements.powerToggle.checked = true;
    openUnlockChallenge();
    elements.powerToggle.blur();
    return;
  }

  elements.powerToggle.checked = state.isBlocking;
  elements.powerToggle.blur();
}

async function handleUnlockConfirmClick() {
  if (!state.isBlocking) {
    return;
  }

  if (getPauseRemainingMs() > 0) {
    await resumePausePositive();
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
    return;
  }

  await stopBlocking();
}

async function handleUnlockBreakClick() {
  if (!state.isBlocking || state.unlockMode !== "phrase") {
    return;
  }

  await requestPausePositive();
}

function handleModeChange() {
  syncUrlListFromSiteRows();
  clearPendingUrlListSync();
  clearPendingUrlListValidation();
  setUrlListValidationError("");
  const previousMode = state.mode;
  state[getActiveListKey()] = parseUrls(elements.urlList.value, previousMode);
  state.mode = sanitizeMode(elements.modeSelect.value);
  elements.urlList.value = formatUrls(state[getActiveListKey()], state.mode);
  renderSiteRowsFromTextarea();
  setUrlListValidationError(getUrlListValidationError(elements.urlList.value));
  syncSegmentedControlsFromState();
  updateCurrentTabButton();
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
  if (elements.siteListEditor?.contains(document.activeElement) === true) {
    syncUrlListFromSiteRows();
  }
  updateCurrentTabButton();
  updatePowerToggleAvailability();
  scheduleUrlListSync();
}

function handleUrlListBlur() {
  if (elements.siteListEditor?.contains(document.activeElement) === true) {
    syncUrlListFromSiteRows();
  }
  flushPendingUrlListSync();
}

function handleSiteRowInput(event) {
  if (!event.target.closest(".site-row-input")) {
    return;
  }

  syncUrlListFromSiteRows();
  handleUrlListInput();
}

function handleSiteRowFocusOut(event) {
  if (!event.target.closest(".site-row-input")) {
    return;
  }

  syncUrlListFromSiteRows();
  flushPendingUrlListSync();
}

function handleSiteRowKeydown(event) {
  if (!event.target.closest(".site-row-input")) {
    return;
  }

  if (event.key === "Enter") {
    event.preventDefault();
    event.target.blur();
  }
}

function handleSiteRowClick(event) {
  const removeButton = event.target.closest(".site-remove-button");
  if (!removeButton) {
    return;
  }

  removeButton.closest(".site-row")?.remove();
  syncUrlListFromSiteRows();
  if (getTrimmedUrlEditorLines().length === 0) {
    renderSiteRowsFromTextarea();
  }
  handleUrlListInput();
  flushPendingUrlListSync();
}

function handleSiteAddKeydown(event) {
  if (event.key === "Enter") {
    event.preventDefault();
    commitSiteAddInput();
    return;
  }

  if (event.key === "Escape") {
    event.preventDefault();
    setSiteAddFormVisible(false);
  }
}

function handleSiteAddFormFocusOut(event) {
  if (!isSiteAddFormVisible) {
    return;
  }

  if (event.relatedTarget === elements.siteAddButton) {
    return;
  }

  if (elements.siteAddForm.contains(event.relatedTarget)) {
    return;
  }

  setSiteAddFormVisible(false);
}

function handleSiteImportButtonClick() {
  setSiteImportPopoverVisible(!isSiteImportPopoverVisible);
}

function handleSiteAddButtonClick() {
  setSiteAddFormVisible(!isSiteAddFormVisible);
}

function handleSiteCurrentButtonClick() {
  void commitCurrentTabRule().catch((error) => {
    console.error("Failed to save current tab rule", error);
  });
}

function handleCollapsedSiteCurrentButtonClick(event) {
  event.preventDefault();
  event.stopPropagation();
  if (event.currentTarget.disabled) {
    return;
  }

  void commitCurrentTabRule({ showCollapsedSavedFeedback: true }).catch((error) => {
    console.error("Failed to save current tab rule", error);
  });
}

function handleSiteImportInputKeydown(event) {
  if (event.key === "Escape") {
    event.preventDefault();
    setSiteImportPopoverVisible(false);
    return;
  }

  if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
    event.preventDefault();
    importSiteListFromPanel();
  }
}

function handleModeSegmentClick(event) {
  const button = event.target.closest(".segment-option");
  if (!button) {
    return;
  }

  selectModeFromSegment(button.dataset.value);
}

function handleUnlockModeSegmentClick(event) {
  const button = event.target.closest(".segment-option");
  if (!button) {
    return;
  }

  selectUnlockModeFromSegment(button.dataset.value);
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

function openPresetEditor(index) {
  const presetIndex = sanitizeSelectedPresetIndex(index);
  if (presetIndex === null) {
    return false;
  }

  const presetButton = elements.timerPresetButtons[presetIndex];
  if (!presetButton || presetButton.hidden || presetButton.disabled) {
    return false;
  }

  beginPresetEditing(presetIndex, presetButton);
  return true;
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
    setTimerEndTimeWarning("");
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
  syncSegmentedControlsFromState();
  updateTimerSettingsVisibility();
  if (state.isBlocking) {
    updateLockedChallenge();
    startTimerTick();
  }

  void saveStateToStorage().catch((error) => {
    console.error("Failed to save unlock mode", error);
  });
}

function handleAdultContentToggleChange() {
  if (state.adultContentForcedByPolicy) {
    state.adultContentBlockingEnabled = true;
    syncFormFromState();
    elements.adultContentToggle.blur();
    return;
  }

  state.adultContentBlockingEnabled = elements.adultContentToggle.checked === true;
  syncAdultContentControlFromState();
  elements.adultContentToggle.blur();
  void browser.storage.local
    .set({ adultContentBlockingEnabled: state.adultContentBlockingEnabled })
    .catch((error) => {
      console.error("Failed to save adult content blocking setting", error);
    });
}

function handleUnlockPhraseSettingInput() {
  const sanitized = sanitizeUnlockPhrase(elements.unlockPhraseSettingInput.value);
  if (elements.unlockPhraseSettingInput.value !== sanitized) {
    elements.unlockPhraseSettingInput.value = sanitized;
  }

  autoResizeUnlockPhraseSettingField();
  scheduleUnlockModeSettingsMinHeightSync();
  state.unlockPhrase = sanitized;
  renderPhraseTypingPreview();
  void saveStateToStorage().catch((error) => {
    console.error("Failed to save unlock phrase", error);
  });
}

function handleUnlockPhraseSettingTyping() {
  autoResizeUnlockPhraseSettingField();
  scheduleUnlockModeSettingsMinHeightSync();
}

function handleUnlockPhraseSettingKeydown(event) {
  if (event.key !== "Enter" || event.isComposing) {
    return;
  }

  event.preventDefault();
  handleUnlockPhraseSettingInput();
  skipNextUnlockPhraseSettingBlurSave = true;
  elements.unlockPhraseSettingInput.blur();
}

function handleUnlockPhraseSettingBlur() {
  if (skipNextUnlockPhraseSettingBlurSave) {
    skipNextUnlockPhraseSettingBlurSave = false;
    return;
  }

  handleUnlockPhraseSettingInput();
}

function handleUnlockPhraseSettingDropdownToggle() {
  if (isMeasuringUnlockModeSettingsHeight) {
    return;
  }

  if (!elements.unlockPhraseSettingDropdown?.open) {
    autoResizeUnlockPhraseSettingField();
    if (state.unlockMode === "timer" && !isSyncingSettingsAccordion) {
      setTimerModeSettingsAccordion("website");
      return;
    }
    scheduleUnlockModeSettingsMinHeightSync();
    updatePopupBottomPaddingState();
    return;
  }

  if (state.unlockMode === "timer" && !isSyncingSettingsAccordion) {
    setTimerModeSettingsAccordion("phrase");
  }
  scheduleUnlockPhraseSettingResize();
  scheduleUnlockModeSettingsMinHeightSync();
  updatePopupBottomPaddingState();
}

function handleSettingsDropdownToggle() {
  if (elements.settingsDropdown?.open) {
    syncSettingsAccordionForMode();
    reconcileUnlockPhraseSettingLayout();
  }
  updateCurrentTabButton();
  syncAdultContentControlFromState();
  scheduleUnlockModeSettingsMinHeightSync();
  updatePopupBottomPaddingState();
}

function handleWebsiteSettingsDropdownToggle() {
  if (state.unlockMode !== "timer" || isSyncingSettingsAccordion) {
    return;
  }

  if (elements.websiteSettingsDropdown?.open) {
    setTimerModeSettingsAccordion("website");
    return;
  }

  setTimerModeSettingsAccordion("phrase");
}

function isEditableTarget(target) {
  if (!(target instanceof HTMLElement)) {
    return false;
  }

  if (target.isContentEditable || target.tagName === "TEXTAREA" || target.tagName === "SELECT") {
    return true;
  }

  if (target.tagName !== "INPUT") {
    return false;
  }

  const input = /** @type {HTMLInputElement} */ (target);
  const nonTextInputTypes = new Set([
    "button",
    "checkbox",
    "color",
    "file",
    "hidden",
    "image",
    "radio",
    "range",
    "reset",
    "submit"
  ]);

  return !nonTextInputTypes.has((input.type || "").toLowerCase());
}

function isSettingsShortcutKey(event) {
  return event.key === "s" || event.key === "S" || event.key === "ы" || event.key === "Ы";
}

function getTimerPresetShortcutIndex(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) {
    return null;
  }

  if (!["1", "2", "3", "4"].includes(event.key)) {
    return null;
  }

  return Number(event.key) - 1;
}

function handleGlobalKeydown(event) {
  if (!elements.settingsDropdown || elements.settingsDropdown.hidden || elements.settingsDropdown.hasAttribute("inert")) {
    return;
  }

  if (isEditableTarget(event.target) || isEditableTarget(document.activeElement)) {
    return;
  }

  const presetShortcutIndex = getTimerPresetShortcutIndex(event);
  if (
    presetShortcutIndex !== null &&
    elements.settingsDropdown.open &&
    !elements.timerSettingsGroup.hidden &&
    state.unlockMode === "timer" &&
    !presetEditState &&
    !event.repeat
  ) {
    event.preventDefault();
    const now = Date.now();
    const isDoublePress =
      lastPresetShortcut.index === presetShortcutIndex &&
      now - lastPresetShortcut.timestamp <= TIMER_PRESET_SHORTCUT_DOUBLE_PRESS_MS;

    lastPresetShortcut = { index: presetShortcutIndex, timestamp: now };
    if (isDoublePress) {
      lastPresetShortcut = { index: null, timestamp: 0 };
      openPresetEditor(presetShortcutIndex);
      return;
    }

    selectTimerPreset(presetShortcutIndex);
    return;
  }

  if (!isSettingsShortcutKey(event) || event.metaKey || event.ctrlKey || event.altKey) {
    return;
  }

  event.preventDefault();
  elements.settingsDropdown.open = !elements.settingsDropdown.open;
  if (!elements.settingsDropdown.open && document.activeElement === elements.settingsSummary) {
    elements.settingsSummary.blur();
  }
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
  renderPhraseTypingPreview();
}

function handlePhraseInputBlur() {
  elements.unlockPhraseDisplay.classList.remove("is-focus-visible");
  elements.unlockPhraseCaret.hidden = true;
}

function handlePhraseCursorMove() {
  renderPhraseTypingPreview();
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

function handleUnlockPhrasePaste(event) {
  event.preventDefault();
}

function handleUnlockPhraseBeforeInput(event) {
  if (event.inputType === "insertFromPaste" || event.inputType === "insertFromDrop") {
    event.preventDefault();
  }
}

function refreshFromStorage() {
  void Promise.all([loadStateFromStorage(), loadManagedPolicyFromStorage()])
    .then(() => {
      syncFormFromState();
      renderUi();
    })
    .catch((error) => {
      console.error("Failed to refresh popup state", error);
    });
}

function handleStorageChanged(changes, areaName) {
  if (areaName === "managed") {
    if (MANAGED_POLICY_FORCE_ADULT_KEYS.some((key) => key in changes)) {
      refreshFromStorage();
    }
    return;
  }

  if (areaName === "local") {
    for (const key of STORAGE_KEYS) {
      if (key in changes) {
        refreshFromStorage();
        return;
      }
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
  await loadManagedPolicyFromStorage();
  await refreshCurrentTabState();
  syncFormFromState();
  renderUi();

  elements.powerToggle.addEventListener("change", () => {
    void handlePowerToggleChange();
  });
  elements.unlockConfirmButton.addEventListener("click", () => {
    void handleUnlockConfirmClick();
  });
  elements.unlockBreakButton.addEventListener("click", () => {
    void handleUnlockBreakClick();
  });
  elements.modeSelect.addEventListener("change", handleModeChange);
  elements.modeSegment?.addEventListener("click", handleModeSegmentClick);
  elements.modeSegment?.addEventListener("keydown", handleSegmentOptionKeydown);
  elements.urlList.addEventListener("input", handleUrlListInput);
  elements.urlList.addEventListener("blur", handleUrlListBlur);
  elements.urlList.addEventListener("change", handleUrlListBlur);
  elements.siteRowScroll?.addEventListener("input", handleSiteRowInput);
  elements.siteRowScroll?.addEventListener("focusout", handleSiteRowFocusOut);
  elements.siteRowScroll?.addEventListener("keydown", handleSiteRowKeydown);
  elements.siteRowScroll?.addEventListener("click", handleSiteRowClick);
  elements.siteAddButton?.addEventListener("click", handleSiteAddButtonClick);
  elements.siteCurrentButton?.addEventListener("click", handleSiteCurrentButtonClick);
  elements.collapsedSiteCurrentButton?.addEventListener("click", handleCollapsedSiteCurrentButtonClick);
  elements.siteAddForm?.addEventListener("focusout", handleSiteAddFormFocusOut);
  elements.siteImportButton?.addEventListener("click", handleSiteImportButtonClick);
  elements.siteImportApply?.addEventListener("click", importSiteListFromPanel);
  elements.siteImportClose?.addEventListener("click", () => {
    setSiteImportPopoverVisible(false);
  });
  elements.siteImportInput?.addEventListener("keydown", handleSiteImportInputKeydown);
  elements.siteImportInput?.addEventListener("input", () => {
    setSiteImportInputInvalid(false);
  });
  elements.siteAddForm?.addEventListener("focusout", handleSiteAddFormFocusOut);
  elements.siteAddConfirm?.addEventListener("click", commitSiteAddInput);
  elements.siteAddInput?.addEventListener("keydown", handleSiteAddKeydown);
  elements.adultContentToggle.addEventListener("change", handleAdultContentToggleChange);
  elements.unlockModeSelect.addEventListener("change", handleUnlockModeChange);
  elements.unlockModeSegment?.addEventListener("click", handleUnlockModeSegmentClick);
  elements.unlockModeSegment?.addEventListener("keydown", handleSegmentOptionKeydown);
  elements.unlockPhraseSettingInput.addEventListener("input", handleUnlockPhraseSettingTyping);
  elements.unlockPhraseSettingInput.addEventListener("keydown", handleUnlockPhraseSettingKeydown);
  elements.unlockPhraseSettingInput.addEventListener("change", handleUnlockPhraseSettingInput);
  elements.unlockPhraseSettingInput.addEventListener("blur", handleUnlockPhraseSettingBlur);
  elements.settingsDropdown?.addEventListener("toggle", handleSettingsDropdownToggle);
  elements.websiteSettingsDropdown?.addEventListener("toggle", handleWebsiteSettingsDropdownToggle);
  elements.unlockPhraseSettingDropdown?.addEventListener("toggle", handleUnlockPhraseSettingDropdownToggle);
  elements.timerEndTimeInput.addEventListener("input", handleTimerEndTimeInput);
  elements.timerEndTimeInput.addEventListener("change", handleTimerEndTimeChange);
  elements.timerPresets.addEventListener("click", handleTimerPresetClick);
  elements.timerPresets.addEventListener("dblclick", handleTimerPresetDoubleClick);
  elements.unlockPhraseInput.addEventListener("input", handlePhraseInput);
  elements.unlockPhraseInput.addEventListener("keydown", handleUnlockPhraseKeydown);
  elements.unlockPhraseInput.addEventListener("paste", handleUnlockPhrasePaste);
  elements.unlockPhraseInput.addEventListener("beforeinput", handleUnlockPhraseBeforeInput);
  elements.unlockPhraseInput.addEventListener("drop", handleUnlockPhrasePaste);
  elements.unlockPhraseInput.addEventListener("focus", handlePhraseInputFocus);
  elements.unlockPhraseInput.addEventListener("blur", handlePhraseInputBlur);
  elements.unlockPhraseInput.addEventListener("keyup", handlePhraseCursorMove);
  elements.unlockPhraseInput.addEventListener("click", handlePhraseCursorMove);
  elements.unlockPhraseInput.addEventListener("select", handlePhraseCursorMove);
  window.addEventListener("keydown", handleGlobalKeydown);
  window.addEventListener("resize", renderPhraseTypingPreview);
  window.addEventListener("beforeunload", () => {
    syncUrlListFromSiteRows();
    flushPendingUrlListSync();
    clearPendingUrlListValidation();
    clearCollapsedCurrentTabSavedFeedback();
    stopPresetEndTimeTicker();
    if (presetEditState) {
      stopPresetEditing(true);
    }
  });

  browser.storage.onChanged.addListener(handleStorageChanged);
  browser.runtime.onMessage.addListener(handleRuntimeMessage);
  updatePopupBottomPaddingState();
}

void initializePopup().catch((error) => {
  console.error("Popup initialization failed", error);
});
