#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const swiftSource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "WebViewController.swift"),
  "utf8"
);

assert.match(
  swiftSource,
  /source: Self\.scrollbarScript/,
  "WKWebView must inject the inertial-scroll-safe scrollbar script"
);
assert.doesNotMatch(
  swiftSource,
  /source: Self\.compatibilityScript/,
  "the legacy global touch fallback must not be injected"
);

const declaration = 'private static let scrollbarScript = """';
const scriptStart = swiftSource.indexOf(declaration);
assert.notEqual(scriptStart, -1, "scrollbarScript declaration is missing");

const contentStart = swiftSource.indexOf("\n", scriptStart) + 1;
const contentEnd = swiftSource.indexOf('\n    """', contentStart);
assert.notEqual(contentEnd, -1, "scrollbarScript terminator is missing");

const script = swiftSource
  .slice(contentStart, contentEnd)
  .split("\n")
  .map((line) => line.startsWith("    ") ? line.slice(4) : line)
  .join("\n");

new Function("window", "document", "MutationObserver", script);
assert.doesNotMatch(
  script,
  /document\.addEventListener\(['"]touchmove/,
  "the document must not intercept native touchmove events"
);

function makeElement({
  tagName = "DIV",
  parentElement = null,
  clientHeight = 400,
  clientWidth = 400,
  scrollHeight = 400,
  overflowY = "visible",
  role = ""
} = {}) {
  const attributes = new Map();
  const classes = new Set();
  const listeners = new Map();
  if (role) attributes.set("role", role);

  const element = {
    nodeType: 1,
    tagName,
    parentElement,
    clientHeight,
    clientWidth,
    scrollHeight,
    scrollTop: 0,
    className: "",
    isConnected: true,
    overflowY,
    id: "",
    children: [],
    style: {},
    classList: {
      add(name) {
        classes.add(name);
      },
      remove(name) {
        classes.delete(name);
      },
      contains(name) {
        return classes.has(name);
      }
    },
    appendChild(child) {
      child.parentElement = this;
      child.isConnected = true;
      this.children.push(child);
      return child;
    },
    addEventListener(name, handler, options = {}) {
      const entries = listeners.get(name) || [];
      entries.push({ handler, options });
      listeners.set(name, entries);
    },
    getBoundingClientRect() {
      if (this.id === "gptweb-scrollbar") {
        return {
          top: 80,
          right: 428,
          bottom: 680,
          left: 414,
          width: 14,
          height: 600
        };
      }
      return {
        top: 0,
        right: this.clientWidth,
        bottom: this.clientHeight,
        left: 0,
        width: this.clientWidth,
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
    getRootNode() {
      return { host: null };
    },
    _listeners: listeners
  };

  Object.defineProperty(element, "clientHeight", {
    configurable: true,
    get() {
      return this.id === "gptweb-scrollbar" ? 600 : clientHeight;
    }
  });
  return element;
}

function makeEnvironment(hostname) {
  const documentListeners = new Map();
  const windowListeners = new Map();
  const candidates = [];
  const documentElement = makeElement({
    tagName: "HTML",
    clientHeight: 800,
    clientWidth: 428,
    scrollHeight: 800
  });
  const head = makeElement({
    tagName: "HEAD",
    parentElement: documentElement,
    clientHeight: 0
  });
  const body = makeElement({
    tagName: "BODY",
    parentElement: documentElement,
    clientHeight: 800,
    clientWidth: 428,
    scrollHeight: 800
  });
  documentElement.appendChild(head);
  documentElement.appendChild(body);

  const document = {
    documentElement,
    scrollingElement: documentElement,
    head,
    body,
    createElement(tagName) {
      return makeElement({
        tagName: String(tagName).toUpperCase(),
        clientHeight: 0,
        clientWidth: 14,
        scrollHeight: 0
      });
    },
    addEventListener(name, handler, options = {}) {
      const entries = documentListeners.get(name) || [];
      entries.push({ handler, options });
      documentListeners.set(name, entries);
    },
    querySelectorAll() {
      return candidates;
    }
  };
  const window = {
    location: { hostname },
    innerHeight: 800,
    innerWidth: 428,
    getComputedStyle(element) {
      return { overflowY: element.overflowY };
    },
    requestAnimationFrame(callback) {
      callback();
    },
    setInterval() {
      return 1;
    },
    addEventListener(name, handler, options = {}) {
      const entries = windowListeners.get(name) || [];
      entries.push({ handler, options });
      windowListeners.set(name, entries);
    }
  };
  class MutationObserver {
    constructor(callback) {
      this.callback = callback;
    }
    observe() {}
  }
  return {
    body,
    candidates,
    document,
    documentListeners,
    MutationObserver,
    window,
    windowListeners
  };
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
  blockedEnvironment.documentListeners.size,
  0,
  "scrollbar must stay inactive on third-party documents"
);
assert.equal(
  blockedEnvironment.body.children.length,
  0,
  "third-party documents must not receive the scrollbar"
);

const environment = makeEnvironment("chatgpt.com");
const scroller = makeElement({
  parentElement: environment.body,
  clientHeight: 400,
  clientWidth: 400,
  scrollHeight: 1200,
  overflowY: "hidden",
  role: "main"
});
const message = makeElement({
  parentElement: scroller,
  clientHeight: 120,
  clientWidth: 380,
  scrollHeight: 120
});
environment.body.appendChild(scroller);
scroller.appendChild(message);
environment.candidates.push(scroller);

runScript(environment);

assert.ok(
  environment.documentListeners.has("touchstart"),
  "passive touchstart should select the active nested scroller"
);
assert.equal(
  environment.documentListeners.has("touchmove"),
  false,
  "normal page movement must remain under native WebKit control"
);
const touchstartRegistration = environment.documentListeners.get("touchstart")[0];
assert.equal(
  touchstartRegistration.options.passive,
  true,
  "the page touchstart observer must be passive"
);

const scrollbar = environment.body.children.find(
  (element) => element.id === "gptweb-scrollbar"
);
assert.ok(scrollbar, "right-side scrollbar should be created");
assert.equal(
  scrollbar.classList.contains("gptweb-visible"),
  true,
  "scrollbar should be visible for an overflowing conversation"
);
const thumb = scrollbar.children[0];
assert.equal(thumb.id, "gptweb-scrollbar-thumb");
assert.equal(thumb.style.height, "200px");

let nativePrevented = false;
touchstartRegistration.handler({
  target: message,
  touches: [{ clientX: 200, clientY: 300 }],
  preventDefault() {
    nativePrevented = true;
  }
});
assert.equal(nativePrevented, false, "normal chat gestures must not be cancelled");

function dragEvent(target, y) {
  return {
    target,
    touches: [{ clientX: 422, clientY: y }],
    cancelable: true,
    prevented: false,
    stopped: false,
    preventDefault() {
      this.prevented = true;
    },
    stopPropagation() {
      this.stopped = true;
    }
  };
}

const barTouchstart = scrollbar._listeners.get("touchstart")[0];
const barTouchmove = scrollbar._listeners.get("touchmove")[0];
assert.equal(barTouchstart.options.passive, false);
assert.equal(barTouchmove.options.passive, false);

const start = dragEvent(thumb, 200);
barTouchstart.handler(start);
assert.equal(start.prevented, true, "only scrollbar dragging should cancel touch");

const move = dragEvent(thumb, 400);
barTouchmove.handler(move);
assert.equal(move.prevented, true);
assert.equal(scroller.scrollTop, 400);
assert.equal(
  thumb.style.transform,
  "translate3d(0,200px,0)",
  "thumb position should track the selected scroller"
);

console.log("Native inertial scrolling and draggable scrollbar checks passed.");
