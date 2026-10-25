const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "background.js"), "utf8");

async function startBrowser(initialState) {
  let state;
  const listeners = {};
  const alarms = new Map();
  const event = (name) => ({ addListener(callback) { listeners[name] = callback; } });
  const browser = {
    storage: {
      local: {
        async get(keys) {
          return Object.fromEntries(keys.filter((key) => key in state).map((key) => [key, state[key]]));
        },
        async set(values) { Object.assign(state, values); }
      },
      managed: { async get() { return {}; } },
      onChanged: event("storageChanged")
    },
    runtime: {
      getURL: (name) => `moz-extension://test/${name}`,
      async sendMessage() {},
      onInstalled: event("installed"),
      onStartup: event("startup"),
      onMessage: event("message")
    },
    tabs: {
      async query() { return []; },
      onUpdated: event("tabUpdated"),
      onCreated: event("tabCreated"),
      onActivated: event("tabActivated")
    },
    webNavigation: { onBeforeNavigate: event("beforeNavigate") },
    alarms: {
      async clear(name) { alarms.delete(name); },
      create(name, options) { alarms.set(name, options); },
      onAlarm: event("alarm")
    },
    action: {
      async setBadgeText() {},
      async setBadgeBackgroundColor() {}
    }
  };
  const context = vm.createContext({
    browser,
    fetch: async () => ({ ok: true, text: async () => "example.invalid\n" }),
    AbortController,
    URL,
    setTimeout,
    clearTimeout,
    setInterval: () => 1,
    clearInterval() {},
    console
  });
  state = vm.runInContext(`(${JSON.stringify(initialState)})`, context);
  vm.runInContext(source, context);
  listeners.startup();
  await vm.runInContext("bootstrapPromise", context);
  for (let index = 0; index < 20; index += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  return { state, alarms };
}

test("startup enables the blocklist by default and starts the timer", async () => {
  const { state, alarms } = await startBrowser({
    adultContentBlockingEnabled: false,
    blockList: ["blocked.example"],
    mode: "allow",
    timerMinutes: 15
  });
  assert.equal(state.isBlocking, true);
  assert.equal(state.mode, "block");
  assert.equal(state.autoTurnOn, true);
  assert.equal(state.startupMode, "block");
  assert.ok(state.lockEndTime > Date.now());
  assert.ok(alarms.has("unlockTimer"));
});

test("startup can enable the allowlist", async () => {
  const { state } = await startBrowser({
    adultContentBlockingEnabled: false,
    startupMode: "allow",
    whiteList: ["allowed.example"]
  });
  assert.equal(state.isBlocking, true);
  assert.equal(state.mode, "allow");
  assert.deepEqual(Array.from(state.whiteList), ["allowed.example"]);
});

test("disabled auto turn on leaves blocking off", async () => {
  const { state } = await startBrowser({
    adultContentBlockingEnabled: false,
    autoTurnOn: false,
    isBlocking: false
  });
  assert.equal(state.isBlocking, false);
  assert.equal(state.mode ?? "block", "block");
});
