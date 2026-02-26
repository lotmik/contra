let isBlocking = false;
let blockList = [];
let whiteList = [];
let adultContentBlockingEnabled = false;
let mode = "block";
let unlockMode = "timer";
let timerMinutes = 25;
let unlockPhrase = "I swear to god I will focus";
let lockEndTime = 0;
let timerExpired = true;
let pausePositiveEnabled = true;
let pauseUntil = 0;
let testDisableUntil = 0;
let recoverableClosedTabs = [];
let aggressiveTamperIntervalId = null;
let adultDomainSet = null;
let adultDomainLoadPromise = null;
let adultContentForcedByPolicy = false;

const TAMPER_PAGES = [
  "about:addons",
  "about:debugging",
  "about:config",
  "about:policies",
  "about:support",
  "about:profiles",
  "about:preferences",
  "about:preferences#addons",
  "chrome://extensions",
  "chrome://policy",
  "chrome://settings/extensions",
  "edge://extensions",
  "edge://policy",
  "edge://settings/extensions",
  "brave://extensions",
  "brave://policy",
  "brave://settings/extensions",
  "opera://extensions",
  "opera://policy",
  "vivaldi://extensions"
];
const SYSTEM_ALLOWED_URL_PREFIXES = [
  "about:newtab",
  "about:blank",
  "about:home",
  "about:privatebrowsing",
  "about:welcome",
  "about:sessionrestore",
  "about:restartrequired",
  "moz-extension://",
  "chrome-extension://",
  "chrome://newtab",
  "edge://newtab",
  "brave://newtab",
  "vivaldi://newtab",
  "opera://startpage"
];
const ALARM_UNLOCK_TIMER = "unlockTimer";
const ALARM_PAUSE_POSITIVE = "pausePositiveResume";
const ALARM_TEST_DISABLE = "testDisableResume";
const ALARM_ADULT_LIST_REFRESH = "adultListRefresh";
const PAUSE_POSITIVE_MS = 2 * 60 * 1000;
const AGGRESSIVE_TAMPER_INTERVAL_MS = 100;
const MAX_RECOVERABLE_CLOSED_TABS = 200;
const ADULT_DOMAIN_LIST_PATH = "data/adult-domains.txt";
const ADULT_LIST_REFRESH_INTERVAL_MINUTES = 15;
const ADULT_LIST_FETCH_TIMEOUT_MS = 15000;
const BON_APPETIT_REPO_CONTENTS_URL = "https://api.github.com/repos/Bon-Appetit/porn-domains/contents";
const ANTI_PORN_HOSTS_URL =
  "https://raw.githubusercontent.com/4skinSkywalker/Anti-Porn-HOSTS-File/main/HOSTS.txt";
const MANAGED_POLICY_FORCE_ADULT_KEYS = ["forceAdultBlock", "forceAdultBlocking", "adultBlockForced", "adult"];

function sanitizeList(value) {
  if (!Array.isArray(value)) {
    return [];
  }

  const normalized = value
    .map((item) => normalizeUrlRule(item))
    .filter((item) => typeof item === "string" && item.length > 0);

  return [...new Set(normalized)];
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

  return Math.min(1440, Math.max(1, Math.round(value)));
}

function normalizePhrase(value) {
  return String(value || "")
    .trim()
    .replace(/\s+/g, " ")
    .toLowerCase();
}

function sanitizeRecoverableClosedTabs(value) {
  if (!Array.isArray(value)) {
    return [];
  }

  const sanitized = [];
  for (const item of value) {
    if (!item || typeof item !== "object") {
      continue;
    }

    const url = typeof item.url === "string" ? item.url.trim() : "";
    if (url.length === 0) {
      continue;
    }

    sanitized.push({
      url,
      windowId: Number.isInteger(item.windowId) ? item.windowId : null,
      index: Number.isInteger(item.index) ? Math.max(0, item.index) : null
    });

    if (sanitized.length >= MAX_RECOVERABLE_CLOSED_TABS) {
      break;
    }
  }

  return sanitized;
}

function sanitizeBoolean(value, fallback = false) {
  if (typeof value === "boolean") {
    return value;
  }

  return fallback;
}

function resolveManagedAdultPolicyFlag(value) {
  if (!value || typeof value !== "object") {
    return false;
  }

  return MANAGED_POLICY_FORCE_ADULT_KEYS.some((key) => value[key] === true);
}

