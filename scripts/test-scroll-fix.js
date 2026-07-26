#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const swiftSource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "WebViewController.swift"),
  "utf8"
);
const declaration = 'private static let compatibilityScript = """';
const scriptStart = swiftSource.indexOf(declaration);
assert.notEqual(scriptStart, -1, "compatibilityScript declaration is missing");

const contentStart = swiftSource.indexOf("\n", scriptStart) + 1;
const contentEnd = swiftSource.indexOf('\n    """', contentStart);
assert.notEqual(contentEnd, -1, "compatibilityScript terminator is missing");

const script = swiftSource
  .slice(contentStart, contentEnd)
  .split("\n")
  .map((line) => line.startsWith("    ") ? line.slice(4) : line)
  .join("\n");

new Function("window", "document", "MutationObserver", script);

function makeStyle() {
  const values = new Map();
  return {
    setProperty(name, value) {
      values.set(name, value);
    },
    get(name) {
      return values.get(name);
    }
  };
}

function makeElement({
  tagName = "DIV",
  parentElement = null,
  clientHeight = 400,
  scrollHeight = 400,
  overflowY = "visible",
  role = ""
} = {}) {
  const attributes = new Map();
  if (role) attributes.set("role", role);

  const element = {
    nodeType: 1,
    tagName,
    parentElement,
    clientHeight,
    scrollHeight,
    scrollTop: 0,
    className: "",
    isConnected: true,
    overflowY,
    style: makeStyle(),
    get offsetHeight() {
      return this.clientHeight;
    },
    getBoundingClientRect() {
      return {
        top: 0,
        right: 400,
        bottom: this.clientHeight,
        left: 0,
        width: 400,
        height: this.clientHeight
      };
    },
    getAttribute(name) {
      return attributes.get(name) || null;
    },
    hasAttribute(name) {
      return attributes.has(name);
    },
    setAttribute(name, value) {
      attributes.set(name, value);
    },
    contains(candidate) {
      let node = candidate;
      while (node) {
        if (node === this) return true;
        node = node.parentElement;
      }
      return false;
    },
    closest() {
      return null;
    },
    getRootNode() {
      return { host: null };
    }
  };
  return element;
}

function makeEnvironment(hostname) {
  const listeners = new Map();
  const documentElement = makeElement({
    tagName: "HTML",
    clientHeight: 800,
    scrollHeight: 800
  });
  const head = {
    appendChild() {}
  };
  const document = {
    documentElement,
    scrollingElement: documentElement,
    head,
    createElement() {
      return { id: "", textContent: "" };
    },
    addEventListener(name, handler) {
      listeners.set(name, handler);
    },
    querySelectorAll() {
      return [];
    }
  };
  const window = {
    location: { hostname },
    innerHeight: 800,
    innerWidth: 428,
    scrollX: 0,
    scrollY: 0,
    getComputedStyle(element) {
      return {
        overflowY: element.style.get("overflow-y") || element.overflowY
      };
    },
    requestAnimationFrame(callback) {
      callback();
    },
    scrollTo(x, y) {
      this.scrollX = x;
      this.scrollY = y;
    }
  };
  class MutationObserver {
    observe() {}
  }
  return { document, listeners, MutationObserver, window };
}

function runScript(environment) {
  new Function(
    "window",
    "document",
    "MutationObserver",
    script
  )(environment.window, environment.document, environment.MutationObserver);
}

const blockedEnvironment = makeEnvironment("example.com");
runScript(blockedEnvironment);
assert.equal(
  blockedEnvironment.listeners.size,
  0,
  "scroll compatibility must stay inactive on third-party documents"
);

const environment = makeEnvironment("chatgpt.com");
const scroller = makeElement({
  parentElement: environment.document.documentElement,
  clientHeight: 400,
  scrollHeight: 1200,
  overflowY: "hidden",
  role: "main"
});
const message = makeElement({
  parentElement: scroller,
  clientHeight: 120,
  scrollHeight: 120
});

runScript(environment);
assert.ok(environment.listeners.has("touchstart"));
assert.ok(environment.listeners.has("touchmove"));

environment.listeners.get("touchstart")({
  target: message,
  touches: [{ clientX: 200, clientY: 300 }]
});

function move(y) {
  let prevented = false;
  environment.listeners.get("touchmove")({
    target: message,
    touches: [{ clientX: 200, clientY: y }],
    preventDefault() {
      prevented = true;
    },
    stopPropagation() {}
  });
  return prevented;
}

assert.equal(move(260), false, "first move allows native WebKit scrolling");
assert.equal(move(220), true, "second stalled move enables manual fallback");
assert.equal(scroller.scrollTop, 40);
assert.equal(scroller.getAttribute("data-gptweb-scroll-fix"), "true");
assert.equal(scroller.style.get("overflow-y"), "auto");

console.log("iOS 16 scroll compatibility checks passed.");
