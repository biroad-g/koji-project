#!/usr/bin/env bash
# Vercel のビルドコンテナで Flutter Web をビルドするスクリプト。
# Vercel には Flutter SDK が入っていないため、指定バージョンを取得してからビルドする。
set -euo pipefail

FLUTTER_VERSION="3.35.4"
FLUTTER_DIR="/tmp/flutter-sdk"

echo "==> Flutter ${FLUTTER_VERSION} を取得"
if [ ! -x "${FLUTTER_DIR}/bin/flutter" ]; then
  rm -rf "${FLUTTER_DIR}"
  git clone --depth 1 --branch "${FLUTTER_VERSION}" \
    https://github.com/flutter/flutter.git "${FLUTTER_DIR}"
fi

export PATH="${FLUTTER_DIR}/bin:${PATH}"
export PUB_CACHE="${PUB_CACHE:-/tmp/pub-cache}"

echo "==> バージョン確認"
flutter --version
flutter config --no-analytics >/dev/null 2>&1 || true
flutter config --enable-web >/dev/null 2>&1 || true

echo "==> 依存関係を解決"
flutter pub get

echo "==> Web リリースビルド"
flutter build web --release \
  --dart-define=flutter.inspector.structuredErrors=false \
  --dart-define=debugShowCheckedModeBanner=false

echo "==> 完了: $(du -sh build/web | cut -f1)"