function isAdultBlockingEnabled() {
  return adultContentForcedByPolicy || adultContentBlockingEnabled;
}

function extractHostnameFromUrl(url) {
  if (typeof url !== "string" || url.length === 0) {
    return "";
  }

  try {
    return new URL(url).hostname.toLowerCase().replace(/\.+$/, "");
  } catch {
    return "";
  }
}

function sanitizeAdultDomain(domain) {
  const normalized = String(domain || "")
    .trim()
    .toLowerCase()
    .replace(/\.+$/, "");
  if (
    normalized.length === 0 ||
    normalized.length > 253 ||
    !normalized.includes(".") ||
    !/^[a-z0-9.-]+$/.test(normalized)
  ) {
    return "";
  }

  return normalized;
}

function parseAdultDomainSetFromText(rawText) {
  const domains = new Set();
  if (typeof rawText !== "string" || rawText.length === 0) {
    return domains;
  }

  const lines = rawText.split(/\r?\n/);
  for (const line of lines) {
    const domain = sanitizeAdultDomain(line);
    if (!domain) {
      continue;
    }
    domains.add(domain);
  }

  return domains;
}

function parseAdultDomainSetFromHostsText(rawText) {
  const domains = new Set();
  if (typeof rawText !== "string" || rawText.length === 0) {
    return domains;
  }

  const lines = rawText.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }

    const columns = trimmed.split(/\s+/);
    if (columns.length < 2) {
      continue;
    }

    const domain = sanitizeAdultDomain(columns[1]);
    if (!domain) {
      continue;
    }

    domains.add(domain);
  }

  return domains;
}

async function fetchTextWithTimeout(url, timeoutMs = ADULT_LIST_FETCH_TIMEOUT_MS) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => {
    controller.abort();
  }, timeoutMs);

  try {
    const response = await fetch(url, {
      cache: "no-cache",
      signal: controller.signal
    });
    if (!response.ok) {
      throw new Error(`HTTP_${response.status}`);
    }

    return response.text();
  } finally {
    clearTimeout(timeoutId);
  }
}

async function resolveBonAppetitBlocklistUrl() {
  const raw = await fetchTextWithTimeout(BON_APPETIT_REPO_CONTENTS_URL);
  const entries = JSON.parse(raw);
  if (!Array.isArray(entries)) {
    throw new Error("BON_APPETIT_CONTENTS_INVALID");
  }

  const blockEntry = entries.find((entry) => {
    const name = typeof entry?.name === "string" ? entry.name : "";
    return /^block\..+\.txt$/i.test(name) && typeof entry?.download_url === "string";
  });

  if (!blockEntry?.download_url) {
    throw new Error("BON_APPETIT_BLOCK_FILE_NOT_FOUND");
  }

  return blockEntry.download_url;
}

async function loadBundledAdultDomainSet() {
  const rawText = await fetchTextWithTimeout(browser.runtime.getURL(ADULT_DOMAIN_LIST_PATH));
  adultDomainSet = parseAdultDomainSetFromText(rawText);
  return adultDomainSet;
}

async function refreshAdultDomainSetFromRemote() {
  try {
    const bonAppetitUrl = await resolveBonAppetitBlocklistUrl();
    const [bonAppetitText, hostsText] = await Promise.all([
      fetchTextWithTimeout(bonAppetitUrl),
      fetchTextWithTimeout(ANTI_PORN_HOSTS_URL)
    ]);

    const nextSet = parseAdultDomainSetFromText(bonAppetitText);
    for (const domain of parseAdultDomainSetFromHostsText(hostsText)) {
      nextSet.add(domain);
    }

    if (nextSet.size > 0) {
      adultDomainSet = nextSet;
      return nextSet;
    }
  } catch (error) {
    console.error("Failed to refresh adult domain blocklist from remote", error);
  }

  return adultDomainSet instanceof Set ? adultDomainSet : new Set();
}

async function ensureAdultDomainSetLoaded() {
  if (adultDomainSet instanceof Set) {
    return adultDomainSet;
  }

  if (adultDomainLoadPromise) {
    return adultDomainLoadPromise;
  }

  adultDomainLoadPromise = (async () => {
    try {
      await loadBundledAdultDomainSet();
    } catch (error) {
      adultDomainSet = new Set();
      console.error("Failed to load adult domain blocklist", error);
    } finally {
      adultDomainLoadPromise = null;
    }

    return adultDomainSet;
  })();

  return adultDomainLoadPromise;
}

