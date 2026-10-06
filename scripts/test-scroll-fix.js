#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const swiftSource = fs.readFileSync(
  path.join(root, "GPTWeb", "WebViewController.swift"),
  "utf8"
);
const appSource = fs.readFileSync(
  path.join(root, "GPTWeb", "AppDelegate.swift"),
  "utf8"
);
const policySource = fs.readFileSync(
  path.join(root, "GPTWeb", "BrowserPolicy.swift"),
  "utf8"
);
const safariScript = fs.readFileSync(
  path.join(root, "SafariExtension", "Resources", "content.js"),
  "utf8"
);

const declaration = 'private static let automaticScrollRepairScript = """';
const scriptStart = swiftSource.indexOf(declaration);
assert.notEqual(scriptStart, -1, "automaticScrollRepairScript declaration is missing");
const contentStart = swiftSource.indexOf("\n", scriptStart) + 1;
const contentEnd = swiftSource.indexOf('\n    """', contentStart);
assert.notEqual(contentEnd, -1, "automaticScrollRepairScript terminator is missing");
const appScript = swiftSource.slice(contentStart, contentEnd)
  .split("\n")
  .map((line) => line.startsWith("    ") ? line.slice(4) : line)
  .join("\n");

assert.equal(appScript.trim(), safariScript.trim(), "Safari and app fixes must stay identical");
new Function("window", "document", "MutationObserver", appScript);

for (const marker of [
  "source: Self.automaticScrollRepairScript",
  "injectionTime: .atDocumentStart",
  "forMainFrameOnly: false",
  "scheduleAutomaticScrollRepair()",
  "webView.observe(\\.url",
  "window.__gptwebRepairScroll",
  "load(BrowserPolicy.homeURL)",
  "webView.allowsLinkPreview = false",
  "webView.isOpaque = true"
]) {
  assert.ok(swiftSource.includes(marker), "App is missing automatic-repair marker: " + marker);
}

for (const marker of [
  "gptweb-ios16-automatic-scroll-style",
  "data-gptweb-scroll-repaired",
  "function repairScroller",
  "function armRepair",
  "observer.disconnect()",
  "maxAttempts = 12",
  "Date.now() + 2800",
  "candidates.length < 48",
  "DOMContentLoaded",
  "document.elementFromPoint"
]) {
  assert.ok(appScript.includes(marker), "Automatic scroll repair is missing: " + marker);
}

