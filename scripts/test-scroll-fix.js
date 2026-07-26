#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const swiftSource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "WebViewController.swift"),
  "utf8"
);

assert.match(swiftSource, /source: Self\.scrollbarScript/);
assert.doesNotMatch(swiftSource, /source: Self\.compatibilityScript/);

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
assert.match(script, /'  background: transparent;'/);
assert.match(script, /'  border: 0;'/);
assert.match(script, /'  background: #0a84ff;'/);
assert.match(script, /gptweb-interactive/);
assert.match(script, /longPressTimer/);

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
          left: 406,
          width: 22,
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
  const timers = new Map();
  let nextTimer = 1;
  let nextFrame = 1;

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
        clientWidth: 22,
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
      return nextFrame++;
    },
    cancelAnimationFrame() {},
    setTimeout(callback, delay) {
      const id = nextTimer++;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
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
    timers,
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

function scrollbarIn(environment) {
  return environment.body.children.find(
    (element) => element.id === "gptweb-scrollbar"
  );
}

function documentTouch(environment, target, x = 200, y = 300) {
  const registration = environment.documentListeners.get("touchstart")[0];
  let prevented = false;
  registration.handler({
    target,
    touches: [{ clientX: x, clientY: y }],
    preventDefault() {
      prevented = true;
    }
  });
  return prevented;
}

function documentMove(environment, x = 200, y = 260) {
  const registration = environment.documentListeners.get("touchmove")[0];
  let prevented = false;
  registration.handler({
    touches: [{ clientX: x, clientY: y }],
    preventDefault() {
      prevented = true;
    }
  });
  return prevented;
}

function barEvent(target, y) {
  return {
    target,
    touches: [{ clientX: 420, clientY: y }],
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
assert.equal(blockedEnvironment.body.children.length, 0);

const environment = makeEnvironment("chatgpt.com");
const scroller = makeElement({
  parentElement: environment.body,
  clientHeight: 400,
  clientWidth: 400,
  scrollHeight: 1200,
  overflowY: "auto",
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

assert.ok(environment.documentListeners.has("touchstart"));
assert.equal(
  environment.documentListeners.get("touchstart")[0].options.passive,
  true
);
assert.equal(
  environment.documentListeners.get("touchmove")[0].options.passive,
  true,
  "the movement detector must be passive"
);

const scrollbar = scrollbarIn(environment);
const thumb = scrollbar.children[0];
assert.ok(scrollbar, "scrollbar should exist as an invisible local control");
assert.equal(scrollbar.classList.contains("gptweb-visible"), false);
assert.equal(scrollbar.classList.contains("gptweb-interactive"), false);

assert.equal(
  documentTouch(environment, message),
  false,
  "observing a native chat gesture must remain passive"
);
assert.equal(
  scrollbar.classList.contains("gptweb-visible"),
  false,
  "a static tap must not reveal the thumb"
);
assert.equal(
  documentMove(environment),
  false,
  "revealing the thumb must not cancel native momentum scrolling"
);
assert.equal(scrollbar.classList.contains("gptweb-visible"), true);
assert.equal(scrollbar.classList.contains("gptweb-interactive"), true);
assert.equal(thumb.style.height, "200px");

const startNormal = barEvent(thumb, 300);
scrollbar._listeners.get("touchstart")[0].handler(startNormal);
assert.equal(startNormal.prevented, true);
const moveNormal = barEvent(thumb, 200);
scrollbar._listeners.get("touchmove")[0].handler(moveNormal);
assert.equal(scroller.scrollTop, 100, "short strip swipe should scroll one-to-one");
scrollbar._listeners.get("touchcancel")[0].handler({
  cancelable: true,
  preventDefault() {},
  stopPropagation() {}
});

const outerEnvironment = makeEnvironment("chatgpt.com");
const outerShell = makeElement({
  parentElement: outerEnvironment.body,
  clientHeight: 700,
  clientWidth: 428,
  scrollHeight: 1000,
  overflowY: "auto",
  role: "main"
});
outerEnvironment.body.appendChild(outerShell);
outerEnvironment.candidates.push(outerShell);
runScript(outerEnvironment);
const outerScrollbar = scrollbarIn(outerEnvironment);
assert.equal(outerScrollbar.classList.contains("gptweb-interactive"), false);

const workEnvironment = makeEnvironment("chatgpt.com");
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

const workScrollbar = scrollbarIn(workEnvironment);
const workThumb = workScrollbar.children[0];
documentTouch(workEnvironment, workMessage);
assert.equal(workScrollbar.classList.contains("gptweb-interactive"), false);
documentMove(workEnvironment);
assert.equal(workScrollbar.classList.contains("gptweb-interactive"), true);
assert.equal(
  outerScrollbar.classList.contains("gptweb-interactive"),
  false,
  "an untouched outer frame must not cover the active Work frame strip"
);

const fastStart = barEvent(workThumb, 200);
workScrollbar._listeners.get("touchstart")[0].handler(fastStart);
workEnvironment.runTimersWithDelay(360);
assert.equal(
  workScrollbar.classList.contains("gptweb-fast"),
  true,
  "stationary long press should enter fast-scroll mode"
);
const fastMove = barEvent(workThumb, 400);
workScrollbar._listeners.get("touchmove")[0].handler(fastMove);
assert.ok(workScroller.scrollTop > 500);
assert.equal(
  workClippingLayer.scrollTop,
  0,
  "Work scrolling must target the native parent, not its hidden clipping layer"
);
workScrollbar._listeners.get("touchend")[0].handler({
  cancelable: true,
  preventDefault() {},
  stopPropagation() {}
});
workEnvironment.runTimersWithDelay(1400);
assert.equal(workScrollbar.classList.contains("gptweb-visible"), false);
assert.equal(workScrollbar.classList.contains("gptweb-interactive"), false);

console.log(
  "Work targeting, auto-hide, strip swipe, and long-press fast scroll checks passed."
);
