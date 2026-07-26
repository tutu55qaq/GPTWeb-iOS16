#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
ARCHIVE_PATH="$BUILD_DIR/GPTWeb.xcarchive"
IPA_PATH="$BUILD_DIR/GPTWeb-unsigned.ipa"
STAGE_DIR="$BUILD_DIR/ipa-stage"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "错误：未找到 xcodebuild。请在安装了 Xcode 的 macOS 上运行。" >&2
  exit 1
fi

XCODE_ARGS=(
  -project "$PROJECT_DIR/GPTWeb.xcodeproj"
  -scheme GPTWeb
  -configuration Release
  -destination "generic/platform=iOS"
  -archivePath "$ARCHIVE_PATH"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
)

if [[ -n "${BUNDLE_ID:-}" ]]; then
  XCODE_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$STAGE_DIR" "$IPA_PATH"

xcodebuild "${XCODE_ARGS[@]}" clean archive

APP_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "错误：归档中没有找到 .app。" >&2
  exit 1
fi

mkdir -p "$STAGE_DIR/Payload"
/usr/bin/ditto "$APP_PATH" "$STAGE_DIR/Payload/$(basename "$APP_PATH")"

(
  cd "$STAGE_DIR"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$IPA_PATH" Payload
)

echo
echo "未签名 IPA 已生成：$IPA_PATH"

