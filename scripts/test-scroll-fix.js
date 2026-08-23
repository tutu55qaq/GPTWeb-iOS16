#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const swiftSource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "WebViewController.swift"),
  "utf8"
);
const appSource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "AppDelegate.swift"),
  "utf8"
);
const browserPolicySource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "BrowserPolicy.swift"),
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
assert.doesNotMatch(
  script,
  /new MutationObserver/,
  "the in-app repair dot must not observe every streamed DOM mutation"
);
assert.match(script, /function cachedScroller\(start, path\)/);
assert.match(script, /event\.composedPath\(\)/);
const findScrollerStart = script.indexOf("function findScroller(start, path)");
const findScrollerEnd = script.indexOf("function ensureDot()", findScrollerStart);
assert.doesNotMatch(
  script.slice(findScrollerStart, findScrollerEnd),
  /fallbackScroller\(/,
  "normal gesture selection must not scan every candidate in the document"
);
assert.match(swiftSource, /load\(BrowserPolicy\.homeURL\)/);
assert.doesNotMatch(swiftSource, /persistCurrentURL/);
assert.doesNotMatch(swiftSource, /Keys\.lastURL/);
assert.match(swiftSource, /webView\.allowsLinkPreview = false/);
assert.match(swiftSource, /webView\.isOpaque = true/);
assert.match(appSource, /removeObject\(\s*forKey: "GPTWeb\.lastFirstPartyURL"/);
assert.doesNotMatch(appSource, /URLCache\.shared/);
assert.doesNotMatch(appSource, /prewarm/);
assert.doesNotMatch(browserPolicySource, /canPersist/);

const manifest = JSON.parse(fs.readFileSync(
  path.join(
    projectRoot,
    "SafariExtension",
    "Resources",
    "manifest.json"
  ),
  "utf8"
));
assert.equal(manifest.manifest_version, 2);
assert.equal(manifest.content_scripts.length, 1);
assert.equal(manifest.content_scripts[0].all_frames, true);
assert.equal(manifest.content_scripts[0].run_at, "document_end");
assert.deepEqual(manifest.content_scripts[0].js, ["content.js"]);
assert.ok(
  manifest.content_scripts[0].matches.includes("https://chatgpt.com/*")
);

const safariScript = fs.readFileSync(
  path.join(
    projectRoot,
    "SafariExtension",
    "Resources",
    "content.js"
  ),
  "utf8"
);
new Function("window", "document", "MutationObserver", safariScript);
for (const marker of [
  "gptweb-work-repair-dot",
  "function repairScroller",
  "data-gptweb-scroll-repaired",
  "'overflow-y', 'auto', 'important'",
  "'touch-action', 'pan-y', 'important'",
  "}, 360);"
]) {
  assert.ok(
    safariScript.includes(marker),
    `Safari content script is missing marker: ${marker}`
  );
}
assert.doesNotMatch(
  safariScript,
  /\.scrollTop\s*=/,
  "the Safari extension must never simulate scrolling"
);

function makeElement({
  tagName = "DIV",
  parentElement = null,
  clientHeight = 400,
  clientWidth = 400,
  scrollHeight = 400,
  overflowY = "visible",
  role = "",
  metrics = null
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
      if (metrics) metrics.layoutReads += 1;
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
  const metrics = {
    layoutReads: 0,
    styleReads: 0,
    selectorScans: 0
  };
  let nextTimer = 1;

  const documentElement = makeElement({
    tagName: "HTML",
    clientHeight: 800,
    clientWidth: 428,
    scrollHeight: 800,
    metrics
  });
  const head = makeElement({
    tagName: "HEAD",
    parentElement: documentElement,
    clientHeight: 0,
    metrics
  });
  const body = makeElement({
    tagName: "BODY",
    parentElement: documentElement,
    clientHeight: 800,
    clientWidth: 428,
    scrollHeight: 800,
    metrics
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
        scrollHeight: 30,
        metrics
      });
    },
    addEventListener(name, handler, options = {}) {
      const entries = documentListeners.get(name) || [];
      entries.push({ handler, options });
      documentListeners.set(name, entries);
    },
    querySelectorAll() {
      metrics.selectorScans += 1;
      return candidates;
    }
  };
  const window = {
    location: { hostname },
    innerHeight: 800,
    innerWidth: 428,
    getComputedStyle(element) {
      metrics.styleReads += 1;
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
    metrics,
    MutationObserver,
    runTimersWithDelay,
    window
  };
}

function runScript(environment, source = script) {
  new Function(
    "window",
    "document",
    "MutationObserver",
    source
  )(environment.window, environment.document, environment.MutationObserver);
}

function dotIn(environment) {
  return environment.body.children.find(
    (element) => element.id === "gptweb-work-repair-dot"
  );
}

function documentTouch(environment, target, x = 200, y = 300) {
  environment.lastTouchTarget = target;
  const registration = environment.documentListeners.get("touchstart")[0];
  registration.handler({
    target,
    touches: [{ clientX: x, clientY: y }]
  });
}

function documentMove(environment, x = 200, y = 260) {
  const registration = environment.documentListeners.get("touchmove")[0];
  registration.handler({
    touches: [{ clientX: x, clientY: y }],
    composedPath() {
      const path = [];
      let node = environment.lastTouchTarget;
      while (node) {
        path.push(node);
        node = node.parentElement;
      }
      return path;
    }
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
  role: "main",
  metrics: workEnvironment.metrics
});
const workClippingLayer = makeElement({
  parentElement: workScroller,
  clientHeight: 420,
  clientWidth: 390,
  scrollHeight: 1200,
  overflowY: "hidden",
  metrics: workEnvironment.metrics
});
const workMessage = makeElement({
  parentElement: workClippingLayer,
  clientHeight: 160,
  clientWidth: 380,
  scrollHeight: 160,
  metrics: workEnvironment.metrics
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

assert.equal(
  dotIn(workEnvironment),
  undefined,
  "the repair dot must not exist before the first vertical gesture"
);

const touchStartMetrics = { ...workEnvironment.metrics };
documentTouch(workEnvironment, workMessage);
assert.deepEqual(
  workEnvironment.metrics,
  touchStartMetrics,
  "touchstart must not read layout, computed style, or scan the document"
);
assert.equal(
  dotIn(workEnvironment),
  undefined,
  "a static tap must not create the repair dot"
);
documentMove(workEnvironment);
const dot = dotIn(workEnvironment);
assert.ok(dot, "the first vertical gesture should lazily create the repair dot");
assert.equal(dot._listeners.get("touchstart")[0].options.passive, false);
assert.equal(dot._listeners.get("touchmove")[0].options.passive, false);
assert.equal(
  dot.classList.contains("gptweb-visible"),
  true,
  "a vertical swipe should reveal the repair dot"
);
assert.equal(
  workEnvironment.metrics.selectorScans,
  0,
  "ordinary scrolling must not run a document-wide candidate scan"
);

const scrollMetrics = { ...workEnvironment.metrics };
workEnvironment.documentListeners.get("scroll")[0].handler({
  target: workScroller
});
assert.deepEqual(
  workEnvironment.metrics,
  scrollMetrics,
  "native scroll events must not force layout or recompute styles"
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
const cachedScrollerMetrics = { ...workEnvironment.metrics };
documentMove(workEnvironment);
assert.deepEqual(
  workEnvironment.metrics,
  cachedScrollerMetrics,
  "an already-selected scroller must be reused without layout reads"
);
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
  role: "main",
  metrics: clippedEnvironment.metrics
});
const clippedMessage = makeElement({
  parentElement: clippedScroller,
  clientHeight: 160,
  clientWidth: 380,
  scrollHeight: 160,
  metrics: clippedEnvironment.metrics
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

const fallbackEnvironment = makeEnvironment("chatgpt.com");
fallbackEnvironment.document.documentElement.scrollHeight = 1400;
const fallbackScroller = makeElement({
  parentElement: fallbackEnvironment.body,
  clientHeight: 500,
  clientWidth: 400,
  scrollHeight: 1900,
  overflowY: "hidden",
  role: "main",
  metrics: fallbackEnvironment.metrics
});
const fallbackTouchTarget = makeElement({
  parentElement: fallbackEnvironment.body,
  clientHeight: 100,
  clientWidth: 100,
  scrollHeight: 100,
  metrics: fallbackEnvironment.metrics
});
fallbackEnvironment.body.appendChild(fallbackScroller);
fallbackEnvironment.body.appendChild(fallbackTouchTarget);
fallbackEnvironment.candidates.push(fallbackScroller);
runScript(fallbackEnvironment);
documentTouch(fallbackEnvironment, fallbackTouchTarget);
documentMove(fallbackEnvironment);
assert.equal(
  fallbackEnvironment.metrics.selectorScans,
  0,
  "a vertical gesture must not run the expensive document-wide fallback"
);
const fallbackDot = dotIn(fallbackEnvironment);
fallbackDot._listeners.get("touchstart")[0].handler(dotEvent(fallbackDot));
assert.equal(
  fallbackEnvironment.metrics.selectorScans,
  0,
  "touching the repair dot must not eagerly scan the document"
);
fallbackEnvironment.runTimersWithDelay(360);
assert.equal(
  fallbackEnvironment.metrics.selectorScans,
  1,
  "the document-wide fallback should run only after the repair long press"
);
assert.equal(
  fallbackScroller.getAttribute("data-gptweb-scroll-repaired"),
  "true",
  "the deferred fallback must still repair the inner Work scroller"
);

const safariEnvironment = makeEnvironment("chatgpt.com");
const safariScroller = makeElement({
  parentElement: safariEnvironment.body,
  clientHeight: 500,
  clientWidth: 400,
  scrollHeight: 1600,
  overflowY: "auto",
  role: "main",
  metrics: safariEnvironment.metrics
});
const safariMessage = makeElement({
  parentElement: safariScroller,
  clientHeight: 120,
  clientWidth: 380,
  scrollHeight: 120,
  metrics: safariEnvironment.metrics
});
safariEnvironment.body.appendChild(safariScroller);
safariScroller.appendChild(safariMessage);
runScript(safariEnvironment, safariScript);
assert.equal(dotIn(safariEnvironment), undefined);
const safariTouchMetrics = { ...safariEnvironment.metrics };
documentTouch(safariEnvironment, safariMessage);
assert.deepEqual(safariEnvironment.metrics, safariTouchMetrics);
documentMove(safariEnvironment);
assert.ok(dotIn(safariEnvironment));

console.log(
  "Lazy Work repair, layout-free touch/scroll paths, target reuse, and Safari parity checks passed."
);