async function setupAdultListRefreshAlarm() {
  await browser.alarms.clear(ALARM_ADULT_LIST_REFRESH);
  browser.alarms.create(ALARM_ADULT_LIST_REFRESH, {
    periodInMinutes: ADULT_LIST_REFRESH_INTERVAL_MINUTES
  });
}

function matchesAdultDomainRule(url) {
  if (!isAdultBlockingEnabled() || !(adultDomainSet instanceof Set) || adultDomainSet.size === 0) {
    return false;
  }

  let candidate = extractHostnameFromUrl(url);
  while (candidate.length > 0) {
    if (adultDomainSet.has(candidate)) {
      return true;
    }

    const separatorIndex = candidate.indexOf(".");
    if (separatorIndex < 0) {
      break;
    }

    candidate = candidate.slice(separatorIndex + 1);
  }

  return false;
}

function isTamperUrl(url) {
  if (typeof url !== "string") {
    return false;
  }

  const lower = url.toLowerCase();
  return TAMPER_PAGES.some((token) => lower.includes(token));
}

function isSystemAllowedUrl(url) {
  if (typeof url !== "string") {
    return false;
  }

  const lower = url.toLowerCase().trim();
  if (!lower || isTamperUrl(lower)) {
    return false;
  }

  return SYSTEM_ALLOWED_URL_PREFIXES.some((prefix) => lower.startsWith(prefix));
}

function urlMatchesRule(url, rule) {
  if (typeof url !== "string") {
    return false;
  }

  const normalizedRule = normalizeUrlRule(rule);
  if (!normalizedRule) {
    return false;
  }

  const hasScheme = /^[a-z][a-z\d+.-]*:\/\//i.test(normalizedRule);
  const candidateRule = hasScheme
    ? normalizedRule
    : `https://${normalizedRule}`;

  try {
    const ruleUrl = new URL(candidateRule);
    const targetUrl = new URL(url);
    const ruleHostname = ruleUrl.hostname.toLowerCase();
    const hostname = targetUrl.hostname.toLowerCase();
    if (!(hostname === ruleHostname || hostname.endsWith(`.${ruleHostname}`))) {
      return false;
    }

    if (ruleUrl.port && targetUrl.port !== ruleUrl.port) {
      return false;
    }

    if (hasScheme && targetUrl.protocol !== ruleUrl.protocol) {
      return false;
    }

    const rulePathname = ruleUrl.pathname || "/";
    if (rulePathname !== "/") {
      const targetPathname = targetUrl.pathname || "/";
      if (targetPathname !== rulePathname && !targetPathname.startsWith(`${rulePathname}/`)) {
        return false;
      }
    }

    if (ruleUrl.search && targetUrl.search !== ruleUrl.search) {
      return false;
    }

    return true;
  } catch {
    return false;
  }
}

function matchesAny(url, rules) {
  return rules.some((rule) => urlMatchesRule(url, rule));
}

function isViolation(url) {
  if (isSystemAllowedUrl(url)) {
    return false;
  }

  if (matchesAdultDomainRule(url)) {
    return true;
  }

  if (!isBlocking || isPausePositiveActive() || isTemporarilyDisabledForTest()) {
    return false;
  }

  if (mode === "allow") {
    return !matchesAny(url, whiteList);
  }

  return matchesAny(url, blockList);
}

function shouldCloseForBlocking(url) {
  if (!isBlocking && adultContentForcedByPolicy) {
    return matchesAdultDomainRule(url);
  }

  return isTamperUrl(url) || isViolation(url);
}

function shouldKeepTabOpen(tab) {
  if (!Number.isInteger(tab?.id) || tab.id < 0) {
    return true;
  }

  const url = getTabUrl(tab);
  if (!url) {
    return true;
  }

  return !shouldCloseForBlocking(url);
}

async function ensureSurvivorTab(excludedTabId, targetWindowId = null) {
  try {
    const queryOptions = Number.isInteger(targetWindowId) ? { windowId: targetWindowId } : {};
    const tabs = await browser.tabs.query(queryOptions);
    const remainingTabs = tabs.filter((tab) => tab.id !== excludedTabId);
    if (remainingTabs.some((tab) => shouldKeepTabOpen(tab))) {
      return;
    }

    const createProperties = { active: false };
    if (Number.isInteger(targetWindowId)) {
      createProperties.windowId = targetWindowId;
    }

    await browser.tabs.create(createProperties);
  } catch {
    // Ignore fallback-tab errors; remove path handles failures safely.
  }
}

