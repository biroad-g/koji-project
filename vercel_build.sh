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
# --no-web-resources-cdn :
#   Flutter は既定で描画エンジン(CanvasKit)を gstatic.com から取得する。
#   オフライン時はこれが失敗して白画面になるため、必ずアプリ自身に同梱する。
flutter build web --release \
  --no-web-resources-cdn \
  --pwa-strategy=offline-first \
  --dart-define=flutter.inspector.structuredErrors=false \
  --dart-define=debugShowCheckedModeBanner=false

echo "==> オフライン対応の検証"
if grep -q '"useLocalCanvasKit":true' build/web/flutter_bootstrap.js; then
  echo "    OK: CanvasKit をアプリに同梱 (CDN 非依存)"
else
  echo "    NG: CanvasKit が CDN 参照のままです" >&2
  exit 1
fi

if grep -q "canvaskit/chromium/canvaskit.wasm" build/web/flutter_service_worker.js; then
  echo "    OK: Service Worker が CanvasKit をキャッシュ対象に含む"
else
  echo "    NG: Service Worker のキャッシュ対象に CanvasKit がありません" >&2
  exit 1
fi

echo "==> 完了: $(du -sh build/web | cut -f1)"
