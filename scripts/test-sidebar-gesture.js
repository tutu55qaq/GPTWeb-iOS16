#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const swiftSource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "WebViewController.swift"),
  "utf8"
);

const declaration = 'private static let sidebarGestureScript = """';
const scriptStart = swiftSource.indexOf(declaration);
assert.notEqual(scriptStart, -1, "sidebarGestureScript declaration is missing");
const contentStart = swiftSource.indexOf("\n", scriptStart) + 1;
const contentEnd = swiftSource.indexOf('\n    """', contentStart);
assert.notEqual(contentEnd, -1, "sidebarGestureScript terminator is missing");
const script = swiftSource
  .slice(contentStart, contentEnd)
  .split("\n")
  .map((line) => line.startsWith("    ") ? line.slice(4) : line)
  .join("\n");

new Function("window", "document", "MouseEvent", "KeyboardEvent", script);

for (const marker of [
  'data-testid="open-sidebar-button"',
  'data-testid="close-sidebar-button"',
  "touch.clientX <= 36",
  "deltaX >= 18",
  "deltaX <= -18",
  "requestIdleCallback",
  "will-change: transform, opacity"
]) {
  assert.ok(script.includes(marker), `sidebar gesture is missing: ${marker}`);
}
assert.doesNotMatch(
  script,
  /preventDefault/,
  "sidebar gestures must not cancel native vertical scrolling"
);
assert.match(
  swiftSource,
  /webView\.allowsBackForwardNavigationGestures = false/
);
assert.match(swiftSource, /source: Self\.sidebarGestureScript/);

const listeners = new Map();
let sidebarOpen = false;
let pointerPrimeCount = 0;

function makeControl(kind) {
  return {
    isConnected: true,
    textContent: kind === "open" ? "Open sidebar" : "Close sidebar",
    getAttribute(name) {
      if (name === "data-testid") return `${kind}-sidebar-button`;
      if (name === "aria-label") return this.textContent;
      if (name === "aria-expanded" && kind === "open") {
        return sidebarOpen ? "true" : "false";
      }
      return null;
    },
    getBoundingClientRect() {
      return {
        top: 20,
        left: 10,
        width: 44,
        height: 44
      };
    },
    click() {
      sidebarOpen = kind === "open";
    },
    dispatchEvent() {
      pointerPrimeCount += 1;
      return true;
    }
  };
}

const openButton = makeControl("open");
const closeButton = makeControl("close");
const sidebar = {
  isConnected: true,
  getBoundingClientRect() {
    return {
      top: 0,
      left: 0,
      width: 320,
      height: 800
    };
  }
};
const head = {
  appendChild() {}
};
const documentElement = {
  appendChild() {}
};
const document = {
  head,
  documentElement,
  createElement() {
    return {
      id: "",
      textContent: ""
    };
  },
  querySelector(selector) {
    if (selector.includes("open-sidebar-button")) return openButton;
    if (selector.includes("close-sidebar-button")) {
      return sidebarOpen ? closeButton : null;
    }
    return null;
  },
  querySelectorAll() {
    return sidebarOpen
      ? [openButton, closeButton]
      : [openButton];
  },
  getElementById(id) {
    return id === "stage-popover-sidebar" && sidebarOpen
      ? sidebar
      : null;
  },
  addEventListener(name, handler, options = {}) {
    listeners.set(name, { handler, options });
  },
  dispatchEvent() {
    sidebarOpen = false;
    return true;
  }
};
const window = {
  location: { hostname: "chatgpt.com" },
  getComputedStyle() {
    return {
      display: "block",
      visibility: "visible"
    };
  },
  requestIdleCallback(callback) {
    callback();
    return 1;
  },
  setTimeout(callback) {
    callback();
    return 1;
  }
};
class MouseEvent {
  constructor(type, options) {
    this.type = type;
    this.options = options;
  }
}
class KeyboardEvent extends MouseEvent {}

new Function(
  "window",
  "document",
  "MouseEvent",
  "KeyboardEvent",
  script
)(window, document, MouseEvent, KeyboardEvent);

for (const name of ["touchstart", "touchmove", "touchend", "touchcancel"]) {
  assert.ok(listeners.has(name), `${name} listener is missing`);
  assert.equal(listeners.get(name).options.passive, true);
}
assert.ok(pointerPrimeCount >= 2, "idle pointer priming did not run");

const pageTarget = {
  closest() {
    return null;
  }
};
function touchEvent(x, y) {
  return {
    target: pageTarget,
    touches: [{ clientX: x, clientY: y }]
  };
}

listeners.get("touchstart").handler(touchEvent(8, 300));
listeners.get("touchmove").handler(touchEvent(30, 302));
assert.equal(sidebarOpen, true, "left-edge right swipe did not open sidebar");

listeners.get("touchstart").handler(touchEvent(300, 300));
listeners.get("touchmove").handler(touchEvent(275, 302));
assert.equal(sidebarOpen, false, "right-to-left swipe did not close sidebar");

listeners.get("touchstart").handler(touchEvent(8, 300));
listeners.get("touchmove").handler(touchEvent(14, 340));
assert.equal(sidebarOpen, false, "vertical scrolling opened the sidebar");

console.log(
  "Sidebar edge-open, swipe-close, priming, and gesture coexistence checks passed."
);
