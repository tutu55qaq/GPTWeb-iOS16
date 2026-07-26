#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

required_files=(
  "GPTWeb.xcodeproj/project.pbxproj"
  "GPTWeb.xcodeproj/xcshareddata/xcschemes/GPTWeb.xcscheme"
  "GPTWeb/AppDelegate.swift"
  "GPTWeb/SceneDelegate.swift"
  "GPTWeb/WebViewController.swift"
  "GPTWeb/Info.plist"
  "GPTWeb/PrivacyInfo.xcprivacy"
  "GPTWeb/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
)

for relative_path in "${required_files[@]}"; do
  if [[ ! -f "$PROJECT_DIR/$relative_path" ]]; then
    echo "缺少文件：$relative_path" >&2
    exit 1
  fi
done

bash -n "$PROJECT_DIR/scripts/build-ipa.sh"

if command -v node >/dev/null 2>&1; then
  node "$PROJECT_DIR/scripts/test-scroll-fix.js"
fi

python3 - "$PROJECT_DIR" <<'PY'
import json
import pathlib
import plistlib
import sys

root = pathlib.Path(sys.argv[1])

for relative in ("GPTWeb/Info.plist", "GPTWeb/PrivacyInfo.xcprivacy"):
    with (root / relative).open("rb") as handle:
        plistlib.load(handle)

catalogs = [
    root / "GPTWeb/Assets.xcassets/Contents.json",
    root / "GPTWeb/Assets.xcassets/AppIcon.appiconset/Contents.json",
    root / "GPTWeb/Assets.xcassets/LaunchBackground.colorset/Contents.json",
]
for path in catalogs:
    json.loads(path.read_text(encoding="utf-8"))

pbxproj = (root / "GPTWeb.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
base_config = (root / "Configs/Base.xcconfig").read_text(encoding="utf-8")
for marker in (
    "WebViewController.swift",
    "PrivacyInfo.xcprivacy",
    "Assets.xcassets",
):
    if marker not in pbxproj:
        raise SystemExit(f"project.pbxproj 缺少标记：{marker}")
if "IPHONEOS_DEPLOYMENT_TARGET = 16.0" not in base_config:
    raise SystemExit("Base.xcconfig 的最低系统版本不是 iOS 16.0")
if "MARKETING_VERSION = 1.0.3" not in base_config:
    raise SystemExit("Base.xcconfig 的更新版本号不是 1.0.3")
if "CURRENT_PROJECT_VERSION = 4" not in base_config:
    raise SystemExit("Base.xcconfig 的更新构建号不是 4")

info = plistlib.loads((root / "GPTWeb/Info.plist").read_bytes())
if info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads") is not False:
    raise SystemExit("必须保持 NSAllowsArbitraryLoads=false")

swift = (root / "GPTWeb/WebViewController.swift").read_text(encoding="utf-8")
for marker in (
    'source: Self.scrollbarScript',
    'nsError.domain == "WebKitErrorDomain" && nsError.code == 102',
    'value(forHTTPHeaderField: "Content-Disposition")',
    'isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow',
):
    if marker not in swift:
        raise SystemExit(f"WebViewController.swift 缺少回归标记：{marker}")

print("Plist、Asset Catalog 和工程引用检查通过。")
PY

echo "静态检查全部通过。"
