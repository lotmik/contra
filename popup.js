"use strict";

const DEFAULT_UNLOCK_PHRASE = "I swear to god I will focus";
const DEFAULT_HARDCORE_MODE_STATUS = {
  active: false,
  reason: "not_checked",
  installType: "unknown",
  checkedAt: 0
};
const STORAGE_KEYS = [
  "isBlocking",
  "mode",
  "blockList",
  "whiteList",
  "unlockMode",
  "timerMinutes",
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
  timerMinutes: 25,
  unlockPhrase: DEFAULT_UNLOCK_PHRASE,
  lockEndTime: 0,
  timerExpired: true,
  pausePositiveEnabled: true,
  pauseUntil: 0,
  testDisableUntil: 0,
  hardcoreModeStatus: { ...DEFAULT_HARDCORE_MODE_STATUS }
};

let timerTickId = null;

const elements = {
  body: document.body,
  statusArea: document.getElementById("status-area"),
  hardcoreModeBadge: document.getElementById("hardcore-mode-badge"),
  installTypeDetail: document.getElementById("install-type-detail"),
  powerToggle: document.getElementById("power-toggle"),
  powerToggleAssistiveText: document.querySelector("#power-toggle-label .sr-only"),
  unlockChallenge: document.getElementById("unlock-challenge"),
  unlockPhraseLabel: document.querySelector('label[for="unlock-phrase-input"]'),
  unlockPhraseInput: document.getElementById("unlock-phrase-input"),
  unlockConfirmButton: document.getElementById("unlock-confirm-btn"),
  testDisableButton: document.getElementById("test-disable-btn"),
  settingsBlurWrap: document.getElementById("settings-blur-wrap"),
  settingsArea: document.getElementById("settings-area"),
  modeSelect: document.getElementById("mode-select"),
  urlList: document.getElementById("url-list"),
  unlockModeSelect: document.getElementById("unlock-mode-select"),
  timerMinutesInput: document.getElementById("timer-minutes"),
  timerMinutesValue: document.getElementById("timer-minutes-value")
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
    return 25;
  }

  return Math.min(180, Math.max(1, Math.round(value)));
}

function normalizePhrase(value) {
  return String(value || "")
    .trim()
    .replace(/\s+/g, " ")
    .toLowerCase();
}

function parseUrls(text) {
  return sanitizeList(String(text || "").split(/\r?\n/));
}

