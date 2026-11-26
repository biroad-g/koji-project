import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;

/// 切り取り・調整の結果
class CropResult {
  CropResult({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

/// 画像の切り取り・余白調整・背景透過を行う純Dartサービス。
/// Android / Web の双方で同一の挙動になる。
class CropService {
  /// [source] から [rect]（画像ピクセル座標）を切り出す。
  ///
  /// - [autoTrim] : 切り出し範囲内の「墨」に合わせて余白を詰める
  /// - [transparentPaper] : 紙の地色を透過させ、字形だけの PNG にする
  /// - [threshold] : 墨と紙を分ける明度しきい値（0-255）
  static CropResult crop({
    required Uint8List source,
    required int left,
    required int top,
    required int right,
    required int bottom,
    bool autoTrim = true,
    bool transparentPaper = false,
    int threshold = 150,
    int padding = 6,
  }) {
    final decoded = img.decodeImage(source);
    if (decoded == null) {
      return CropResult(bytes: source, width: 0, height: 0);
    }

    final x0 = left.clamp(0, decoded.width - 1);
    final y0 = top.clamp(0, decoded.height - 1);
    final x1 = right.clamp(x0 + 1, decoded.width);
    final y1 = bottom.clamp(y0 + 1, decoded.height);

    img.Image out = img.copyCrop(
      decoded,
      x: x0,
      y: y0,
      width: x1 - x0,
      height: y1 - y0,
    );

    if (autoTrim) {
      out = _trimToInk(out, threshold);
    }

    if (transparentPaper) {
      out = _paperToAlpha(out, threshold);
    } else {
      out = _normalizePaper(out, threshold);
    }

    if (padding > 0) {
      out = _pad(out, padding);
    }

    final png = img.encodePng(out, level: 6);
    return CropResult(
      bytes: Uint8List.fromList(png),
      width: out.width,
      height: out.height,
    );
  }

  /// 墨の外接矩形まで詰める（紙面の余白を落とす）
  ///
  /// 重要: この処理は「選んだ範囲の内側に詰める」だけで、範囲の外へは広げない。
  /// 外へ広げると隣の文字まで巻き込んでしまい、一字を切り出せなくなるため。
  static img.Image _trimToInk(img.Image src, int threshold) {
    int minX = src.width, minY = src.height, maxX = -1, maxY = -1;
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        final lum = _luminance(p);
        if (lum < threshold) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0 || maxY < 0) return src; // 墨が見つからない場合はそのまま

    // わずかに外側へ（字形の端が切れないように）が、元の範囲は超えない
    final pad = math.max(2, (math.max(src.width, src.height) * 0.02).round());
    final int cx0 = math.max(0, minX - pad);
    final int cy0 = math.max(0, minY - pad);
    final int cx1 = math.min(src.width, maxX + 1 + pad);
    final int cy1 = math.min(src.height, maxY + 1 + pad);

    // 正方形に近づける。ただし元の範囲内に収める（外へは広げない）
    final int w = cx1 - cx0;
    final int h = cy1 - cy0;
    final int maxSide = math.max(w, h);
    final int centerX = (cx0 + cx1) ~/ 2;
    final int centerY = (cy0 + cy1) ~/ 2;

    // 元画像のサイズを超えない範囲で正方形を作る
    final int limit = math.min(math.max(maxSide, 1),
        math.min(src.width, src.height));
    int sx = centerX - limit ~/ 2;
    int sy = centerY - limit ~/ 2;
    sx = sx.clamp(0, math.max(0, src.width - limit));
    sy = sy.clamp(0, math.max(0, src.height - limit));
    final int sw = math.min(limit, src.width - sx);
    final int sh = math.min(limit, src.height - sy);

    if (sw <= 0 || sh <= 0) return src;
    return img.copyCrop(src, x: sx, y: sy, width: sw, height: sh);
  }

  /// 画像から「文字らしき領域」を検出して返す（元画像のピクセル座標）。
  ///
  /// 過去帳・扁額のような横並び／縦並びの文字列から一字を選ぶために使う。
  /// 墨の投影（行・列の分布）から文字の切れ目を推定する。
  static List<Rect> detectCharacters(
    Uint8List source, {
    int threshold = 150,
    int maxCount = 60,
  }) {
    final decoded = img.decodeImage(source);
    if (decoded == null) return const [];

    final int w = decoded.width;
    final int h = decoded.height;
    if (w < 8 || h < 8) return const [];

    // 1) 墨のマスクを作る
    final mask = List<List<bool>>.generate(
      h,
      (_) => List<bool>.filled(w, false),
      growable: false,
    );
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (_luminance(decoded.getPixel(x, y)) < threshold) {
          mask[y][x] = true;
        }
      }
    }

    // 2) 行ごとの墨の有無から「文字の帯」を求める
    final rowInk = List<int>.filled(h, 0);
    for (int y = 0; y < h; y++) {
      int c = 0;
      for (int x = 0; x < w; x++) {
        if (mask[y][x]) c++;
      }
      rowInk[y] = c;
    }
    final rowGap = math.max(1, (w * 0.01).round());
    final bands = _splitRuns(rowInk, rowGap);

    final List<Rect> out = [];
    for (final band in bands) {
      // 3) 帯の中で列方向の墨分布を見て、文字ごとに切る
      final colInk = List<int>.filled(w, 0);
      for (int y = band.$1; y < band.$2; y++) {
        for (int x = 0; x < w; x++) {
          if (mask[y][x]) colInk[x]++;
        }
      }
      final bandH = band.$2 - band.$1;
      final colGap = math.max(2, (bandH * 0.08).round());
      final cols = _splitRuns(colInk, colGap);
      for (final col in cols) {
        final cw = col.$2 - col.$1;
        final chh = band.$2 - band.$1;
        if (cw < w * 0.02 || chh < h * 0.04) continue; // 小さすぎるものは除外
        if (cw > w * 0.9 && chh > h * 0.9) continue; // ほぼ全面は無視
        out.add(Rect.fromLTRB(
          col.$1.toDouble(),
          band.$1.toDouble(),
          col.$2.toDouble(),
          band.$2.toDouble(),
        ));
        if (out.length >= maxCount) return out;
      }
    }
    return out;
  }

