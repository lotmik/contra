let isBlocking = false;
let blockList = [];
let whiteList = [];
let mode = "block";
let unlockMode = "timer";
let timerMinutes = 25;
let unlockPhrase = "I swear to god I will focus";
let lockEndTime = 0;
let timerExpired = true;
let pausePositiveEnabled = true;
let pauseUntil = 0;
let testDisableUntil = 0;
let aggressiveTamperIntervalId = null;

const TAMPER_PAGES = ["about:addons", "about:debugging", "about:preferences"];
const ALARM_UNLOCK_TIMER = "unlockTimer";
const ALARM_PAUSE_POSITIVE = "pausePositiveResume";
const ALARM_TEST_DISABLE = "testDisableResume";
const PAUSE_POSITIVE_MS = 2 * 60 * 1000;
const AGGRESSIVE_TAMPER_INTERVAL_MS = 100;

function sanitizeList(value) {
  if (!Array.isArray(value)) {
    return [];
  }

  const normalized = value
    .map((item) => (typeof item === "string" ? item.trim().toLowerCase() : ""))
    .filter((item) => item.length > 0);

  return [...new Set(normalized)];
}

function sanitizeMode(value) {
  return value === "allow" ? "allow" : "block";
}

function sanitizeUnlockMode(value) {
  return value === "phrase" ? "phrase" : "timer";
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

function isTamperUrl(url) {
  if (typeof url !== "string") {
    return false;
  }

  const lower = url.toLowerCase();
  return TAMPER_PAGES.some((token) => lower.includes(token));
}

function urlMatchesRule(url, rule) {
  const lowerUrl = url.toLowerCase();
  if (lowerUrl.includes(rule)) {
    return true;
  }

  try {
    const hostname = new URL(url).hostname.toLowerCase();
    return hostname === rule || hostname.endsWith(`.${rule}`);
  } catch {
    return false;
  }
}

function matchesAny(url, rules) {
  return rules.some((rule) => urlMatchesRule(url, rule));
}

function isViolation(url) {
  if (mode === "allow") {
    return !matchesAny(url, whiteList);
  }

  return matchesAny(url, blockList);
}

function isPausePositiveActive() {
  return pauseUntil > Date.now();
}

function isTemporarilyDisabledForTest() {
  return testDisableUntil > Date.now();
}

function shouldEnforceBlocking() {
  return isBlocking && !isPausePositiveActive() && !isTemporarilyDisabledForTest();
}

function isAddonsUrl(url) {
  return typeof url === "string" && url.toLowerCase().includes("about:addons");
}

function canStopBlocking() {
  if (unlockMode !== "timer") {
    return true;
  }

  return timerExpired;
}

async function removeTabSafely(tabId) {
  try {
    await browser.tabs.remove(tabId);
  } catch {
    // Ignore cases where the tab was already closed or is no longer accessible.
  }
}

async function sendPopupMessage(message) {
  try {
    await browser.runtime.sendMessage(message);
  } catch {
    // Ignore when popup is closed or no listeners are active.
  }
}

async function checkAndCloseTab(tabId, url) {
  if (!shouldEnforceBlocking()) {
    return;
  }

  if (!Number.isInteger(tabId) || tabId < 0 || typeof url !== "string" || !url) {
    return;
  }

  if (isTamperUrl(url) || isViolation(url)) {
    await removeTabSafely(tabId);
  }
}

async function aggressivelyCloseAddonsTab(tabId, url) {
  if (!shouldEnforceBlocking() || !isAddonsUrl(url)) {
    return;
  }

  await removeTabSafely(tabId);
}

async function aggressivelyCloseAddonsTabsByQuery() {
  if (!shouldEnforceBlocking()) {
    return;
  }

  const tabs = await browser.tabs.query({});
  const addonsTabs = tabs.filter((tab) => isAddonsUrl(tab.url));
  await Promise.all(addonsTabs.map((tab) => removeTabSafely(tab.id)));
}

function stopAggressiveTamperMonitor() {
  if (aggressiveTamperIntervalId !== null) {
    clearInterval(aggressiveTamperIntervalId);
    aggressiveTamperIntervalId = null;
  }
}

function startAggressiveTamperMonitor() {
  stopAggressiveTamperMonitor();
  if (!shouldEnforceBlocking()) {
    return;
  }

  aggressiveTamperIntervalId = setInterval(() => {
    void aggressivelyCloseAddonsTabsByQuery();
  }, AGGRESSIVE_TAMPER_INTERVAL_MS);
}

function reconcileAggressiveTamperMonitor() {
  if (shouldEnforceBlocking()) {
    startAggressiveTamperMonitor();
    return;
  }

  stopAggressiveTamperMonitor();
}

async function persistState() {
  await browser.storage.local.set({
    isBlocking,
    blockList,
    whiteList,
    mode,
    unlockMode,
    timerMinutes,
    unlockPhrase,
    lockEndTime,
    timerExpired,
    pausePositiveEnabled,
    pauseUntil,
    testDisableUntil
  });
}

function applySettingsPayload(payload = {}) {
  if ("blockList" in payload) {
    blockList = sanitizeList(payload.blockList);
  }

  if ("whiteList" in payload) {
    whiteList = sanitizeList(payload.whiteList);
  }

  if ("mode" in payload) {
    mode = sanitizeMode(payload.mode);
  }

  if ("unlockMode" in payload) {
    unlockMode = sanitizeUnlockMode(payload.unlockMode);
  }

  if ("timerMinutes" in payload) {
    timerMinutes = clampTimerMinutes(Number(payload.timerMinutes));
  }

  if ("unlockPhrase" in payload && typeof payload.unlockPhrase === "string") {
    const phrase = payload.unlockPhrase.trim();
    unlockPhrase = phrase.length > 0 ? phrase : unlockPhrase;
  }

  if ("pausePositiveEnabled" in payload && typeof payload.pausePositiveEnabled === "boolean") {
    pausePositiveEnabled = payload.pausePositiveEnabled;
  }
}

async function loadState() {
  const stored = await browser.storage.local.get([
    "isBlocking",
    "blockList",
    "whiteList",
    "mode",
    "unlockMode",
    "timerMinutes",
    "unlockPhrase",
    "lockEndTime",
    "timerExpired",
    "pausePositiveEnabled",
    "pauseUntil",
    "testDisableUntil"
  ]);

  if (typeof stored.isBlocking === "boolean") {
    isBlocking = stored.isBlocking;
  }

  if (stored.blockList !== undefined) {
    blockList = sanitizeList(stored.blockList);
  }

  if (stored.whiteList !== undefined) {
    whiteList = sanitizeList(stored.whiteList);
  }

  if (stored.mode !== undefined) {
    mode = sanitizeMode(stored.mode);
  }

  if (stored.unlockMode !== undefined) {
    unlockMode = sanitizeUnlockMode(stored.unlockMode);
  }

  if (stored.timerMinutes !== undefined) {
    timerMinutes = clampTimerMinutes(Number(stored.timerMinutes));
  }

  if (typeof stored.unlockPhrase === "string" && stored.unlockPhrase.trim().length > 0) {
    unlockPhrase = stored.unlockPhrase.trim();
  }

  if (Number.isFinite(stored.lockEndTime)) {
    lockEndTime = stored.lockEndTime;
  }

  if (typeof stored.timerExpired === "boolean") {
    timerExpired = stored.timerExpired;
  }

  if (typeof stored.pausePositiveEnabled === "boolean") {
    pausePositiveEnabled = stored.pausePositiveEnabled;
  }

  if (Number.isFinite(stored.pauseUntil)) {
    pauseUntil = stored.pauseUntil;
  }

  if (Number.isFinite(stored.testDisableUntil)) {
    testDisableUntil = stored.testDisableUntil;
  }
}

async function enforceAllOpenTabs() {
  const tabs = await browser.tabs.query({});
  await Promise.all(tabs.map((tab) => checkAndCloseTab(tab.id, tab.url)));
}

async function setupUnlockTimerAlarm() {
  await browser.alarms.clear(ALARM_UNLOCK_TIMER);

  if (unlockMode !== "timer" || timerExpired || lockEndTime <= Date.now()) {
    return;
  }

  browser.alarms.create(ALARM_UNLOCK_TIMER, { when: lockEndTime });
}

async function setupPausePositiveAlarm() {
  await browser.alarms.clear(ALARM_PAUSE_POSITIVE);

  if (!isPausePositiveActive()) {
    return;
  }

  browser.alarms.create(ALARM_PAUSE_POSITIVE, { when: pauseUntil });
}

async function setupTestDisableAlarm() {
  await browser.alarms.clear(ALARM_TEST_DISABLE);
  if (!isTemporarilyDisabledForTest()) {
    return;
  }

  browser.alarms.create(ALARM_TEST_DISABLE, { when: testDisableUntil });
}

async function startBlockingSession(payload = {}) {
  applySettingsPayload(payload);

  isBlocking = true;
  pauseUntil = 0;
  testDisableUntil = 0;
  await browser.alarms.clear(ALARM_PAUSE_POSITIVE);
  await browser.alarms.clear(ALARM_TEST_DISABLE);

  if (unlockMode === "timer") {
    timerExpired = false;
    lockEndTime = Date.now() + timerMinutes * 60 * 1000;
    await setupUnlockTimerAlarm();
  } else {
    timerExpired = true;
    lockEndTime = 0;
    await browser.alarms.clear(ALARM_UNLOCK_TIMER);
  }

  await persistState();
  reconcileAggressiveTamperMonitor();
  await enforceAllOpenTabs();

  return {
    ok: true,
    isBlocking,
    unlockMode,
    timerExpired,
    lockEndTime,
    pauseUntil
  };
}

async function stopBlockingSession() {
  if (!canStopBlocking()) {
    return { ok: false, error: "TIMER_NOT_EXPIRED" };
  }

  isBlocking = false;
  pauseUntil = 0;
  lockEndTime = 0;
  timerExpired = true;
  testDisableUntil = 0;

  await browser.alarms.clear(ALARM_UNLOCK_TIMER);
  await browser.alarms.clear(ALARM_PAUSE_POSITIVE);
  await browser.alarms.clear(ALARM_TEST_DISABLE);
  await persistState();
  reconcileAggressiveTamperMonitor();

  return { ok: true };
}

async function startPausePositiveSession(payload = {}) {
  if (!isBlocking) {
    return { ok: false, error: "NOT_BLOCKING" };
  }

  if (unlockMode !== "timer") {
    return { ok: false, error: "PAUSE_POSITIVE_TIMER_ONLY" };
  }

  if (timerExpired) {
    return { ok: false, error: "TIMER_ALREADY_EXPIRED" };
  }

  if (!pausePositiveEnabled) {
    return { ok: false, error: "PAUSE_POSITIVE_DISABLED" };
  }

  const expectedPhrase = normalizePhrase(unlockPhrase);
  const actualPhrase = normalizePhrase(payload.phrase);
  if (actualPhrase !== expectedPhrase) {
    return { ok: false, error: "PHRASE_MISMATCH" };
  }

  pauseUntil = Date.now() + PAUSE_POSITIVE_MS;
  await setupPausePositiveAlarm();
  await persistState();
  reconcileAggressiveTamperMonitor();
  await sendPopupMessage({ type: "PAUSE_POSITIVE_STARTED", pauseUntil });

  return { ok: true, pauseUntil };
}

async function reconcileTimers() {
  let changed = false;

  if (unlockMode === "timer" && isBlocking && !timerExpired) {
    if (lockEndTime > Date.now()) {
      await setupUnlockTimerAlarm();
    } else {
      timerExpired = true;
      changed = true;
    }
  } else {
    await browser.alarms.clear(ALARM_UNLOCK_TIMER);
  }

  if (pauseUntil > 0) {
    if (isPausePositiveActive()) {
      await setupPausePositiveAlarm();
    } else {
      pauseUntil = 0;
      changed = true;
    }
  }

  if (testDisableUntil > 0) {
    if (isTemporarilyDisabledForTest()) {
      await setupTestDisableAlarm();
    } else {
      testDisableUntil = 0;
      changed = true;
    }
  }

  if (changed) {
    await persistState();
  }
}

browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const url = changeInfo.url || tab.url;
  void aggressivelyCloseAddonsTab(tabId, url);
  void checkAndCloseTab(tabId, url);
});