function formatUrls(list) {
  return sanitizeList(list).join("\n");
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

function getTestDisableRemainingMs() {
  return Math.max(0, (state.testDisableUntil || 0) - Date.now());
}

function updateTimerLabel(minutes) {
  elements.timerMinutesValue.textContent = `${minutes} min`;
}

function updateStatus(text) {
  elements.statusArea.textContent = text;
}

function normalizeHardcoreModeStatus(status = {}) {
  const installType = typeof status.installType === "string" ? status.installType : "unknown";
  return {
    active: status.active === true,
    reason: typeof status.reason === "string" ? status.reason : "unknown",
    installType,
    checkedAt: Number.isFinite(status.checkedAt) ? status.checkedAt : 0
  };
}

function getInstallTypeLabel(installType) {
  if (typeof installType !== "string" || installType.trim().length === 0) {
    return "unknown";
  }

  return installType;
}

function renderHardcoreModeStatus() {
  const isActive = state.hardcoreModeStatus.active;
  const installTypeLabel = getInstallTypeLabel(state.hardcoreModeStatus.installType);
  const classList = elements.hardcoreModeBadge.classList;
  classList.remove("is-active", "is-inactive");

  if (isActive) {
    classList.add("is-active");
    elements.hardcoreModeBadge.textContent = "Hardcore mode: on";
  } else {
    classList.add("is-inactive");
    elements.hardcoreModeBadge.textContent = "Hardcore mode: off";
  }

  elements.installTypeDetail.textContent = `Installation type detected: ${installTypeLabel}`;
}

function updateTestDisableButton() {
  const remaining = getTestDisableRemainingMs();
  if (remaining > 0) {
    elements.testDisableButton.textContent = `Testing disabled ${formatDuration(remaining)}`;
    return;
  }

  elements.testDisableButton.textContent = "Temporary Disable (60s)";
}

function setChallengeVisibility(isVisible) {
  elements.body.classList.toggle("is-unlock-pending", isVisible);
  elements.unlockChallenge.setAttribute("aria-hidden", String(!isVisible));
}

function setSettingsBlur(isBlurred) {
  elements.settingsBlurWrap.classList.toggle("settings-blurred", isBlurred);
  elements.settingsArea.classList.toggle("settings-blurred", isBlurred);
}

function setPhraseControls({ visible, label, disabled }) {
  elements.unlockPhraseLabel.hidden = !visible;
  elements.unlockPhraseInput.hidden = !visible;
  elements.unlockPhraseInput.disabled = disabled;
  if (label) {
    elements.unlockPhraseLabel.textContent = label;
  }
}

function syncFormFromState() {
  elements.modeSelect.value = state.mode;
  elements.urlList.value = formatUrls(state[getActiveListKey()]);
  elements.unlockModeSelect.value = state.unlockMode;
  elements.timerMinutesInput.value = String(state.timerMinutes);
  updateTimerLabel(state.timerMinutes);
}

function applyFormToState() {
  state.mode = sanitizeMode(elements.modeSelect.value);
  state.unlockMode = sanitizeUnlockMode(elements.unlockModeSelect.value);
  state.timerMinutes = clampTimerMinutes(Number(elements.timerMinutesInput.value));

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
  state.timerMinutes = clampTimerMinutes(Number(stored.timerMinutes));
  state.unlockPhrase =
    typeof stored.unlockPhrase === "string" && stored.unlockPhrase.trim().length > 0
      ? stored.unlockPhrase.trim()
      : DEFAULT_UNLOCK_PHRASE;
  state.lockEndTime = Number.isFinite(stored.lockEndTime) ? stored.lockEndTime : 0;
  state.timerExpired = typeof stored.timerExpired === "boolean" ? stored.timerExpired : true;
  state.pausePositiveEnabled =
    typeof stored.pausePositiveEnabled === "boolean" ? stored.pausePositiveEnabled : true;
  state.pauseUntil = Number.isFinite(stored.pauseUntil) ? stored.pauseUntil : 0;
  state.testDisableUntil = Number.isFinite(stored.testDisableUntil) ? stored.testDisableUntil : 0;
}

function updateLockedChallenge() {
  updateTestDisableButton();

  const isTimerMode = state.unlockMode === "timer";
  const phraseInput = normalizePhrase(elements.unlockPhraseInput.value);
  const expectedPhrase = normalizePhrase(state.unlockPhrase);

  if (isTimerMode) {
    const pauseRemaining = getPauseRemainingMs();
    if (pauseRemaining > 0) {
      setPhraseControls({ visible: false, label: "Unlock phrase", disabled: true });
      elements.unlockConfirmButton.disabled = true;
      elements.unlockConfirmButton.textContent = "Paused";
      updateStatus(`Pause active: ${formatDuration(pauseRemaining)}`);
      return;
    }

    if (state.timerExpired) {
      setPhraseControls({ visible: false, label: "Unlock phrase", disabled: true });
      elements.unlockConfirmButton.disabled = false;
      elements.unlockConfirmButton.textContent = "Stop";
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
      elements.unlockConfirmButton.disabled = phraseInput !== expectedPhrase;
      elements.unlockConfirmButton.textContent = "Pause 2 min";
      return;
    }

    setPhraseControls({ visible: false, label: "Unlock phrase", disabled: true });
    elements.unlockConfirmButton.disabled = true;
    elements.unlockConfirmButton.textContent = "Wait for timer";
    return;
  }

  setPhraseControls({ visible: true, label: "Unlock phrase", disabled: false });
  elements.unlockConfirmButton.disabled = phraseInput !== expectedPhrase;
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
  renderHardcoreModeStatus();
  elements.powerToggle.checked = state.isBlocking;
  elements.powerToggleAssistiveText.textContent = state.isBlocking
    ? "Stop blocking"
    : "Start blocking";
  updateTestDisableButton();

  if (state.isBlocking) {
    setSettingsBlur(true);
    setChallengeVisibility(true);
    updateLockedChallenge();
    startTimerTick();
    return;
  }

  stopTimerTick();
  setSettingsBlur(false);
  setChallengeVisibility(false);
  elements.unlockPhraseInput.value = "";
  setPhraseControls({ visible: true, label: "Unlock phrase", disabled: false });
  elements.unlockConfirmButton.disabled = false;
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

async function handleTestDisableClick() {
  try {
    const response = await browser.runtime.sendMessage({
      type: "TEMP_DISABLE_FOR_TEST",
      payload: { durationSeconds: 60 }
    });

    if (!response || response.ok !== true) {
      updateStatus("Could not enable test bypass");
      return;
    }

    if (Number.isFinite(response.testDisableUntil)) {
      state.testDisableUntil = response.testDisableUntil;
      await saveStateToStorage();
    }

    updateStatus("Test bypass active (60s)");
    renderUi();
  } catch (error) {
    updateStatus("Could not enable test bypass");
    console.error("TEMP_DISABLE_FOR_TEST failed", error);
  }
}

async function handlePowerToggleChange() {
  if (!state.isBlocking && elements.powerToggle.checked) {
    await startBlocking();
    return;
  }

  if (state.isBlocking && !elements.powerToggle.checked) {
    elements.powerToggle.checked = true;
    setChallengeVisibility(true);
    updateLockedChallenge();
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
  state.mode = sanitizeMode(elements.modeSelect.value);
  elements.urlList.value = formatUrls(state[getActiveListKey()]);
}

function handleTimerInput() {
  state.timerMinutes = clampTimerMinutes(Number(elements.timerMinutesInput.value));
  updateTimerLabel(state.timerMinutes);
}

function handleUnlockModeChange() {
  state.unlockMode = sanitizeUnlockMode(elements.unlockModeSelect.value);
  if (state.isBlocking) {
    updateLockedChallenge();
    startTimerTick();
  }
}

function handlePhraseInput() {
  if (state.isBlocking) {
    updateLockedChallenge();
  }
}

async function refreshHardcoreModeStatus(forceRefresh = false) {
  try {
    const response = await browser.runtime.sendMessage({
      type: forceRefresh ? "REFRESH_MANAGED_LOCK_STATUS" : "GET_MANAGED_LOCK_STATUS"
    });

    if (response?.ok === true && response.status) {
      state.hardcoreModeStatus = normalizeHardcoreModeStatus(response.status);
      renderHardcoreModeStatus();
    }
  } catch (error) {
    state.hardcoreModeStatus = {
      active: false,
      reason: "check_failed",
      installType: "unknown",
      checkedAt: Date.now()
    };
    renderHardcoreModeStatus();
    console.error("Failed to refresh hardcore mode status", error);
  }
}

function refreshFromStorage() {
  void loadStateFromStorage()
    .then(() => {
      syncFormFromState();
      renderUi();
      return refreshHardcoreModeStatus(false);
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
  if (message.type === "MANAGED_LOCK_STATUS_UPDATED" && message.status) {
    state.hardcoreModeStatus = normalizeHardcoreModeStatus(message.status);
    renderHardcoreModeStatus();
    return;
  }

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
  await refreshHardcoreModeStatus(true);

  elements.powerToggle.addEventListener("change", () => {
    void handlePowerToggleChange();
  });
  elements.unlockConfirmButton.addEventListener("click", () => {
    void handleUnlockConfirmClick();
  });
  elements.testDisableButton.addEventListener("click", () => {
    void handleTestDisableClick();
  });
  elements.modeSelect.addEventListener("change", handleModeChange);
  elements.unlockModeSelect.addEventListener("change", handleUnlockModeChange);
  elements.timerMinutesInput.addEventListener("input", handleTimerInput);
  elements.unlockPhraseInput.addEventListener("input", handlePhraseInput);

  browser.storage.onChanged.addListener(handleStorageChanged);
  browser.runtime.onMessage.addListener(handleRuntimeMessage);
}

void initializePopup().catch((error) => {
  updateStatus("Initialization failed");
  console.error("Popup initialization failed", error);
});
