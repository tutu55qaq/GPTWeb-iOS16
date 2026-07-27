#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "错误：未找到 xcodebuild。请在安装了 Xcode 的 macOS 上运行。" >&2
  exit 1
fi

EXTRA_SETTINGS=()
if [[ -n "${BUNDLE_ID:-}" ]]; then
  EXTRA_SETTINGS+=("HOST_BUNDLE_IDENTIFIER=$BUNDLE_ID")
fi
if [[ -n "${SAFARI_FIX_BUNDLE_ID:-}" ]]; then
  EXTRA_SETTINGS+=(
    "SAFARI_FIX_BUNDLE_IDENTIFIER=$SAFARI_FIX_BUNDLE_ID"
  )
fi

build_ipa() {
  local scheme="$1"
  local archive_path="$2"
  local ipa_path="$3"
  local stage_dir="$4"

  rm -rf "$archive_path" "$stage_dir" "$ipa_path"

  xcodebuild \
    -project "$PROJECT_DIR/GPTWeb.xcodeproj" \
    -scheme "$scheme" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$archive_path" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    "${EXTRA_SETTINGS[@]}" \
    clean archive

  local app_path
  app_path="$(
    find "$archive_path/Products/Applications" \
      -maxdepth 1 \
      -type d \
      -name '*.app' \
      -print \
      -quit
  )"
  if [[ -z "$app_path" ]]; then
    echo "错误：$scheme 归档中没有找到 .app。" >&2
    exit 1
  fi

  mkdir -p "$stage_dir/Payload"
  /usr/bin/ditto \
    "$app_path" \
    "$stage_dir/Payload/$(basename "$app_path")"

  (
    cd "$stage_dir"
    COPYFILE_DISABLE=1 /usr/bin/zip -qry "$ipa_path" Payload
  )

  echo "未签名 IPA 已生成：$ipa_path"
}

mkdir -p "$BUILD_DIR"

build_ipa \
  GPTWeb \
  "$BUILD_DIR/GPTWeb.xcarchive" \
  "$BUILD_DIR/GPTWeb-unsigned.ipa" \
  "$BUILD_DIR/gptweb-ipa-stage"

build_ipa \
  SafariFixHost \
  "$BUILD_DIR/SafariFixHost.xcarchive" \
  "$BUILD_DIR/SafariFixHost-unsigned.ipa" \
  "$BUILD_DIR/safari-fix-ipa-stage"
