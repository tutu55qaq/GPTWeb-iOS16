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
  "SafariExtension/Info.plist"
  "SafariExtension/SafariWebExtensionHandler.swift"
  "SafariExtension/Resources/manifest.json"
  "SafariExtension/Resources/content.js"
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
import hashlib
import pathlib
import plistlib
import struct
import sys

root = pathlib.Path(sys.argv[1])

for relative in (
    "GPTWeb/Info.plist",
    "GPTWeb/PrivacyInfo.xcprivacy",
    "SafariExtension/Info.plist",
):
    with (root / relative).open("rb") as handle:
        plistlib.load(handle)

manifest = json.loads(
    (root / "SafariExtension/Resources/manifest.json").read_text(
        encoding="utf-8"
    )
)
if manifest.get("manifest_version") != 2:
    raise SystemExit("Safari Extension 必须使用兼容 iOS 16 的 Manifest V2")
if manifest.get("version") != "1.2.0":
    raise SystemExit("Safari Extension 版本号不是 1.2.0")
content_scripts = manifest.get("content_scripts", [])
if len(content_scripts) != 1:
    raise SystemExit("Safari Extension content_scripts 配置错误")
content_script = content_scripts[0]
if content_script.get("js") != ["content.js"]:
    raise SystemExit("Safari Extension 没有加载 content.js")
if content_script.get("run_at") != "document_end":
    raise SystemExit("Safari Extension 必须在 document_end 注入")
if content_script.get("all_frames") is not True:
    raise SystemExit("Safari Extension 必须覆盖 ChatGPT 子 Frame")
if "https://chatgpt.com/*" not in content_script.get("matches", []):
    raise SystemExit("Safari Extension 没有限定 chatgpt.com")

catalogs = [
    root / "GPTWeb/Assets.xcassets/Contents.json",
    root / "GPTWeb/Assets.xcassets/AppIcon.appiconset/Contents.json",
    root / "GPTWeb/Assets.xcassets/LaunchBackground.colorset/Contents.json",
]
for path in catalogs:
    json.loads(path.read_text(encoding="utf-8"))

icon_directory = root / "GPTWeb/Assets.xcassets/AppIcon.appiconset"
icon_sizes = {
    "AppIcon-1024.png": (1024, 1024),
    "AppIcon-20@2x.png": (40, 40),
    "AppIcon-20@3x.png": (60, 60),
    "AppIcon-29@2x.png": (58, 58),
    "AppIcon-29@3x.png": (87, 87),
    "AppIcon-40@2x.png": (80, 80),
    "AppIcon-40@3x.png": (120, 120),
    "AppIcon-60@2x.png": (120, 120),
    "AppIcon-60@3x.png": (180, 180),
}
for filename, expected_size in icon_sizes.items():
    data = (icon_directory / filename).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise SystemExit(f"{filename} 不是有效 PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != expected_size:
        raise SystemExit(
            f"{filename} 尺寸错误：{width}x{height}，应为 "
            f"{expected_size[0]}x{expected_size[1]}"
        )
    if data[25] not in (0, 2, 3):
        raise SystemExit(f"{filename} 含有 App Store 不允许的 Alpha 通道")

official_icon_sha256 = hashlib.sha256(
    (icon_directory / "AppIcon-1024.png").read_bytes()
).hexdigest()
if official_icon_sha256 != "25a0de01a71d3ba6c3e32b9a230d4d0c6cca296aabbfdd9d5379f3a21e7648dc":
    raise SystemExit("1024px 官方 ChatGPT 图标内容不匹配")

pbxproj = (root / "GPTWeb.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
base_config = (root / "Configs/Base.xcconfig").read_text(encoding="utf-8")
build_script = (root / "scripts/build-ipa.sh").read_text(encoding="utf-8")
for marker in (
    "WebViewController.swift",
    "PrivacyInfo.xcprivacy",
    "Assets.xcassets",
    "SafariExtension.appex",
    "SafariWebExtensionHandler.swift",
    "manifest.json in Resources",
    "content.js in Resources",
    "Embed App Extensions",
    "com.apple.product-type.app-extension",
):
    if marker not in pbxproj:
        raise SystemExit(f"project.pbxproj 缺少标记：{marker}")
if "IPHONEOS_DEPLOYMENT_TARGET = 16.0" not in base_config:
    raise SystemExit("Base.xcconfig 的最低系统版本不是 iOS 16.0")
if "HOST_BUNDLE_IDENTIFIER = com.example.gptweb" not in base_config:
    raise SystemExit("Base.xcconfig 的宿主 Bundle ID 不正确")
if "PRODUCT_BUNDLE_IDENTIFIER = $(HOST_BUNDLE_IDENTIFIER)" not in base_config:
    raise SystemExit("主应用没有使用宿主 Bundle ID")
if "MARKETING_VERSION = 1.2.0" not in base_config:
    raise SystemExit("Base.xcconfig 的更新版本号不是 1.2.0")
if "CURRENT_PROJECT_VERSION = 7" not in base_config:
    raise SystemExit("Base.xcconfig 的更新构建号不是 7")
if 'XCODE_ARGS+=("HOST_BUNDLE_IDENTIFIER=$BUNDLE_ID")' not in build_script:
    raise SystemExit("自定义 Bundle ID 没有同时传递给宿主与 Safari Extension")

info = plistlib.loads((root / "GPTWeb/Info.plist").read_bytes())
if info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads") is not False:
    raise SystemExit("必须保持 NSAllowsArbitraryLoads=false")
if info.get("CFBundleDisplayName") != "ChatGPT":
    raise SystemExit("应用显示名不是 ChatGPT")
if info.get("CFBundleName") != "ChatGPT":
    raise SystemExit("应用名称不是 ChatGPT")

extension_info = plistlib.loads(
    (root / "SafariExtension/Info.plist").read_bytes()
)
extension = extension_info.get("NSExtension", {})
if extension.get("NSExtensionPointIdentifier") != "com.apple.Safari.web-extension":
    raise SystemExit("Safari Extension Point 配置错误")
if extension_info.get("CFBundleDisplayName") != "ChatGPT Work 滚动修复":
    raise SystemExit("Safari Extension 显示名称不正确")

swift = (root / "GPTWeb/WebViewController.swift").read_text(encoding="utf-8")
for marker in (
    'source: Self.workRepairDotScript',
    'data-gptweb-scroll-repaired',
    'nsError.domain == "WebKitErrorDomain" && nsError.code == 102',
    'value(forHTTPHeaderField: "Content-Disposition")',
    'isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow',
):
    if marker not in swift:
        raise SystemExit(f"WebViewController.swift 缺少回归标记：{marker}")

print("Plist、Safari Extension、Asset Catalog 和工程引用检查通过。")
PY

echo "静态检查全部通过。"
