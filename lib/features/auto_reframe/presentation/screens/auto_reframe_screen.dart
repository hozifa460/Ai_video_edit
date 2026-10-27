import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/services/face_detection_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/logger.dart';
import '../../data/services/ffmpeg_auto_reframe_service.dart';
import '../../domain/entities/reframe_config.dart';

/// Standalone Auto Reframe studio: real ML Kit speaker tracking, a live crop
/// overlay, and an FFmpeg render for any target aspect ratio.
class AutoReframeScreen extends StatefulWidget {
  final String videoPath;

  const AutoReframeScreen({super.key, required this.videoPath});

  @override
  State<AutoReframeScreen> createState() => _AutoReframeScreenState();
}

class _AutoReframeScreenState extends State<AutoReframeScreen> {
  final _reframeService = FfmpegAutoReframeService();

  VideoPlayerController? _controller;
  bool _playerReady = false;
  Duration _duration = Duration.zero;
  String? _error;

  FaceTrackResult? _track;
  bool _analyzing = false;
  double _analysisProgress = 0;
  String _analysisStatus = '';

  ReframeConfig _config = const ReframeConfig();
  bool _rendering = false;

  late final TextEditingController _customWidthController;
  late final TextEditingController _customHeightController;

  @override
  void initState() {
    super.initState();
    _customWidthController = TextEditingController(
      text: _config.customWidthRatio.toStringAsFixed(0),
    );
    _customHeightController = TextEditingController(
      text: _config.customHeightRatio.toStringAsFixed(0),
    );
    _initialize();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onPlayerTick);
    _controller?.dispose();
    _customWidthController.dispose();
    _customHeightController.dispose();
    super.dispose();
  }

  void _onPlayerTick() {
    if (mounted) setState(() {});
  }

  double get _durationSeconds => _duration.inMilliseconds / 1000;

  double get _positionSeconds {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return 0;
    return controller.value.position.inMilliseconds / 1000;
  }

  Future<void> _initialize() async {
    await _probeDuration();
    try {
      final controller = VideoPlayerController.file(File(widget.videoPath));
      _controller = controller;
      await controller.initialize();
      controller.addListener(_onPlayerTick);
      if (_duration == Duration.zero) {
        _duration = controller.value.duration;
      }
      if (mounted) setState(() => _playerReady = true);
    } catch (e, stack) {
      AppLogger().e('AutoReframe: player init failed', e, stack);
      if (mounted) {
        setState(() => _error = 'Could not open this video: $e');
      }
    }
    await _analyzeFaces();
  }

  /// FFprobe first, player duration as fallback (Release builds can lose the
  /// FFprobe JNI bridge, which must never block the feature).
  Future<void> _probeDuration() async {
    try {
      final session = await FFprobeKit.getMediaInformation(widget.videoPath);
      final info = session.getMediaInformation();
      final seconds = double.tryParse(info?.getDuration() ?? '') ?? 0;
      if (seconds > 0 && mounted) {
        setState(
          () => _duration = Duration(milliseconds: (seconds * 1000).round()),
        );
      }
    } catch (e) {
      AppLogger().e('AutoReframe: probe failed', e);
    }
  }

  Future<void> _analyzeFaces() async {
    if (_analyzing) return;
    setState(() {
      _analyzing = true;
      _analysisProgress = 0;
      _analysisStatus = 'Preparing face analysis...';
    });
    final result = await FaceDetectionService.analyzeVideoFaceTrack(
      widget.videoPath,
      durationSec: _durationSeconds > 0 ? _durationSeconds : null,
      deadZone: _config.motion.deadZone,
      smoothness: _config.motion.smoothness,
      onProgress: (progress, status) {
        if (!mounted) return;
        setState(() {
          _analysisProgress = progress;
          _analysisStatus = status;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _track = result;
      _analyzing = false;
      if (result == null) {
        _analysisStatus = 'No face found — center crop will be used';
      }
    });
  }

  /// Re-smooths the already measured trajectory. No FFmpeg, no ML Kit: the
  /// motion preset is a pure post-processing choice.
  void _applyMotionPreset(CameraMotionPreset preset) {
    setState(() {
      _config = _config.copyWith(motion: preset);
      final track = _track;
      if (track != null) {
        _track = FaceTrackResult(
          rawPoints: track.rawPoints,
          keyframes: FaceDetectionService.buildKeyframes(
            track.rawPoints,
            deadZone: preset.deadZone,
            smoothness: preset.smoothness,
          ),
          avgNormX: track.avgNormX,
          avgNormY: track.avgNormY,
          facesDetectedCount: track.facesDetectedCount,
          sourceWidth: track.sourceWidth,
          sourceHeight: track.sourceHeight,
        );
      }
    });
  }

  void _selectPreset(AspectRatioPreset preset) {
    setState(() => _config = _config.copyWith(preset: preset));
  }

  void _updateCustomRatio() {
    final width = double.tryParse(_customWidthController.text.trim());
    final height = double.tryParse(_customHeightController.text.trim());
    if (width == null || height == null || width <= 0 || height <= 0) return;
    setState(
      () => _config = _config.copyWith(
        customWidthRatio: width,
        customHeightRatio: height,
      ),
    );
  }

  Future<void> _render() async {
    if (_rendering) return;
    final tempDir = await getTemporaryDirectory();
    final outputPath =
        '${tempDir.path}/reframe_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final progress = ValueNotifier<double>(0);
    final status = ValueNotifier<String>('Starting render...');
    if (!mounted) {
      progress.dispose();
      status.dispose();
      return;
    }
    setState(() => _rendering = true);
    var dialogOpen = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Rendering Auto Reframe'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, value, _) => LinearProgressIndicator(value: value),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, value, _) =>
                    Text('${(value * 100).toStringAsFixed(0)}%'),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (_, value, _) => Text(
                  value,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final result = await _reframeService.reframe(
      videoPath: widget.videoPath,
      outputPath: outputPath,
      config: _config,
      track: _track,
      durationMs: _duration.inMilliseconds,
      onProgress: (value, message) {
        progress.value = value;
        status.value = message;
      },
    );

    if (!mounted) {
      progress.dispose();
      status.dispose();
      return;
    }
    if (dialogOpen) {
      dialogOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }
    setState(() => _rendering = false);
    progress.dispose();
    status.dispose();

    if (result == null) {
      final log = _reframeService.lastErrorLog;
      final detail = log == null
          ? 'Unknown FFmpeg error'
          : (log.length > 400 ? log.substring(log.length - 400) : log);
      setState(() => _error = detail);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reframe failed: $detail')),
      );
      return;
    }

    setState(() => _error = null);
    await Navigator.of(context).pushNamed(
      AppRouter.preview,
      arguments: {
        'originalPath': widget.videoPath,
        'processedPath': result,
        'originalDuration': _duration,
        'removedDuration': Duration.zero,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Auto Reframe'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Re-Analyze Face',
            onPressed: _analyzing ? null : _analyzeFaces,
            icon: const Icon(Icons.face_retouching_natural),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildPreview(),
            const SizedBox(height: 12),
            if (_analyzing) _buildAnalysisBanner(),
            if (_track != null) _buildTrackSummary(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            const SizedBox(height: 16),
            _buildRatioSelector(),
            if (_config.preset == AspectRatioPreset.custom)
              _buildCustomRatioInputs(),
            const SizedBox(height: 16),
            _buildStyleSelector(),
            const SizedBox(height: 16),
            _buildMotionSelector(),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _rendering ? null : _render,
              icon: const Icon(Icons.movie_creation_outlined),
              label: Text(_rendering ? 'Rendering...' : 'Render & Preview'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9C27B0),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final controller = _controller;
    if (!_playerReady || controller == null) {
      return Container(
        height: 260,
        decoration: BoxDecoration(
          color: AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final size = controller.value.size;
    final aspect = size.width > 0 && size.height > 0
        ? size.width / size.height
        : 16 / 9;
    final track = _track;
    final (normX, normY) = track?.sampleAt(_positionSeconds) ?? (0.5, 0.42);

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: aspect,
            child: Stack(
              fit: StackFit.expand,
              children: [
                VideoPlayer(controller),
                CustomPaint(
                  painter: ReframeOverlayPainter(
                    targetAspect: _config.aspectRatio,
                    normX: normX,
                    normY: normY,
                    style: _config.style,
                    speakerLocked: track != null,
                  ),
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: IconButton.filledTonal(
                    onPressed: () {
                      setState(() {
                        controller.value.isPlaying
                            ? controller.pause()
                            : controller.play();
                      });
                    },
                    icon: Icon(
                      controller.value.isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Slider(
          value: _positionSeconds.clamp(0, _durationSeconds).toDouble(),
          max: _durationSeconds > 0 ? _durationSeconds : 1,
          onChanged: _durationSeconds > 0
              ? (value) => controller.seekTo(
                  Duration(milliseconds: (value * 1000).round()),
                )
              : null,
        ),
        Text(
          '${_formatTime(_positionSeconds)} / ${_formatTime(_durationSeconds)}',
          style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _buildAnalysisBanner() {
    return Card(
      color: AppColors.surfaceLight,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            LinearProgressIndicator(value: _analysisProgress),
            const SizedBox(height: 8),
            Text(
              _analysisStatus,
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackSummary() {
    final track = _track!;
    return Card(
      color: AppColors.surfaceLight,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.face, color: Color(0xFFE040FB)),
        title: Text(
          'Speaker locked · ${track.facesDetectedCount} faces · '
          '${track.keyframes.length} keyframes',
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: Text(
          'avg x=${track.avgNormX.toStringAsFixed(2)} '
          'y=${track.avgNormY.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }

  Widget _buildRatioSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Aspect Ratio', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in AspectRatioPreset.values)
              ChoiceChip(
                avatar: Icon(preset.icon, size: 18),
                label: Text(preset.shortLabel),
                selected: _config.preset == preset,
                onSelected: (_) => _selectPreset(preset),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${_config.outputSize.$1} x ${_config.outputSize.$2}',
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _buildCustomRatioInputs() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _customWidthController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Width ratio',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _updateCustomRatio(),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(':'),
          ),
          Expanded(
            child: TextField(
              controller: _customHeightController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Height ratio',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _updateCustomRatio(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStyleSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Framing Mode', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final style in AutoReframeStyle.values)
              ChoiceChip(
                label: Text(style.label),
                selected: _config.style == style,
                onSelected: (_) =>
                    setState(() => _config = _config.copyWith(style: style)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _config.style.description,
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _buildMotionSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Camera Motion', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final motion in CameraMotionPreset.values)
              ChoiceChip(
                label: Text(motion.label),
                selected: _config.motion == motion,
                onSelected: (_) => _applyMotionPreset(motion),
              ),
          ],
        ),
      ],
    );
  }

  static String _formatTime(double seconds) {
    final total = seconds < 0 ? 0 : seconds.round();
    final minutes = total ~/ 60;
    final secs = total % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }
}

/// Live overlay: dimmed area outside the crop window, a glowing framing
/// rectangle at the tracked speaker position, and a "Speaker Locked" marker.
class ReframeOverlayPainter extends CustomPainter {
  final double targetAspect;
  final double normX;
  final double normY;
  final AutoReframeStyle style;
  final bool speakerLocked;

  const ReframeOverlayPainter({
    required this.targetAspect,
    required this.normX,
    required this.normY,
    required this.style,
    required this.speakerLocked,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final aspect = targetAspect > 0 ? targetAspect : 1.0;

    // Universal crop math in preview coordinates, mirroring the FFmpeg filter.
    double cropW;
    double cropH;
    if (size.width / size.height > aspect) {
      cropH = size.height;
      cropW = cropH * aspect;
    } else {
      cropW = size.width;
      cropH = cropW / aspect;
    }

    final faceTracking = style == AutoReframeStyle.smartFaceCrop;
    final centerX = faceTracking ? normX * size.width : size.width / 2;
    final centerY = faceTracking ? normY * size.height : size.height / 2;

    final left = (centerX - cropW / 2).clamp(0.0, size.width - cropW);
    final top = (centerY - cropH / 2).clamp(0.0, size.height - cropH);
    final cropRect = Rect.fromLTWH(left, top, cropW, cropH);

    if (style != AutoReframeStyle.blurBackgroundFrame) {
      final dimPath = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(cropRect);
      canvas.drawPath(dimPath, Paint()..color = Colors.black.withValues(alpha: 0.55));
    }

    final glow = Paint()
      ..color = const Color(0xFFE040FB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 6);
    canvas.drawRect(cropRect, glow);
    canvas.drawRect(
      cropRect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    // Crosshair at the actual tracked face center.
    final faceCenter = Offset(centerX, centerY);
    final cross = Paint()
      ..color = const Color(0xFF00E5FF)
      ..strokeWidth = 1.6;
    canvas.drawLine(
      faceCenter - const Offset(12, 0),
      faceCenter + const Offset(12, 0),
      cross,
    );
    canvas.drawLine(
      faceCenter - const Offset(0, 12),
      faceCenter + const Offset(0, 12),
      cross,
    );
    canvas.drawCircle(faceCenter, 5, cross..style = PaintingStyle.stroke);

    if (speakerLocked && faceTracking) {
      final badge = TextPainter(
        text: const TextSpan(
          text: 'Speaker Locked',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            backgroundColor: Color(0xAA9C27B0),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final badgeOffset = Offset(
        (cropRect.left + 8).clamp(0.0, size.width - badge.width - 8),
        (cropRect.top + 8).clamp(0.0, size.height - badge.height - 8),
      );
      badge.paint(canvas, badgeOffset);
    }
  }

  @override
  bool shouldRepaint(covariant ReframeOverlayPainter oldDelegate) {
    return oldDelegate.normX != normX ||
        oldDelegate.normY != normY ||
        oldDelegate.targetAspect != targetAspect ||
        oldDelegate.style != style ||
        oldDelegate.speakerLocked != speakerLocked;
  }
}
