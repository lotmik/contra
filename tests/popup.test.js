const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

test("blocked phrase renders per-character feedback and a custom caret", () => {
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
        classList: { toggle() {}, add() {}, remove() {} },
        blur() {}
      });
    }
    return elements.get(id);
  };
  const display = getElement("unlock-phrase-display");
  display.children = [];
  display.replaceChildren = (fragment) => { display.children = fragment.children; };
  display.querySelector = (selector) => {
    if (selector === ".typing-char:last-of-type") return display.children.at(-1);
    const match = selector.match(/data-(start|end)="(\d+)"/);
    return match ? display.children.find((node) => node.dataset[match[1]] === match[2]) : null;
  };
  display.getBoundingClientRect = () => ({ left: 0, top: 0 });
  const document = {
    body: getElement("body"),
    getElementById: getElement,
    querySelector: getElement,
    querySelectorAll: () => [],
    createElement() {
      return {
        dataset: {},
        getBoundingClientRect() {
          const left = Number(this.dataset.start) * 8;
          return { left, right: left + 8, top: 0, height: 20 };
        }
      };
    },
    createDocumentFragment() {
      return { children: [], appendChild(node) { this.children.push(node); } };
    }
  };
  const context = vm.createContext({ document, URL, getComputedStyle: () => ({ lineHeight: "20px" }) });
  vm.runInContext(sourceWithoutStartup, context);
  const input = getElement("unlock-phrase-input");
  const caret = getElement("unlock-phrase-caret");
  vm.runInContext('state.unlockPhrase = "cat dog"', context);
  input.value = "cat dXg";
  input.selectionStart = input.value.length;
  vm.runInContext("renderPhraseTypingPreview()", context);
  assert.equal(display.children.map((node) => node.textContent).join(""), "cat dog");
  assert.equal(display.children[5].className, "typing-char incorrect");
  assert.equal(display.children[6].className, "typing-char correct");
  assert.equal(caret.hidden, false);
  assert.match(caret.style.transform, /^translate\(/);
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