async function closeTabWithSurvivor(tabId, url, context = {}) {
  if (!Number.isInteger(tabId) || tabId < 0 || typeof url !== "string" || !url) {
    return;
  }

  if (!shouldCloseForBlocking(url)) {
    return;
  }

  let windowId = Number.isInteger(context?.windowId) ? context.windowId : null;
  if (!Number.isInteger(windowId)) {
    try {
      const tab = await browser.tabs.get(tabId);
      windowId = Number.isInteger(tab?.windowId) ? tab.windowId : null;
    } catch {
      windowId = null;
    }
  }

  await ensureSurvivorTab(tabId, windowId);
  await removeTabSafely(tabId);
}

function isPausePositiveActive() {
  return pauseUntil > Date.now();
}

function isTemporarilyDisabledForTest() {
  return testDisableUntil > Date.now();
}

function shouldEnforceBlocking() {
  if (adultContentForcedByPolicy) {
    return true;
  }

  return isBlocking && !isPausePositiveActive() && !isTemporarilyDisabledForTest();
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

function getTabUrl(tab) {
  if (!tab || typeof tab !== "object") {
    return "";
  }

  const pendingUrl = typeof tab.pendingUrl === "string" ? tab.pendingUrl.trim() : "";
  if (pendingUrl.length > 0) {
    return pendingUrl;
  }

  const stableUrl = typeof tab.url === "string" ? tab.url.trim() : "";
  return stableUrl;
}

function createRecoverableClosedTabSnapshot(tab, url) {
  if (typeof url !== "string" || url.length === 0) {
    return null;
  }

  return {
    url,
    windowId: Number.isInteger(tab?.windowId) ? tab.windowId : null,
    index: Number.isInteger(tab?.index) ? Math.max(0, tab.index) : null
  };
}

async function restoreRecoverableClosedTabs() {
  try {
    if (!Array.isArray(recoverableClosedTabs) || recoverableClosedTabs.length === 0) {
      return 0;
    }

    const tabs = sanitizeRecoverableClosedTabs(recoverableClosedTabs);
    if (tabs.length === 0) {
      return 0;
    }

    const currentlyOpenTabs = await browser.tabs.query({});
    const openCountsByUrl = new Map();
    for (const tab of currentlyOpenTabs) {
      const url = getTabUrl(tab);
      if (!url) {
        continue;
      }

      openCountsByUrl.set(url, (openCountsByUrl.get(url) || 0) + 1);
    }

    const missingCountsByUrl = new Map();
    for (const tab of tabs) {
      missingCountsByUrl.set(tab.url, (missingCountsByUrl.get(tab.url) || 0) + 1);
    }

    for (const [url, openCount] of openCountsByUrl) {
      if (!missingCountsByUrl.has(url)) {
        continue;
      }

      const missingCount = Math.max(0, (missingCountsByUrl.get(url) || 0) - openCount);
      missingCountsByUrl.set(url, missingCount);
    }

    const orderedTabs = [...tabs].sort((left, right) => {
      if (left.windowId !== right.windowId) {
        return (left.windowId || 0) - (right.windowId || 0);
      }

      return (left.index || 0) - (right.index || 0);
    });

    let restoredCount = 0;
    for (const tab of orderedTabs) {
      const missingForUrl = missingCountsByUrl.get(tab.url) || 0;
      if (missingForUrl <= 0) {
        continue;
      }

      missingCountsByUrl.set(tab.url, missingForUrl - 1);

      const createProperties = {
        url: tab.url,
        active: false
      };

      if (Number.isInteger(tab.windowId)) {
        createProperties.windowId = tab.windowId;
      }

      if (Number.isInteger(tab.index) && Number.isInteger(tab.windowId)) {
        createProperties.index = tab.index;
      }

      try {
        await browser.tabs.create(createProperties);
        restoredCount += 1;
        continue;
      } catch {
        // Fall through to a simplified restore attempt.
      }

      try {
        await browser.tabs.create({ url: tab.url, active: false });
        restoredCount += 1;
      } catch {
        // Ignore if the browser rejects restoring a specific URL.
      }
    }

    return restoredCount;
  } catch {
    return 0;
  }
}

async function checkAndCloseTab(tabId, url, context = {}) {
  if (!shouldEnforceBlocking()) {
    return;
  }

  await closeTabWithSurvivor(tabId, url, context);
}

async function aggressivelyCloseTamperTab(tabId, url, context = {}) {
  if (!isBlocking || !shouldEnforceBlocking()) {
    return;
  }

  if (!isTamperUrl(url)) {
    return;
  }

  await closeTabWithSurvivor(tabId, url, context);
}

async function aggressivelyCloseTamperTabsByQuery() {
  if (!isBlocking || !shouldEnforceBlocking()) {
    return;
  }

  const tabs = await browser.tabs.query({});
  const tamperTabs = tabs.filter((tab) => isTamperUrl(tab.pendingUrl || tab.url));
  for (const tab of tamperTabs) {
    await aggressivelyCloseTamperTab(tab.id, getTabUrl(tab), tab);
  }
}

function stopAggressiveTamperMonitor() {
  if (aggressiveTamperIntervalId !== null) {
    clearInterval(aggressiveTamperIntervalId);
    aggressiveTamperIntervalId = null;
  }
}

function startAggressiveTamperMonitor() {
  stopAggressiveTamperMonitor();
  if (!isBlocking || !shouldEnforceBlocking()) {
    return;
  }

  aggressiveTamperIntervalId = setInterval(() => {
    void aggressivelyCloseTamperTabsByQuery();
  }, AGGRESSIVE_TAMPER_INTERVAL_MS);
}

function reconcileAggressiveTamperMonitor() {
  if (isBlocking && shouldEnforceBlocking()) {
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
    adultContentBlockingEnabled,
    mode,
    unlockMode,
    timerMinutes,
    unlockPhrase,
    lockEndTime,
    timerExpired,
    pausePositiveEnabled,
    pauseUntil,
    testDisableUntil,
    recoverableClosedTabs
  });
}