for (const forbidden of [
  /addEventListener\(\s*['"]touchstart['"]/,
  /addEventListener\(\s*['"]touchmove['"]/,
  /addEventListener\(\s*['"]touchend['"]/,
  /addEventListener\(\s*['"]scroll['"]/,
  /\.scrollTop\s*=/,
  /gptweb-work-repair-dot/,
  /sidebarGestureScript/,
  /scrollbarScript/
]) {
  assert.doesNotMatch(appScript, forbidden, "Automatic repair contains forbidden hot-path logic");
  assert.doesNotMatch(safariScript, forbidden, "Safari repair contains forbidden hot-path logic");
}

assert.match(appSource, /removeObject\(\s*forKey: "GPTWeb\.lastFirstPartyURL"/);
assert.doesNotMatch(appSource, /URLCache\.shared|prewarm/);
assert.doesNotMatch(policySource, /canPersist/);

const manifest = JSON.parse(fs.readFileSync(
  path.join(root, "SafariExtension", "Resources", "manifest.json"),
  "utf8"
));
assert.equal(manifest.manifest_version, 2);
assert.equal(manifest.version, "1.2.9");
assert.equal(manifest.content_scripts.length, 1);
assert.equal(manifest.content_scripts[0].run_at, "document_start");
assert.equal(manifest.content_scripts[0].all_frames, true);
assert.deepEqual(manifest.content_scripts[0].js, ["content.js"]);
assert.ok(manifest.content_scripts[0].matches.includes("https://chatgpt.com/*"));

function makeElement(options = {}) {
  const attributes = new Map();
  const metrics = options.metrics;
  if (options.role) attributes.set("role", options.role);
  if (options.scrollRoot) attributes.set("data-scroll-root", "");
  const element = {
    nodeType: 1,
    tagName: options.tagName || "DIV",
    parentElement: options.parentElement || null,
    clientHeight: options.clientHeight || 520,
    clientWidth: options.clientWidth || 400,
    scrollHeight: options.scrollHeight || options.clientHeight || 520,
    scrollTop: options.scrollTop || 0,
    overflowY: options.overflowY || "visible",
    className: options.className || "",
    isConnected: options.isConnected !== false,
    insideSidebar: options.insideSidebar || false,
    children: [],
    style: {
      setProperty(name, value, priority) {
        this[name] = value;
        this[name + ":priority"] = priority;
      }
    },
    appendChild(child) {
      child.parentElement = this;
      child.isConnected = true;
      this.children.push(child);
      return child;
    },
    getAttribute(name) {
      return attributes.has(name) ? attributes.get(name) : null;
    },
    setAttribute(name, value) {
      attributes.set(name, String(value));
    },
    hasAttribute(name) {
      return attributes.has(name);
    },
    getBoundingClientRect() {
      metrics.layoutReads += 1;
      return {
        top: 100,
        left: 20,
        bottom: 100 + this.clientHeight,
        right: 20 + this.clientWidth,
        height: this.clientHeight,
        width: this.clientWidth
      };
    },
    closest(selector) {
      return this.insideSidebar && selector.includes("stage-popover-sidebar")
        ? {}
        : null;
    }
  };
  Object.defineProperty(element, "offsetHeight", {
    get() {
      metrics.layoutFlushes += 1;
      return element.clientHeight;
    }
  });
  return element;
}

function makeEnvironment(options = {}) {
  const metrics = {
    layoutReads: 0,
    layoutFlushes: 0,
    styleReads: 0,
    selectorScans: 0
  };
  const documentListeners = new Map();
  const windowListeners = new Map();
  const timers = new Map();
  const observers = [];
  let nextTimer = 1;
  let now = 10000;

  const documentElement = makeElement({
    tagName: "HTML",
    clientHeight: 844,
    clientWidth: 390,
    scrollHeight: 1044,
    metrics
  });
  const body = makeElement({
    tagName: "BODY",
    parentElement: documentElement,
    clientHeight: 844,
    clientWidth: 390,
    metrics
  });
  const main = makeElement({
    tagName: "MAIN",
    parentElement: body,
    clientHeight: 760,
    clientWidth: 390,
    scrollHeight: 760,
    metrics
  });
  const state = {
    candidates: [],
    focused: null,
    main,
    metrics,
    timers,
    observers,
    documentListeners,
    windowListeners
  };

  class MockMutationObserver {
    constructor(callback) {
      this.callback = callback;
      this.connected = false;
      this.target = null;
      observers.push(this);
    }

    observe(target, configuration) {
      this.target = target;
      this.configuration = configuration;
      this.connected = true;
    }

    disconnect() {
      this.connected = false;
      this.disconnectCount = (this.disconnectCount || 0) + 1;
    }

    trigger() {
      if (this.connected) this.callback([{ type: "childList" }]);
    }
  }

  const document = {
    head: options.noHead ? null : {
      appendChild(child) {
        documentElement.appendChild(child);
      }
    },
    body,
    documentElement,
    scrollingElement: documentElement,
    readyState: options.readyState || "complete",
    hidden: options.hidden || false,
    createElement() {
      return makeElement({ metrics });
    },
    elementFromPoint() {
      return state.focused;
    },
    querySelectorAll() {
      metrics.selectorScans += 1;
      return state.candidates;
    },
    querySelector(selector) {
      return selector === 'main, [role="main"]' ? state.main : null;
    },
    addEventListener(name, handler, configuration) {
      documentListeners.set(name, { handler, configuration });
    }
  };

  const window = {
    location: { hostname: options.hostname || "chatgpt.com", href: 'https://chatgpt.com/' },
    innerWidth: 390,
    innerHeight: 844,
    addEventListener(name, handler, configuration) {
      windowListeners.set(name, { handler, configuration });
    },
    getComputedStyle(element) {
      metrics.styleReads += 1;
      return { overflowY: element.overflowY };
    },
    setTimeout(handler, delay) {
      const identifier = nextTimer++;
      timers.set(identifier, { handler, delay, due: now + delay });
      return identifier;
    },
    clearTimeout(identifier) {
      timers.delete(identifier);
    }
  };

  state.document = document;
  state.window = window;
  state.MutationObserver = MockMutationObserver;
  state.Date = { now: () => now };
  state.advance = (milliseconds) => { now += milliseconds; };
  state.runNextTimer = function runNextTimer() {
    const entry = [...timers.entries()].sort(
      (left, right) => left[1].due - right[1].due
    )[0];
    if (!entry) return false;
    timers.delete(entry[0]);
    now = Math.max(now, entry[1].due);
    entry[1].handler();
    return true;
  };
  state.makeElement = (elementOptions) => makeElement({
    ...elementOptions,
    metrics
  });
  return state;
}

function install(environment, script = appScript) {
  new Function("window", "document", "MutationObserver", "Date", script)(
    environment.window,
    environment.document,
    environment.MutationObserver,
    environment.Date
  );
}

function createWorkScroller(environment, options = {}) {
  const scroller = environment.makeElement({
    parentElement: options.parentElement || environment.main,
    clientHeight: options.clientHeight || 570,
    clientWidth: 370,
    scrollHeight: options.scrollHeight || 2240,
    scrollTop: options.scrollTop || 145,
    overflowY: options.overflowY || "auto",
    className: options.className || "overflow-y-auto conversation-thread",
    scrollRoot: options.scrollRoot !== false,
    role: options.role || ""
  });
  const message = environment.makeElement({
    parentElement: scroller,
    clientHeight: 80,
    clientWidth: 350,
    scrollHeight: 80
  });
  environment.candidates = [scroller, environment.main];
  environment.focused = message;
  return scroller;
}

const immediate = makeEnvironment({ noHead: true });
const clippingLayer = immediate.makeElement({
  parentElement: immediate.main,
  clientHeight: 690,
  clientWidth: 390,
  scrollHeight: 1890,
  overflowY: "hidden",
  className: "overflow-hidden"
});
const workScroller = createWorkScroller(immediate, {
  parentElement: clippingLayer,
  scrollTop: 211
});
immediate.candidates.unshift(clippingLayer);
install(immediate);

assert.equal(workScroller.getAttribute("data-gptweb-scroll-repaired"), "true");
assert.equal(workScroller.style["overflow-y"], "auto");
assert.equal(workScroller.style["-webkit-overflow-scrolling"], "auto");
assert.equal(workScroller.style["overscroll-behavior-y"], "contain");
assert.equal(workScroller.style["touch-action"], "pan-y");
assert.equal(workScroller.style["min-height"], "0");
assert.equal(workScroller.style["overflow-y:priority"], "important");
assert.equal(workScroller.scrollTop, 211, "Automatic repair modified native scroll position");
assert.equal(clippingLayer.getAttribute("data-gptweb-scroll-repaired"), null);
assert.equal(immediate.metrics.layoutFlushes, 1);
assert.equal(immediate.observers.length, 0, "Ready Work content must not create an observer");
assert.equal(immediate.timers.size, 0);
assert.equal(
  immediate.document.documentElement.children[0].id,
  "gptweb-ios16-automatic-scroll-style"
);

for (const forbidden of ["touchstart", "touchmove", "touchend", "scroll"]) {
  assert.equal(immediate.documentListeners.has(forbidden), false);
  assert.equal(immediate.windowListeners.has(forbidden), false);
}

const flushesBeforeReuse = immediate.metrics.layoutFlushes;
const metricsBeforeReuse = { ...immediate.metrics };
immediate.window.__gptwebRepairScroll();
immediate.windowListeners.get('pageshow').handler({ persisted: false });
assert.deepEqual(immediate.metrics, metricsBeforeReuse,
  'Duplicate startup triggers must perform zero DOM/layout work');
assert.equal(immediate.metrics.selectorScans, 0,
  'Recognized visible scroller should skip global selector fallback');
assert.equal(immediate.metrics.layoutFlushes, flushesBeforeReuse);

workScroller.isConnected = false;
const replacement = createWorkScroller(immediate, { overflowY: "hidden" });
immediate.window.__gptwebRepairScroll();
assert.equal(replacement.getAttribute("data-gptweb-scroll-repaired"), "true");
assert.equal(immediate.metrics.layoutFlushes, flushesBeforeReuse + 1);

const loading = makeEnvironment({ readyState: "loading" });
const loadingScroller = createWorkScroller(loading);
install(loading);
assert.equal(loadingScroller.getAttribute("data-gptweb-scroll-repaired"), null);
assert.equal(loading.metrics.selectorScans, 0);
assert.equal(loading.documentListeners.get("DOMContentLoaded").configuration.once, true);
loading.document.readyState = 'interactive';
loading.documentListeners.get("DOMContentLoaded").handler();
assert.equal(loadingScroller.getAttribute("data-gptweb-scroll-repaired"), "true");

const delayed = makeEnvironment();
install(delayed);
assert.equal(delayed.observers.length, 1);
assert.equal(delayed.observers[0].target, delayed.main);
assert.equal(delayed.observers[0].configuration.subtree, true);
const delayedScroller = createWorkScroller(delayed, { overflowY: "clip" });
delayed.observers[0].trigger();
assert.equal(delayed.runNextTimer(), true);
assert.equal(delayedScroller.getAttribute("data-gptweb-scroll-repaired"), "true");
assert.equal(delayed.observers[0].connected, false);
assert.equal(delayed.timers.size, 0, "Successful repair must cancel every pending retry");

const empty = makeEnvironment();
install(empty);
let retries = 0;
while (empty.runNextTimer()) {
  retries += 1;
  assert.ok(retries <= 12, "Observer retries were not bounded");
}
assert.equal(empty.metrics.selectorScans, 5);
assert.equal(empty.observers[0].connected, false);
assert.equal(empty.timers.size, 0);

// Frequent streaming mutations and duplicate navigation notifications cannot
// increase polling frequency or keep an empty-page observer alive forever.
const busy = makeEnvironment();
install(busy);
for (let frame = 0; frame < 100; frame++) {
  busy.observers[0].trigger();
  busy.window.__gptwebRepairScroll();
}
assert.equal(busy.timers.size, 1);
assert.equal(busy.metrics.selectorScans, 1);
while (busy.runNextTimer()) {
  busy.observers[0].trigger();
  if (busy.timers.size) busy.window.__gptwebRepairScroll();
}
assert.equal(busy.metrics.selectorScans, 5);
assert.equal(busy.observers[0].connected, false);

const hidden = makeEnvironment({ hidden: true });
install(hidden);
assert.equal(hidden.metrics.selectorScans, 0);
assert.equal(hidden.timers.size, 0);
hidden.document.hidden = false;
hidden.documentListeners.get('visibilitychange').handler();
assert.equal(hidden.timers.size, 1);
hidden.document.hidden = true;
hidden.documentListeners.get('visibilitychange').handler();
assert.equal(hidden.timers.size, 0);
assert.equal(hidden.observers[0].connected, false);

// A new URL must invalidate the short cache even if React retains the old node.
const routed = makeEnvironment();
createWorkScroller(routed);
install(routed);
routed.window.location.href = 'https://chatgpt.com/c/another';
const nextScroller = createWorkScroller(routed);
routed.window.__gptwebRepairScroll();
assert.equal(nextScroller.getAttribute('data-gptweb-scroll-repaired'), 'true');
// Same-URL replacement after the coalescing window remains repairable.
routed.advance(501);
const sameURLScroller = createWorkScroller(routed);
routed.window.__gptwebRepairScroll();
assert.equal(sameURLScroller.getAttribute('data-gptweb-scroll-repaired'), 'true');

const fallback = makeEnvironment();
const offProbeScroller = createWorkScroller(fallback);
fallback.focused = null;
install(fallback);
assert.equal(offProbeScroller.getAttribute('data-gptweb-scroll-repaired'), 'true');
assert.equal(fallback.metrics.selectorScans, 1);

const excluded = makeEnvironment({ hostname: "example.com" });
install(excluded);
assert.equal(excluded.document.documentElement.children.length, 0);
assert.equal(excluded.metrics.selectorScans, 0);

const safari = makeEnvironment();
const safariScroller = createWorkScroller(safari);
install(safari, safariScript);
assert.equal(safariScroller.getAttribute("data-gptweb-scroll-repaired"), "true");
assert.equal(safari.metrics.layoutFlushes, 1);
assert.equal(safari.timers.size, 0);

console.log(
  "Automatic one-shot Work repair, bounded DOM observation, native inertia, " +
  "document_start iframe coverage, zero touch/scroll hooks, and Safari parity passed."
);
