import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:gaiji_album/data/gaiji_repository.dart';
import 'package:gaiji_album/models/gaiji_entry.dart';
import 'package:gaiji_album/screens/detail_screen.dart';
import 'package:gaiji_album/state/gaiji_provider.dart';
import 'package:gaiji_album/theme/app_theme.dart';

/// Hive を使わずに動くテスト用リポジトリ
class _FakeRepository extends GaijiRepository {
  _FakeRepository(this._entries);

  final List<GaijiEntry> _entries;

  @override
  List<GaijiEntry> loadAll() => List.of(_entries);

  @override
  Future<void> save(GaijiEntry entry) async {
    final i = _entries.indexWhere((e) => e.id == entry.id);
    if (i >= 0) {
      _entries[i] = entry;
    } else {
      _entries.add(entry);
    }
  }

  @override
  Future<void> delete(String id) async {
    _entries.removeWhere((e) => e.id == id);
  }
}

/// 1x1 の透過 PNG
const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

GaijiEntry _sample({String? originalBase64}) => GaijiEntry(
      id: 'g_1',
      name: '觀',
      reading: 'かん',
      category: GaijiCategory.itaiji,
      source: '大正蔵',
      memo: '観の旧字',
      imageBase64: _pngBase64,
      originalBase64: originalBase64,
      createdAt: DateTime(2026, 1, 18),
    );

Future<GaijiProvider> _pump(WidgetTester tester, GaijiEntry entry) async {
  final provider = GaijiProvider(_FakeRepository([entry]));
  await provider.load();

  await tester.pumpWidget(
    ChangeNotifierProvider<GaijiProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.light,
        home: DetailScreen(entryId: entry.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return provider;
}

void main() {
  testWidgets('詳細画面に「画像を編集」ボタンがある', (tester) async {
    await _pump(tester, _sample());

    expect(find.text('画像を編集'), findsOneWidget);
    expect(find.byIcon(Icons.crop_free), findsOneWidget);
  });

  testWidgets('「画像を編集」を押すと編集方法を選ぶシートが出る', (tester) async {
    await _pump(tester, _sample());

    await tester.tap(find.text('画像を編集'));
    await tester.pumpAndSettle();

    // 元写真が無い場合は「今の字形をもとに切り取り直します」
    expect(find.text('枠を引き直す'), findsOneWidget);
    expect(find.text('別の写真から選び直す'), findsOneWidget);
    expect(find.text('今の字形をもとに切り取り直します'), findsOneWidget);
  });

  testWidgets('元写真がある場合は元写真から切り取り直すと案内する', (tester) async {
    await _pump(tester, _sample(originalBase64: _pngBase64));

    await tester.tap(find.text('画像を編集'));
    await tester.pumpAndSettle();

    expect(find.text('撮影した元写真から切り取り直します'), findsOneWidget);
  });

  testWidgets('「枠を引き直す」を押すと切り取り画面が開く', (tester) async {
    await _pump(tester, _sample());

    await tester.tap(find.text('画像を編集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('枠を引き直す'));
    // 切り取り画面は画像読み込み中にインジケータが回り続けるため
    // pumpAndSettle は使わず、数フレームだけ進める
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 「漢字を一字囲む」画面（読み込み中または切り取り本体）
    expect(
      find.textContaining('漢字を一字囲む'),
      findsWidgets,
    );
  });

  test('replaceImage は字形だけを差し替え、他の項目を保つ', () async {
    final entry = _sample();
    final provider = GaijiProvider(_FakeRepository([entry]));
    await provider.load();

    final newImage = Uint8List.fromList(List<int>.filled(8, 7));
    await provider.replaceImage(entryId: entry.id, croppedImage: newImage);

    final updated = provider.all.firstWhere((e) => e.id == entry.id);
    expect(updated.name, '觀');
    expect(updated.reading, 'かん');
    expect(updated.source, '大正蔵');
    expect(updated.createdAt, entry.createdAt);
    expect(updated.imageBase64, isNot(entry.imageBase64));
    expect(updated.updatedAt, isNotNull);
  });

  test('replaceImage は元写真を渡すと差し替える', () async {
    final entry = _sample();
    final provider = GaijiProvider(_FakeRepository([entry]));
    await provider.load();

    final newOriginal = Uint8List.fromList(List<int>.filled(6, 9));
    await provider.replaceImage(
      entryId: entry.id,
      croppedImage: Uint8List.fromList(List<int>.filled(4, 1)),
      originalImage: newOriginal,
    );

    final updated = provider.all.firstWhere((e) => e.id == entry.id);
    expect(updated.originalBytes, isNotNull);
    expect(updated.originalBytes!.length, 6);
  });

  test('存在しない ID への replaceImage は何もしない', () async {
    final provider = GaijiProvider(_FakeRepository([_sample()]));
    await provider.load();

    await provider.replaceImage(
      entryId: 'not_exist',
      croppedImage: Uint8List.fromList([1, 2, 3]),
    );
    expect(provider.total, 1);
  });
}
