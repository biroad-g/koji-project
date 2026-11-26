import 'dart:async';
import 'dart:ui' as ui;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/crop_service.dart';
import '../state/gaiji_provider.dart';
import '../theme/app_theme.dart';
import 'album_screen.dart';
import 'capture_screen.dart';
import 'crop_editor_screen.dart';
import 'register_screen.dart';

/// 下タブ（アルバム／撮影）を束ねるシェル。撮影の一連の流れを司る。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// アルバムが空かどうか（空なら FAB を出さず、画面内のボタンを使う）
  bool _albumEmpty = true;

  /// Web のときだけ接続状態を監視する（オフラインでも使えることを伝えるため）
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _listenConnectivity();
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  void _listenConnectivity() {
    final connectivity = Connectivity();
    bool? previous;
    _connectivitySub =
        connectivity.onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (previous != null && previous != online) {
        _showConnectionNotice(online);
      }
      previous = online;
    });
  }

  void _showConnectionNotice(bool online) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        backgroundColor: online ? AppColors.indigo : AppColors.inkSoft,
        content: Row(
          children: [
            Icon(
              online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              color: AppColors.goldSoft,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                online
                    ? 'オンラインに戻りました'
                    : 'オフラインになりました。そのまま撮影・登録できます',
                style: const TextStyle(
                  fontFamily: AppTheme.fontSans,
                  fontSize: 12.5,
                  height: 1.5,
                  color: AppColors.paper,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 空のアルバムでは画面内の大きなボタンが入口になるため、FAB は出さない
    final provider = context.watch<GaijiProvider>();
    _albumEmpty = !provider.loading && provider.total == 0;

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          AlbumScreen(onRequestCapture: () => setState(() => _index = 1)),
          CaptureScreen(onImagePicked: _startCropFlow),
        ],
      ),
      floatingActionButton: (_index == 0 && !_albumEmpty)
          ? Padding(
              // アルバム下部の絞り込みバー（62px）の上に出す
              padding: const EdgeInsets.only(bottom: 74),
              child: FloatingActionButton.extended(
                onPressed: () => setState(() => _index = 1),
                backgroundColor: AppColors.indigo,
                foregroundColor: Colors.white,
                elevation: 3,
                icon: const Icon(Icons.photo_camera_outlined, size: 19),
                label: const Text(
                  '外字を撮影',
                  style: TextStyle(
                    fontFamily: AppTheme.fontSans,
                    fontSize: 13,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: AppColors.gold.withValues(alpha: 0.55)),
                ),
              ),
            )
          : null,
      bottomNavigationBar: _BottomBar(
        index: _index,
        onChanged: (i) => setState(() => _index = i),
      ),
    );
  }

  /// 撮影／読み込みした画像から切り取り → 登録へ進む
  ///
  /// 写真の読み込み（デコード）に時間がかかると「何も起きない」ように見えて
  /// しまうため、デコードを待たずに切り取り画面を開き、画面側で読み込みます。
  Future<void> _startCropFlow(Uint8List bytes) async {
    if (!mounted) return;

    final confirmed = await Navigator.of(context).push<_CropConfirmation>(
      MaterialPageRoute(
        builder: (_) => _CropFlowScreen(imageBytes: bytes),
      ),
    );

    if (confirmed == null || !mounted) return;

    final registered = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RegisterScreen(
          croppedImage: confirmed.croppedImage,
          originalImage: confirmed.originalImage,
        ),
      ),
    );

    if (registered == true && mounted) {
      setState(() => _index = 0);
    }
  }
}

class _CropConfirmation {
  _CropConfirmation(this.croppedImage, this.originalImage);
  final Uint8List croppedImage;
  final Uint8List? originalImage;
}

/// 切り取り処理を実行し、確定した画像を返す画面
class _CropFlowScreen extends StatefulWidget {
  const _CropFlowScreen({required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<_CropFlowScreen> createState() => _CropFlowScreenState();
}

class _CropFlowScreenState extends State<_CropFlowScreen> {
  bool _processing = false;

  /// 画像の実寸。dart:ui のコーデックで非同期に取得する
  /// （大きな写真でもUIを固めないため）
  int _width = 0;
  int _height = 0;
  bool _sizeReady = false;
  String? _sizeError;

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
      setState(() {
        _sizeReady = true;
        _sizeError = '写真の情報を読み取れませんでした。枠を手で合わせてください。';
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(_sizeError!)),
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
    await Future.delayed(const Duration(milliseconds: 40));

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
          const SnackBar(content: Text('画像を処理できませんでした。別の写真でお試しください。')),
        );
        return;
      }

      final cropped = CropService.makeThumbnail(result.bytes, maxSide: 900);
      final original =
          CropService.downscaleIfNeeded(widget.imageBytes, maxSide: 1400);

      if (!mounted) return;
      Navigator.of(context).pop(_CropConfirmation(cropped, original));
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
          automaticallyImplyLeading: false,
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

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.indigoDeep,
        border: Border(top: BorderSide(color: AppColors.indigoSoft)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _NavItem(
                icon: Icons.grid_view_rounded,
                label: 'アルバム',
                selected: index == 0,
                onTap: () => onChanged(0),
              ),
              _NavItem(
                icon: Icons.photo_camera_outlined,
                label: '撮影',
                selected: index == 1,
                onTap: () => onChanged(1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.goldSoft : Colors.white54;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 21, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 1.2,
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
