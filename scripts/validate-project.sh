#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

required_files=(
  "GPTWeb.xcodeproj/project.pbxproj"
  "GPTWeb.xcodeproj/xcshareddata/xcschemes/GPTWeb.xcscheme"
  "GPTWeb.xcodeproj/xcshareddata/xcschemes/SafariFixHost.xcscheme"
  "GPTWeb/AppDelegate.swift"
  "GPTWeb/SceneDelegate.swift"
  "GPTWeb/WebViewController.swift"
  "GPTWeb/Info.plist"
  "GPTWeb/PrivacyInfo.xcprivacy"
  "GPTWeb/Assets.xcassets/ChatGPTIcon.appiconset/AppIcon-1024.png"
  "SafariFixHost/Info.plist"
  "SafariFixHost/SafariFixAppDelegate.swift"
  "SafariFixHost/SafariFixViewController.swift"
  "SafariExtension/Info.plist"
  "SafariExtension/SafariWebExtensionHandler.swift"
  "SafariExtension/Resources/manifest.json"
  "SafariExtension/Resources/content.js"
  "scripts/test-sidebar-gesture.js"
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
  node "$PROJECT_DIR/scripts/test-sidebar-gesture.js"
  node "$PROJECT_DIR/scripts/test-document-import.js"
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
    "SafariFixHost/Info.plist",
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
if manifest.get("version") != "1.2.6":
    raise SystemExit("Safari Extension 版本号不是 1.2.6")
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
    root / "GPTWeb/Assets.xcassets/ChatGPTIcon.appiconset/Contents.json",
    root / "GPTWeb/Assets.xcassets/LaunchBackground.colorset/Contents.json",
]
for path in catalogs:
    json.loads(path.read_text(encoding="utf-8"))

icon_directory = root / "GPTWeb/Assets.xcassets/ChatGPTIcon.appiconset"
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
    "SafariFixHost.app",
    'PBXNativeTarget "SafariFixHost"',
    "SafariWebExtensionHandler.swift",
    "manifest.json in Resources",
    "content.js in Resources",
    "Embed App Extensions",
    "com.apple.product-type.app-extension",
    "ASSETCATALOG_COMPILER_APPICON_NAME = ChatGPTIcon",
):
    if marker not in pbxproj:
        raise SystemExit(f"project.pbxproj 缺少标记：{marker}")
if "IPHONEOS_DEPLOYMENT_TARGET = 16.0" not in base_config:
    raise SystemExit("Base.xcconfig 的最低系统版本不是 iOS 16.0")
if "HOST_BUNDLE_IDENTIFIER = com.example.gptweb" not in base_config:
    raise SystemExit("Base.xcconfig 的宿主 Bundle ID 不正确")
if "SAFARI_FIX_BUNDLE_IDENTIFIER = com.example.gptweb.safarifix" not in base_config:
    raise SystemExit("Base.xcconfig 的 Safari 修复宿主 Bundle ID 不正确")
if "PRODUCT_BUNDLE_IDENTIFIER = $(HOST_BUNDLE_IDENTIFIER)" not in base_config:
    raise SystemExit("主应用没有使用宿主 Bundle ID")
if "MARKETING_VERSION = 1.2.6" not in base_config:
    raise SystemExit("Base.xcconfig 的更新版本号不是 1.2.6")
if "CURRENT_PROJECT_VERSION = 13" not in base_config:
    raise SystemExit("Base.xcconfig 的更新构建号不是 13")
if 'EXTRA_SETTINGS+=("HOST_BUNDLE_IDENTIFIER=$BUNDLE_ID")' not in build_script:
    raise SystemExit("自定义主应用 Bundle ID 没有传给 Xcode")
if '"SAFARI_FIX_BUNDLE_IDENTIFIER=$SAFARI_FIX_BUNDLE_ID"' not in build_script:
    raise SystemExit("自定义 Safari 修复宿主 Bundle ID 没有传给 Xcode")
for output in ("GPTWeb-unsigned.ipa", "SafariFixHost-unsigned.ipa"):
    if output not in build_script:
        raise SystemExit(f"构建脚本没有生成 {output}")

info = plistlib.loads((root / "GPTWeb/Info.plist").read_bytes())
if info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads") is not False:
    raise SystemExit("必须保持 NSAllowsArbitraryLoads=false")
if info.get("CFBundleDisplayName") != "ChatGPT":
    raise SystemExit("应用显示名不是 ChatGPT")
if info.get("CFBundleName") != "ChatGPT":
    raise SystemExit("应用名称不是 ChatGPT")
