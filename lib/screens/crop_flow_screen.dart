import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/crop_service.dart';
import '../theme/app_theme.dart';
import 'crop_editor_screen.dart';

/// 切り取り結果
class CropConfirmation {
  CropConfirmation(this.croppedImage, this.originalImage);

  /// 切り取った字形（透過 PNG）
  final Uint8List croppedImage;

  /// 切り取り元の写真（参照用・任意）
  final Uint8List? originalImage;
}

/// 切り取り画面を開き、確定した画像を返す。
/// キャンセルされた場合は null。
Future<CropConfirmation?> openCropFlow(
  BuildContext context,
  Uint8List imageBytes,
) {
  return Navigator.of(context).push<CropConfirmation>(
    MaterialPageRoute(
      builder: (_) => CropFlowScreen(imageBytes: imageBytes),
    ),
  );
}

/// 切り取り処理を実行し、確定した画像を返す画面。
/// 撮影直後でも、登録済みの外字の再編集でも同じものを使う。
class CropFlowScreen extends StatefulWidget {
  const CropFlowScreen({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<CropFlowScreen> createState() => _CropFlowScreenState();
}

class _CropFlowScreenState extends State<CropFlowScreen> {
  bool _processing = false;

  /// 画像の実寸。dart:ui のコーデックで非同期に取得する
  /// （大きな写真でもUIを固めないため）
  int _width = 0;
  int _height = 0;
  bool _sizeReady = false;

  @override
  void initState() {
    super.initState();
    _resolveSize();
  }

  Future<void> _resolveSize() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (!mounted) return;
      setState(() {
        _width = w;
        _height = h;
        _sizeReady = true;
      });
    } catch (e, st) {
      debugPrint('image size resolve failed: $e\n$st');
      if (!mounted) return;
      // 寸法が取れなくても切り取り画面は開く（枠は手動で調整できる）
      setState(() => _sizeReady = true);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('写真の情報を読み取れませんでした。枠を手で合わせてください。'),
        ),
      );
    }
  }

  Future<void> _onConfirmed(
    Rect pixelRect,
    bool transparentPaper,
    int threshold,
    bool autoTrim,
  ) async {
    setState(() => _processing = true);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    try {
      final result = CropService.crop(
        source: widget.imageBytes,
        left: pixelRect.left.round(),
        top: pixelRect.top.round(),
        right: pixelRect.right.round(),
        bottom: pixelRect.bottom.round(),
        autoTrim: autoTrim,
        transparentPaper: transparentPaper,
        threshold: threshold,
      );

      if (result.width == 0) {
        if (!mounted) return;
        setState(() => _processing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('画像を処理できませんでした。別の写真でお試しください。'),
          ),
        );
        return;
      }

      final cropped = CropService.makeThumbnail(result.bytes, maxSide: 900);
      final original =
          CropService.downscaleIfNeeded(widget.imageBytes, maxSide: 1400);

      if (!mounted) return;
      Navigator.of(context).pop(CropConfirmation(cropped, original));
    } catch (e, st) {
      debugPrint('crop failed: $e\n$st');
      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('切り取りに失敗しました: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 寸法を測っている間も「漢字を一字囲む」画面を出しておく（真っ暗にしない）
    if (!_sizeReady) {
      return Scaffold(
        backgroundColor: const Color(0xFF10151F),
        appBar: AppBar(
          backgroundColor: const Color(0xFF10151F),
          title: const Text('漢字を一字囲む'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.gold),
              SizedBox(height: 18),
              Text(
                '写真を読み込んでいます…',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        CropEditorScreen(
          imageBytes: widget.imageBytes,
          imageWidth: _width,
          imageHeight: _height,
          onConfirmed: _onConfirmed,
        ),
        if (_processing)
          Container(
            color: Colors.black.withValues(alpha: 0.62),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.gold),
                  SizedBox(height: 16),
                  Text(
                    '一字を切り取っています…',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
