const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

test("typing the unlock phrase keeps the native input and caret intact", () => {
  const popupSource = fs.readFileSync(path.join(__dirname, "..", "popup.js"), "utf8");
  const sourceWithoutStartup = popupSource.slice(0, popupSource.lastIndexOf("void initializePopup().catch"));
  const elements = new Map();
  const getElement = (id) => {
    if (!elements.has(id)) {
      elements.set(id, {
        value: "",
        textContent: "",
        selectionStart: 0,
        hidden: false,
        disabled: false,
        style: {},
        classList: { toggle() {} },
        blur() {}
      });
    }
    return elements.get(id);
  };
  const document = {
    body: getElement("body"),
    getElementById: getElement,
    querySelector: getElement,
    querySelectorAll: () => [],
    createElement() { throw new Error("Typing should not rebuild character nodes"); }
  };
  const context = vm.createContext({ document, URL });
  vm.runInContext(sourceWithoutStartup, context);
  const input = getElement("unlock-phrase-input");
  const reference = getElement("unlock-phrase-display");

  vm.runInContext('state.unlockPhrase = "Stay focused"; syncUnlockPhraseReference()', context);
  assert.equal(reference.textContent, "Stay focused");
  input.value = "Stay focus";
  input.selectionStart = 6;
  vm.runInContext("handlePhraseInput()", context);
  assert.equal(input.value, "Stay focus");
  assert.equal(input.selectionStart, 6);
  assert.equal(reference.textContent, "Stay focused");

  vm.runInContext('state.isBlocking = true; state.unlockMode = "phrase"', context);
  vm.runInContext("handlePhraseInput()", context);
  assert.equal(getElement("unlock-confirm-btn").disabled, true);
  input.value = "Stay focused";
  input.selectionStart = input.value.length;
  vm.runInContext("handlePhraseInput()", context);
  assert.equal(getElement("unlock-confirm-btn").disabled, false);
  assert.equal(input.selectionStart, input.value.length);
});

test("startup menu saves off, blocklist, and whitelist choices", () => {
  const popupSource = fs.readFileSync(path.join(__dirname, "..", "popup.js"), "utf8");
  const sourceWithoutStartup = popupSource.slice(0, popupSource.lastIndexOf("void initializePopup().catch"));
  const elements = new Map();
  const saved = [];
  const getElement = (id) => {
    if (!elements.has(id)) {
      elements.set(id, {
        value: "",
        checked: false,
        disabled: false,
        classList: { toggle() {} }
      });
    }
    return elements.get(id);
  };
  const segment = getElement("startup-mode-segment");
  getElement("mode-segment").querySelectorAll = () => [];
  getElement("unlock-mode-segment").querySelectorAll = () => [];
  const buttons = ["off", "block", "allow"].map((value) => ({
    dataset: { value },
    disabled: false,
    tabIndex: -1,
    classList: { toggle() {} },
    setAttribute(name, setting) { this[name] = setting; },
    closest(selector) { return selector === "#startup-mode-segment" || selector === ".segmented-control" ? segment : this; },
    focus() { this.focused = true; }
  }));
  segment.querySelectorAll = () => buttons;
  const document = {
    getElementById: getElement,
    querySelector: getElement,
    querySelectorAll: () => []
  };
  const browser = { storage: { local: { set(value) { saved.push(value); return Promise.resolve(); } } } };
  const context = vm.createContext({ document, browser, URL });
  vm.runInContext(sourceWithoutStartup, context);

  vm.runInContext('state.autoTurnOn = true; state.startupMode = "block"', context);
  vm.runInContext("syncSegmentedControlsFromState()", context);
  assert.equal(buttons[1].tabIndex, 0);
  assert.equal(buttons[1]["aria-checked"], "true");

  vm.runInContext('selectStartupModeFromSegment("off")', context);
  assert.equal(buttons[0]["aria-checked"], "true");
  assert.equal(buttons[0].tabIndex, 0);
  assert.equal(saved.at(-1).autoTurnOn, false);
  assert.equal(saved.at(-1).startupMode, "block");

  vm.runInContext('selectStartupModeFromSegment("allow")', context);
  assert.equal(buttons[2]["aria-checked"], "true");
  assert.equal(buttons[2].tabIndex, 0);
  assert.equal(saved.at(-1).autoTurnOn, true);
  assert.equal(saved.at(-1).startupMode, "allow");

  vm.runInContext('selectStartupModeFromSegment("block")', context);
  assert.equal(buttons[1]["aria-checked"], "true");
  assert.equal(saved.at(-1).startupMode, "block");
});