if info.get("CFBundleIconName") != "ChatGPTIcon":
    raise SystemExit("主应用没有使用新的 ChatGPTIcon 缓存键")
if info.get("CADisableMinimumFrameDurationOnPhone") is not True:
    raise SystemExit("主应用没有保留 ProMotion 自适应高刷新率")
if info.get("LSSupportsOpeningDocumentsInPlace") is not False:
    raise SystemExit("主应用必须让系统先复制文档，不能原地打开")
document_types = info.get("CFBundleDocumentTypes", [])
if not document_types or any(
    document_type.get("CFBundleTypeRole") != "Viewer"
    for document_type in document_types
):
    raise SystemExit("主应用文档类型必须使用只读 Viewer 角色")
declared_content_types = {
    content_type
    for document_type in document_types
    for content_type in document_type.get("LSItemContentTypes", [])
}
for required_type in ("public.data", "public.content", "public.image"):
    if required_type not in declared_content_types:
        raise SystemExit(f"主应用没有声明文档类型：{required_type}")

safari_fix_info = plistlib.loads(
    (root / "SafariFixHost/Info.plist").read_bytes()
)
if safari_fix_info.get("CFBundleDisplayName") != "ChatGPT Safari 修复":
    raise SystemExit("Safari 修复宿主显示名不正确")
if safari_fix_info.get("CFBundleIconName") != "ChatGPTIcon":
    raise SystemExit("Safari 修复宿主没有使用 ChatGPTIcon")

extension_info = plistlib.loads(
    (root / "SafariExtension/Info.plist").read_bytes()
)
extension = extension_info.get("NSExtension", {})
if extension.get("NSExtensionPointIdentifier") != "com.apple.Safari.web-extension":
    raise SystemExit("Safari Extension Point 配置错误")
if extension_info.get("CFBundleDisplayName") != "ChatGPT Work 滚动修复":
    raise SystemExit("Safari Extension 显示名称不正确")

swift = (root / "GPTWeb/WebViewController.swift").read_text(encoding="utf-8")
scene_swift = (root / "GPTWeb/SceneDelegate.swift").read_text(encoding="utf-8")
app_swift = (root / "GPTWeb/AppDelegate.swift").read_text(encoding="utf-8")
for marker in (
    'source: Self.workRepairDotScript',
    'source: Self.sidebarGestureScript',
    'data-gptweb-scroll-repaired',
    'nsError.domain == "WebKitErrorDomain" && nsError.code == 102',
    'value(forHTTPHeaderField: "Content-Disposition")',
    'isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow',
    'input.files = transfer.files;',
    'NSFileCoordinator(filePresenter: nil)',
    'try fileManager.copyItem(',
    'startAccessingSecurityScopedResource()',
    'load(BrowserPolicy.homeURL)',
    'webView.allowsLinkPreview = false',
    'webView.isOpaque = true',
    'webView.allowsBackForwardNavigationGestures = false',
    'button[data-testid="open-sidebar-button"]',
    'button[data-testid="close-sidebar-button"]',
):
    if marker not in swift:
        raise SystemExit(f"WebViewController.swift 缺少回归标记：{marker}")
for marker in (
    "connectionOptions.urlContexts",
    "openURLContexts URLContexts",
    "IncomingDocumentRouter.shared.register",
    "IncomingDocumentRouter.shared.receive",
):
    if marker not in scene_swift:
        raise SystemExit(f"SceneDelegate.swift 缺少回归标记：{marker}")
for marker in (
    "final class IncomingDocumentRouter",
    "launchOptions?[.url]",
    "open url: URL",
    'forKey: "GPTWeb.lastFirstPartyURL"',
):
    if marker not in app_swift:
        raise SystemExit(f"AppDelegate.swift 缺少回归标记：{marker}")
for removed_marker in (
    "UIDropInteraction",
    "loadFileRepresentation",
    "blockUnsafeWebFileDropScript",
):
    if removed_marker in swift:
        raise SystemExit(f"WebViewController.swift 仍包含已放弃的拖放代码：{removed_marker}")
for removed_marker in (
    "persistCurrentURL",
    "Keys.lastURL",
):
    if removed_marker in swift:
        raise SystemExit(f"WebViewController.swift 仍会恢复旧对话：{removed_marker}")
for removed_marker in (
    "URLCache.shared",
    "prewarmedWebView",
    "func prewarm",
):
    if removed_marker in app_swift:
        raise SystemExit(f"AppDelegate.swift 仍包含额外启动负担：{removed_marker}")

print("Plist、Safari Extension、Asset Catalog 和工程引用检查通过。")
PY

echo "静态检查全部通过。"