  /// インク分布を「途切れている所」で区切って区間のリストにする
  static List<(int, int)> _splitRuns(List<int> values, int minGap) {
    final runs = <(int, int)>[];
    int? start;
    int lastInk = -1;
    for (int i = 0; i < values.length; i++) {
      if (values[i] > 0) {
        if (start == null) {
          start = i;
        } else if (i - lastInk > minGap) {
          runs.add((start, lastInk + 1));
          start = i;
        }
        lastInk = i;
      }
    }
    if (start != null && lastInk >= 0) runs.add((start, lastInk + 1));
    return runs;
  }

  /// 紙の地色を透明にし、墨だけを残す（濃淡は保持）
  static img.Image _paperToAlpha(img.Image src, int threshold) {
    final out = img.Image(width: src.width, height: src.height, numChannels: 4);
    final hi = math.max(threshold + 40, 200).toDouble();
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        final lum = _luminance(p);
        double alpha;
        if (lum <= threshold) {
          alpha = 1.0;
        } else if (lum >= hi) {
          alpha = 0.0;
        } else {
          alpha = 1.0 - ((lum - threshold) / (hi - threshold));
        }
        // 墨色は黒寄りに正規化（紙の色かぶりを除去）
        const value = 0;
        out.setPixelRgba(x, y, value, value, value, (alpha * 255).round());
      }
    }
    return out;
  }

  /// 背景透過しない場合：紙の明るさを揃えて読みやすくする
  static img.Image _normalizePaper(img.Image src, int threshold) {
    final out = src.convert(numChannels: 3);
    for (int y = 0; y < out.height; y++) {
      for (int x = 0; x < out.width; x++) {
        final p = out.getPixel(x, y);
        final lum = _luminance(p);
        if (lum > threshold) {
          // 紙はほぼ白に
          out.setPixelRgb(x, y, 253, 251, 244);
        } else {
          // 墨はやや引き締める
          final f = (lum / threshold).clamp(0.0, 1.0);
          final v = (40 + 60 * f).round();
          out.setPixelRgb(x, y, v, v, (v * 0.95).round());
        }
      }
    }
    return out;
  }

  static img.Image _pad(img.Image src, int padding) {
    final out = img.Image(
      width: src.width + padding * 2,
      height: src.height + padding * 2,
      numChannels: src.numChannels,
    );
    final bg = src.numChannels == 4 ? 0 : 253;
    img.fill(out, color: img.ColorRgba8(bg, bg, bg, 0));
    img.compositeImage(out, src, dstX: padding, dstY: padding);
    return out;
  }

  static double _luminance(img.Pixel p) =>
      0.299 * p.r + 0.587 * p.g + 0.114 * p.b;

  /// 解像度が大きすぎる写真を縮小（メモリ対策）
  static Uint8List downscaleIfNeeded(Uint8List source, {int maxSide = 2200}) {
    final decoded = img.decodeImage(source);
    if (decoded == null) return source;
    final longest = math.max(decoded.width, decoded.height);
    if (longest <= maxSide) return source;
    final resized = img.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? maxSide : null,
      height: decoded.height > decoded.width ? maxSide : null,
      interpolation: img.Interpolation.average,
    );
    return Uint8List.fromList(img.encodeJpg(resized, quality: 90));
  }

  /// 詳細表示用のサムネイル生成（base64 を軽くする）
  static Uint8List makeThumbnail(Uint8List source, {int maxSide = 900}) {
    final decoded = img.decodeImage(source);
    if (decoded == null) return source;
    final longest = math.max(decoded.width, decoded.height);
    if (longest <= maxSide) return Uint8List.fromList(img.encodePng(decoded));
    final resized = img.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? maxSide : null,
      height: decoded.height > decoded.width ? maxSide : null,
      interpolation: img.Interpolation.average,
    );
    return Uint8List.fromList(img.encodePng(resized));
  }
}
