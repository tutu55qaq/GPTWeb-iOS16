#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const source = fs.readFileSync(
  path.join(__dirname, "..", "GPTWeb", "WebViewController.swift"),
  "utf8"
);

function extractScript(name) {
  const declaration = 'private static let ' + name + ' = """';
  const start = source.indexOf(declaration);
  assert.notEqual(start, -1, name + " declaration is missing");
  const contentStart = source.indexOf("\n", start) + 1;
  const end = source.indexOf('\n    """', contentStart);
  assert.notEqual(end, -1, name + " terminator is missing");
  return source.slice(contentStart, end)
    .split("\n")
    .map((line) => line.startsWith("    ") ? line.slice(4) : line)
    .join("\n");
}

const openScript = extractScript("openSidebarScript");
const closeScript = extractScript("closeSidebarScript");

for (const marker of [
  "UIScreenEdgePanGestureRecognizer",
  "UIPanGestureRecognizer",
  "configureNativeSidebarGestures()",
  "openGesture.edges = .left",
  "openGesture.cancelsTouchesInView = false",
  "closeGesture.cancelsTouchesInView = false",
  "closeGesture.maximumNumberOfTouches = 1",
  "horizontalDistance >= 18",
  "abs(translation.y) * 1.35",
  "velocity.x > 0",
  "velocity.x < 0",
  "shouldRecognizeSimultaneouslyWith",
  "opening ? Self.openSidebarScript : Self.closeSidebarScript",
  "webView.allowsBackForwardNavigationGestures = false"
]) {
  assert.ok(source.includes(marker), "Native sidebar gesture is missing: " + marker);
}

assert.doesNotMatch(source, /sidebarGestureScript/);
assert.doesNotMatch(source, /source:\s*Self\.openSidebarScript/);
assert.doesNotMatch(source, /source:\s*Self\.closeSidebarScript/);

for (const script of [openScript, closeScript]) {
  new Function("document", script);
  assert.doesNotMatch(script, /addEventListener/);
  assert.doesNotMatch(script, /preventDefault/);
  assert.doesNotMatch(script, /getBoundingClientRect|getComputedStyle/);
  assert.doesNotMatch(script, /querySelectorAll/);
}

let sidebarOpen = false;
let selectorReads = 0;

const openButton = {
  disabled: false,
  click() {
    sidebarOpen = true;
  }
};

const closeButton = {
  disabled: false,
  click() {
    sidebarOpen = false;
  }
};

const sidebar = {
  querySelector() {
    return closeButton;
  }
};

const document = {
  querySelector(selector) {
    selectorReads += 1;
    if (selector.includes("open-sidebar-button")) return openButton;
    if (selector.includes("close-sidebar-button")) {
      return sidebarOpen ? closeButton : null;
    }
    return null;
  },
  getElementById(id) {
    return id === "stage-popover-sidebar" && sidebarOpen ? sidebar : null;
  }
};

const open = new Function("document", "return " + openScript);
const close = new Function("document", "return " + closeScript);

assert.equal(open(document), true);
assert.equal(sidebarOpen, true, "Native left-edge gesture command did not open the sidebar");
assert.equal(close(document), true);
assert.equal(sidebarOpen, false, "Native left-swipe command did not close the sidebar");

const settledReads = selectorReads;
assert.equal(close(document), false);
assert.equal(sidebarOpen, false);
assert.ok(selectorReads - settledReads <= 2);

openButton.disabled = true;
assert.equal(open(document), false);
assert.equal(sidebarOpen, false);

console.log(
  "Native UIKit sidebar gestures, direction gating, one-shot DOM commands, " +
  "and zero webpage touch listeners passed."
);
