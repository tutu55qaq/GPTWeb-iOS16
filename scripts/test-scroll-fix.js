#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const swiftSource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "WebViewController.swift"),
  "utf8"
);

assert.match(swiftSource, /source: Self\.workRepairDotScript/);
assert.doesNotMatch(swiftSource, /source: Self\.compatibilityScript/);
assert.doesNotMatch(swiftSource, /source: Self\.scrollbarScript/);

const declaration = 'private static let workRepairDotScript = """';
const scriptStart = swiftSource.indexOf(declaration);
assert.notEqual(scriptStart, -1, "workRepairDotScript declaration is missing");
const contentStart = swiftSource.indexOf("\n", scriptStart) + 1;
const contentEnd = swiftSource.indexOf('\n    """', contentStart);
assert.notEqual(contentEnd, -1, "workRepairDotScript terminator is missing");
const script = swiftSource
  .slice(contentStart, contentEnd)
  .split("\n")
  .map((line) => line.startsWith("    ") ? line.slice(4) : line)
  .join("\n");

new Function("window", "document", "MutationObserver", script);
assert.match(script, /gptweb-work-repair-dot/);
assert.match(script, /'  width: 9px;'/);
assert.match(script, /'  height: 9px;'/);
assert.match(script, /'  background: #0a84ff;'/);
assert.match(script, /function repairScroller/);
assert.match(script, /data-gptweb-scroll-repaired/);
assert.match(script, /}, 360\);/);
assert.doesNotMatch(
  script,
  /\.scrollTop\s*=/,
  "the repair dot must never simulate scrolling"
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
  const priorities = new Map();
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
    style: {
      setProperty(name, value, priority = "") {
        this[name] = value;
        priorities.set(name, priority);
      },
      getPropertyValue(name) {
        return this[name] || "";
      },
      getPropertyPriority(name) {
        return priorities.get(name) || "";
      },
      removeProperty(name) {
        const value = this[name] || "";
        delete this[name];
        priorities.delete(name);
        return value;
      }
    },
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
      if (this.id === "gptweb-work-repair-dot") {
        return {
          top: 56,
          right: 428,
          bottom: 86,
          left: 398,
          width: 30,
          height: 30
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
  return element;
}

function makeEnvironment(hostname) {
  const documentListeners = new Map();
  const candidates = [];
  const timers = new Map();
  let nextTimer = 1;

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
        clientHeight: 30,
        clientWidth: 30,
        scrollHeight: 30
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
      return { overflowY: element.style["overflow-y"] || element.overflowY };
    },
    setTimeout(callback, delay) {
      const id = nextTimer++;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    }
  };
  class MutationObserver {
    constructor(callback) {
      this.callback = callback;
    }
    observe() {}
  }

  function runTimersWithDelay(delay) {
    const ready = [...timers.entries()]
      .filter(([, timer]) => timer.delay === delay);
    for (const [id, timer] of ready) {
      timers.delete(id);
      timer.callback();
    }
  }

  return {
    body,
    candidates,
    document,
    documentListeners,
    MutationObserver,
    runTimersWithDelay,
    window
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

function dotIn(environment) {
  return environment.body.children.find(
    (element) => element.id === "gptweb-work-repair-dot"
  );
}

function documentTouch(environment, target, x = 200, y = 300) {
  const registration = environment.documentListeners.get("touchstart")[0];
  registration.handler({
    target,
    touches: [{ clientX: x, clientY: y }]
  });
}

function documentMove(environment, x = 200, y = 260) {
  const registration = environment.documentListeners.get("touchmove")[0];
  registration.handler({
    touches: [{ clientX: x, clientY: y }]
  });
}

function dotEvent(target, x = 413, y = 71) {
  return {
    target,
    touches: [{ clientX: x, clientY: y }],
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

const blockedEnvironment = makeEnvironment("example.com");
runScript(blockedEnvironment);
assert.equal(blockedEnvironment.documentListeners.size, 0);
assert.equal(dotIn(blockedEnvironment), undefined);

const workEnvironment = makeEnvironment("chatgpt.com");
workEnvironment.document.documentElement.scrollHeight = 1200;
const workScroller = makeElement({
  parentElement: workEnvironment.body,
  clientHeight: 500,
  clientWidth: 400,
  scrollHeight: 2500,
  overflowY: "auto",
  role: "main"
});
const workClippingLayer = makeElement({
  parentElement: workScroller,
  clientHeight: 420,
  clientWidth: 390,
  scrollHeight: 1200,
  overflowY: "hidden"
});
const workMessage = makeElement({
  parentElement: workClippingLayer,
  clientHeight: 160,
  clientWidth: 380,
  scrollHeight: 160
});
workEnvironment.body.appendChild(workScroller);
workScroller.appendChild(workClippingLayer);
workClippingLayer.appendChild(workMessage);
workEnvironment.candidates.push(workClippingLayer, workScroller);
runScript(workEnvironment);

assert.ok(workEnvironment.documentListeners.has("touchstart"));
assert.equal(
  workEnvironment.documentListeners.get("touchstart")[0].options.passive,
  true
);
assert.equal(
  workEnvironment.documentListeners.get("touchmove")[0].options.passive,
  true,
  "the vertical gesture detector must remain passive"
);

const dot = dotIn(workEnvironment);
assert.ok(dot, "the local repair dot should be installed");
assert.equal(dot.classList.contains("gptweb-visible"), false);
assert.equal(dot._listeners.get("touchstart")[0].options.passive, false);
assert.equal(dot._listeners.get("touchmove")[0].options.passive, false);

documentTouch(workEnvironment, workMessage);
assert.equal(
  dot.classList.contains("gptweb-visible"),
  false,
  "a static tap must not reveal the repair dot"
);
documentMove(workEnvironment);
assert.equal(
  dot.classList.contains("gptweb-visible"),
  true,
  "a vertical swipe should reveal the repair dot"
);

workEnvironment.documentListeners.get("scroll")[0].handler({
  target: workEnvironment.document
});

const initialScrollTop = workScroller.scrollTop;
const pressStart = dotEvent(dot);
dot._listeners.get("touchstart")[0].handler(pressStart);
assert.equal(pressStart.prevented, true);
assert.equal(pressStart.stopped, true);
assert.equal(dot.classList.contains("gptweb-pressing"), true);

workEnvironment.runTimersWithDelay(360);
assert.equal(
  workScroller.getAttribute("data-gptweb-scroll-repaired"),
  "true",
  "long pressing the dot must repair the selected Work scroller"
);
assert.equal(workScroller.style["overflow-y"], "auto");
assert.equal(workScroller.style["-webkit-overflow-scrolling"], "auto");
assert.equal(workScroller.style["overscroll-behavior-y"], "contain");
assert.equal(workScroller.style["touch-action"], "pan-y");
assert.equal(workScroller.style["min-height"], "0");
assert.equal(workScroller.style.getPropertyPriority("touch-action"), "important");
assert.equal(dot.classList.contains("gptweb-repaired"), true);
assert.equal(workScroller.scrollTop, initialScrollTop);
assert.equal(workEnvironment.document.documentElement.scrollTop, 0);
assert.equal(workClippingLayer.getAttribute("data-gptweb-scroll-repaired"), null);

const pressEnd = dotEvent(dot);
pressEnd.touches = [];
dot._listeners.get("touchend")[0].handler(pressEnd);
workEnvironment.runTimersWithDelay(320);
assert.equal(dot.classList.contains("gptweb-visible"), false);

documentTouch(workEnvironment, workMessage);
documentMove(workEnvironment);
assert.equal(
  dot.classList.contains("gptweb-visible"),
  false,
  "a repaired Work scroller must continue with native scrolling"
);

const clippedEnvironment = makeEnvironment("chatgpt.com");
const clippedScroller = makeElement({
  parentElement: clippedEnvironment.body,
  clientHeight: 500,
  clientWidth: 400,
  scrollHeight: 1800,
  overflowY: "clip",
  role: "main"
});
const clippedMessage = makeElement({
  parentElement: clippedScroller,
  clientHeight: 160,
  clientWidth: 380,
  scrollHeight: 160
});
clippedEnvironment.body.appendChild(clippedScroller);
clippedScroller.appendChild(clippedMessage);
clippedEnvironment.candidates.push(clippedScroller);
runScript(clippedEnvironment);
documentTouch(clippedEnvironment, clippedMessage);
documentMove(clippedEnvironment);
const clippedDot = dotIn(clippedEnvironment);
clippedDot._listeners.get("touchstart")[0].handler(dotEvent(clippedDot));
clippedEnvironment.runTimersWithDelay(360);
assert.equal(
  clippedScroller.style["overflow-y"],
  "auto",
  "the long press must persistently repair a clipped Work scroller"
);
assert.equal(
  clippedScroller.getAttribute("data-gptweb-scroll-repaired"),
  "true"
);

console.log(
  "Work repair dot visibility, target locking, and native-scroll handoff checks passed."
);
