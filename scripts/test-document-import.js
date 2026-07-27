#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const swiftSource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "WebViewController.swift"),
  "utf8"
);
const sceneSource = fs.readFileSync(
  path.join(projectRoot, "GPTWeb", "SceneDelegate.swift"),
  "utf8"
);

function extractSwiftMultilineString(name) {
  const declaration = `private static let ${name} = """`;
  const start = swiftSource.indexOf(declaration);
  assert.notEqual(start, -1, `${name} declaration is missing`);
  const contentStart = swiftSource.indexOf("\n", start) + 1;
  const contentEnd = swiftSource.indexOf('\n    """', contentStart);
  assert.notEqual(contentEnd, -1, `${name} terminator is missing`);
  return swiftSource
    .slice(contentStart, contentEnd)
    .split("\n")
    .map((line) => line.startsWith("    ") ? line.slice(4) : line)
    .join("\n");
}

const availabilityScript = extractSwiftMultilineString(
  "uploadInputAvailabilityScript"
);
const finalizeScript = extractSwiftMultilineString(
  "finalizeIncomingUploadScript"
);

new Function("window", "document", "DataTransfer", "File", "Blob", availabilityScript);
new Function(
  "window",
  "document",
  "DataTransfer",
  "File",
  "Blob",
  "Uint8Array",
  "Event",
  finalizeScript
);

for (const marker of [
  "new DataTransfer()",
  "new File([blob]",
  "input.files = transfer.files",
  "dispatchEvent(new Event('input'",
  "dispatchEvent(new Event('change'",
  "delete window.__gptwebIncomingUpload"
]) {
  assert.ok(
    finalizeScript.includes(marker),
    `automatic upload script is missing marker: ${marker}`
  );
}

for (const marker of [
  "CFBundleDocumentTypes",
  "LSSupportsOpeningDocumentsInPlace"
]) {
  const plist = fs.readFileSync(
    path.join(projectRoot, "GPTWeb", "Info.plist"),
    "utf8"
  );
  assert.ok(plist.includes(marker), `Info.plist is missing ${marker}`);
}

assert.match(sceneSource, /openURLContexts URLContexts/);
assert.match(sceneSource, /connectionOptions\.urlContexts/);
assert.doesNotMatch(swiftSource, /WKOpenPanelParameters/);
assert.match(availabilityScript, /composer.*plus|plus.*composer/);
assert.match(swiftSource, /maximumAutomaticAttachmentBytes/);

console.log(
  "Document Open In and automatic attachment checks passed."
);