browser.webNavigation.onBeforeNavigate.addListener((details) => {
  void aggressivelyCloseAddonsTab(details.tabId, details.url);
  void checkAndCloseTab(details.tabId, details.url);
});

browser.tabs.onActivated.addListener((activeInfo) => {
  void (async () => {
    try {
      const tab = await browser.tabs.get(activeInfo.tabId);
      await aggressivelyCloseAddonsTab(tab.id, tab.url);
      await checkAndCloseTab(tab.id, tab.url);
    } catch {
      // Ignore race conditions where the activated tab disappears.
    }
  })();
});

browser.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_UNLOCK_TIMER) {
    void (async () => {
      timerExpired = true;
      await persistState();
      await sendPopupMessage({ type: "UNLOCK_TIMER_EXPIRED", expiredAt: Date.now() });
    })();
    return;
  }

  if (alarm.name === ALARM_PAUSE_POSITIVE) {
    void (async () => {
      pauseUntil = 0;
      await persistState();
      reconcileAggressiveTamperMonitor();
      await enforceAllOpenTabs();
      await sendPopupMessage({ type: "PAUSE_POSITIVE_ENDED" });
    })();
    return;
  }

  if (alarm.name === ALARM_TEST_DISABLE) {
    void (async () => {
      testDisableUntil = 0;
      await persistState();
      reconcileAggressiveTamperMonitor();
      await enforceAllOpenTabs();
      await sendPopupMessage({ type: "TEST_DISABLE_EXPIRED" });
    })();
  }
});

