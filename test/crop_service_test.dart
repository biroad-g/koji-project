import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:gaiji_album/services/crop_service.dart';
import 'package:image/image.dart' as img;

/// 紙に漢字が並んでいる写真を模したテスト画像を作る
Uint8List _makeTextImage({
  required int charCount,
  required int charSize,
  int gap = 40,
  int paperLum = 250,
  int inkLum = 30,
}) {
  final int w = charCount * (charSize + gap) + gap;
  final int h = charSize + gap * 2;
  final im = img.Image(width: w, height: h, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(paperLum, paperLum, paperLum));

  for (int i = 0; i < charCount; i++) {
    final int x0 = gap + i * (charSize + gap);
    final int y0 = gap;
    // 漢字の代わりに、外接矩形が明確な「田」のような図形を描く
    // 外枠
    for (int x = x0; x < x0 + charSize; x++) {
      for (int y = y0; y < y0 + charSize; y++) {
        final bool edge = x < x0 + 3 ||
            x >= x0 + charSize - 3 ||
            y < y0 + 3 ||
            y >= y0 + charSize - 3;
        final bool cross = (x - x0 - charSize ~/ 2).abs() < 3 ||
            (y - y0 - charSize ~/ 2).abs() < 3;
        if (edge || cross) {
          im.setPixelRgb(x, y, inkLum, inkLum, inkLum);
        }
      }
    }
  }
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  group('CropService.detectCharacters', () {
    test('横に並んだ5文字を5つ検出する', () {
      final bytes = _makeTextImage(charCount: 5, charSize: 120);
      final found = CropService.detectCharacters(bytes, threshold: 150);

      expect(found.length, 5,
          reason: '5文字あるので5つの矩形が返るはず: ${found.length}');

      // すべて正方形に近い（漢字一字）
      for (final r in found) {
        final ratio = r.width / r.height;
        expect(ratio, greaterThan(0.7));
        expect(ratio, lessThan(1.4));
      }

      // x 座標が単調増加（左から右へ）
      for (int i = 1; i < found.length; i++) {
        expect(found[i].left, greaterThan(found[i - 1].left));
      }
    });

    test('1文字だけの画像では1つ検出する', () {
      final bytes = _makeTextImage(charCount: 1, charSize: 150);
      final found = CropService.detectCharacters(bytes, threshold: 150);
      expect(found.length, 1);
    });

    test('空白だけの画像では何も検出しない', () {
      final im = img.Image(width: 300, height: 300, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(250, 250, 250));
      final bytes = Uint8List.fromList(img.encodePng(im));
      final found = CropService.detectCharacters(bytes, threshold: 150);
      expect(found, isEmpty);
    });
  });

  group('CropService.crop', () {
    test('指定した一字だけを切り取り、隣の字を巻き込まない', () {
      final bytes = _makeTextImage(charCount: 3, charSize: 120, gap: 40);
      final cands = CropService.detectCharacters(bytes, threshold: 150);
      expect(cands.length, 3);

      // 中央の文字だけを切り取る
      final target = cands[1];
      final result = CropService.crop(
        source: bytes,
        left: target.left.round(),
        top: target.top.round(),
        right: target.right.round(),
        bottom: target.bottom.round(),
        autoTrim: true,
        transparentPaper: true,
        threshold: 150,
      );

      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));

      // 切り取った結果が、元の一字の大きさから大きく外れていないこと
      // （自動調整で隣の字まで広がっていないかの確認）
      final expected = math.max(target.width, target.height);
      final actual = math.max(result.width, result.height);
      expect(actual, lessThanOrEqualTo((expected * 1.45).round()),
          reason: '一字 $expected px に対し $actual px は広がりすぎ（隣の字を巻き込んでいる）');
    });

    test('範囲外の座標を渡しても落ちない', () {
      final bytes = _makeTextImage(charCount: 2, charSize: 100);
      final result = CropService.crop(
        source: bytes,
        left: -500,
        top: -500,
        right: 99999,
        bottom: 99999,
        autoTrim: false,
        transparentPaper: false,
      );
      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));
    });
  });
}