function applySettingsPayload(payload = {}) {
  if ("blockList" in payload) {
    blockList = sanitizeList(payload.blockList);
  }

  if ("whiteList" in payload) {
    whiteList = sanitizeList(payload.whiteList);
  }

  if ("adultContentBlockingEnabled" in payload) {
    adultContentBlockingEnabled = adultContentForcedByPolicy
      ? true
      : sanitizeBoolean(payload.adultContentBlockingEnabled, false);
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

  if (adultContentForcedByPolicy) {
    adultContentBlockingEnabled = true;
  }
}

async function loadManagedPolicy() {
  try {
    if (!browser?.storage?.managed?.get) {
      adultContentForcedByPolicy = false;
      return;
    }

    const managed = await browser.storage.managed.get(null);
    adultContentForcedByPolicy = resolveManagedAdultPolicyFlag(managed);
  } catch {
    adultContentForcedByPolicy = false;
  }

  if (adultContentForcedByPolicy) {
    adultContentBlockingEnabled = true;
  }
}

async function loadState() {
  const stored = await browser.storage.local.get([
    "isBlocking",
    "blockList",
    "whiteList",
    "adultContentBlockingEnabled",
    "mode",
    "unlockMode",
    "timerMinutes",
    "unlockPhrase",
    "lockEndTime",
    "timerExpired",
    "pausePositiveEnabled",
    "pauseUntil",
    "testDisableUntil",
    "recoverableClosedTabs"
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

  if (stored.adultContentBlockingEnabled !== undefined) {
    adultContentBlockingEnabled = sanitizeBoolean(stored.adultContentBlockingEnabled, false);
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

  if (stored.recoverableClosedTabs !== undefined) {
    recoverableClosedTabs = sanitizeRecoverableClosedTabs(stored.recoverableClosedTabs);
  }

  if (!isBlocking && recoverableClosedTabs.length > 0) {
    recoverableClosedTabs = [];
  }

  if (adultContentForcedByPolicy) {
    adultContentBlockingEnabled = true;
  }
}

async function enforceAllOpenTabs() {
  const tabs = await browser.tabs.query({});
  for (const tab of tabs) {
    const url = getTabUrl(tab);
    await checkAndCloseTab(tab.id, url, tab);
  }
}

async function enforceAllOpenTabsAtSessionStart() {
  const initialClosedTabs = [];
  try {
    const tabs = await browser.tabs.query({});
    for (const tab of tabs) {
      const tabId = tab.id;
      const url = getTabUrl(tab);
      if (!Number.isInteger(tabId) || tabId < 0 || typeof url !== "string" || !url) {
        continue;
      }

      if (!shouldCloseForBlocking(url)) {
        continue;
      }

      if (isViolation(url)) {
        const snapshot = createRecoverableClosedTabSnapshot(tab, url);
        if (snapshot) {
          initialClosedTabs.push(snapshot);
        }
      }

      await closeTabWithSurvivor(tabId, url, tab);
    }
  } catch {
    // Keep blocking active even if a startup sweep fails unexpectedly.
  }

  recoverableClosedTabs = sanitizeRecoverableClosedTabs(initialClosedTabs);
  await persistState();
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
  if (isAdultBlockingEnabled()) {
    await ensureAdultDomainSetLoaded();
  }

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

  recoverableClosedTabs = [];
  await persistState();
  reconcileAggressiveTamperMonitor();
  await enforceAllOpenTabsAtSessionStart();

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

  const restoredTabs = await restoreRecoverableClosedTabs();
  recoverableClosedTabs = [];
  await persistState();
  reconcileAggressiveTamperMonitor();

  return { ok: true, restoredTabs };
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

async function resumePausePositiveSession() {
  if (!isBlocking) {
    return { ok: false, error: "NOT_BLOCKING" };
  }

  if (unlockMode !== "timer") {
    return { ok: false, error: "PAUSE_POSITIVE_TIMER_ONLY" };
  }

  if (!isPausePositiveActive()) {
    return { ok: true, pauseUntil: 0 };
  }

  pauseUntil = 0;
  await browser.alarms.clear(ALARM_PAUSE_POSITIVE);
  await persistState();
  reconcileAggressiveTamperMonitor();
  await enforceAllOpenTabs();
  await sendPopupMessage({ type: "PAUSE_POSITIVE_ENDED" });

  return { ok: true, pauseUntil: 0 };
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
  void aggressivelyCloseTamperTab(tabId, url, tab);
  void checkAndCloseTab(tabId, url, tab);
});

browser.tabs.onCreated.addListener((tab) => {
  const url = tab.pendingUrl || tab.url;
  void aggressivelyCloseTamperTab(tab.id, url, tab);
  void checkAndCloseTab(tab.id, url, tab);
});

browser.webNavigation.onBeforeNavigate.addListener((details) => {
  if (!details || details.frameId !== 0) {
    return;
  }

  void aggressivelyCloseTamperTab(details.tabId, details.url, details);
  void checkAndCloseTab(details.tabId, details.url, details);
});

browser.tabs.onActivated.addListener((activeInfo) => {
  void (async () => {
    try {
      const tab = await browser.tabs.get(activeInfo.tabId);
      await aggressivelyCloseTamperTab(tab.id, tab.url, tab);
      await checkAndCloseTab(tab.id, tab.url, tab);
    } catch {
      // Ignore race conditions where the activated tab disappears.
    }
  })();
});

browser.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_ADULT_LIST_REFRESH) {
    void refreshAdultDomainSetFromRemote();
    return;
  }

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

  if (type === "RESUME_PAUSE_POSITIVE") {
    return resumePausePositiveSession();
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
    return Promise.resolve()
      .then(() => {
        if (isAdultBlockingEnabled()) {
          return ensureAdultDomainSetLoaded();
        }
        return undefined;
      })
      .then(() => persistState())
      .then(() => {
        reconcileAggressiveTamperMonitor();
        if (shouldEnforceBlocking()) {
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
    await setupAdultListRefreshAlarm();
    await ensureAdultDomainSetLoaded();
    void refreshAdultDomainSetFromRemote();

    await loadManagedPolicy();
    if (isAdultBlockingEnabled()) {
      await ensureAdultDomainSetLoaded();
    }

    await reconcileTimers();
    reconcileAggressiveTamperMonitor();
    if (shouldEnforceBlocking()) {
      await aggressivelyCloseTamperTabsByQuery();
      await enforceAllOpenTabs();
    }
  })
  .catch(() => {
    // Ignore bootstrap errors to keep the worker alive; defaults remain in effect.
  });