browser.runtime.onMessage.addListener((message = {}) => {
  const type = message.type;
  const payload = message.payload || {};

  if (type === "START_BLOCKING") {
    return startBlockingSession(payload);
  }

  if (type === "STOP_BLOCKING") {
    return stopBlockingSession();
  }

  if (type === "REQUEST_PAUSE_POSITIVE") {
    return startPausePositiveSession(payload);
  }

  if (type === "TEMP_DISABLE_FOR_TEST") {
    const requestedSeconds = Number(payload.durationSeconds);
    const durationSeconds = Number.isFinite(requestedSeconds)
      ? Math.min(300, Math.max(5, Math.round(requestedSeconds)))
      : 60;

    testDisableUntil = Date.now() + durationSeconds * 1000;
    return setupTestDisableAlarm()
      .then(() => persistState())
      .then(() => {
        reconcileAggressiveTamperMonitor();
        return sendPopupMessage({ type: "TEST_DISABLE_STARTED", testDisableUntil });
      })
      .then(() => ({ ok: true, testDisableUntil }));
  }

  if (type === "UPDATE_SETTINGS") {
    applySettingsPayload(payload);
    return persistState()
      .then(() => {
        reconcileAggressiveTamperMonitor();
        if (isBlocking && !isPausePositiveActive() && !isTemporarilyDisabledForTest()) {
          return enforceAllOpenTabs();
        }
        return undefined;
      })
      .then(() => ({ ok: true }));
  }

  return Promise.resolve({ ok: false, error: "UNKNOWN_MESSAGE_TYPE" });
});

void loadState()
  .then(async () => {
    await reconcileTimers();
    reconcileAggressiveTamperMonitor();
    if (isBlocking && !isPausePositiveActive() && !isTemporarilyDisabledForTest()) {
      await aggressivelyCloseAddonsTabsByQuery();
      await enforceAllOpenTabs();
    }
  })
  .catch(() => {
    // Ignore bootstrap errors to keep the worker alive; defaults remain in effect.
  });
