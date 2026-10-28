import 'dart:io';
import 'dart:math';

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

  /// The trajectory actually rendered/previewed: auto active-speaker path, or
  /// the locked person's path when `selectedSpeakerId` is set. Recomputed only
  /// when the analysis, motion preset or speaker selection changes.
  FaceTrackResult? _effectiveTrack;

  /// AI-generated keyframes (normalized for editing) — the "Reset AI" base.
  List<FaceTrackPoint> _aiKeyframes = const [];

  /// User-editable keyframe list driving preview + render. Re-initialized
  /// whenever [_recomputeEffectiveTrack] runs.
  List<FaceTrackPoint> _workingKeyframes = const [];

  /// When on, tapping the video places/moves the crop window instead of
  /// locking onto a detected face.
  bool _editMode = false;

  /// Crop-box drag origin (normalized), kept across a pan gesture.
  (double, double)? _dragOrigin;

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
      _recomputeEffectiveTrack();
    });
  }

  /// Resolves the path used by preview + render: the auto active-speaker
  /// trajectory, or the locked person's own trajectory when a speaker chip is
  /// selected (`selectedSpeakerId != null`), then (re)initializes the manual
  /// keyframe editor from those keyframes.
  void _recomputeEffectiveTrack() {
    final track = _track;
    if (track == null) {
      _effectiveTrack = null;
      _aiKeyframes = const [];
      _workingKeyframes = const [];
      return;
    }
    final id = _config.selectedSpeakerId;
    FaceTrackResult resolved = track;
    if (id != null) {
      DetectedSpeakerProfile? profile;
      for (final candidate in track.speakers) {
        if (candidate.id == id) {
          profile = candidate;
          break;
        }
      }
      if (profile != null) {
        resolved = FaceTrackResult(
          rawPoints: profile.rawPoints,
          keyframes: FaceDetectionService.buildKeyframes(
            profile.rawPoints,
            deadZone: _config.motion.deadZone,
            smoothness: _config.motion.smoothness,
          ),
          avgNormX: profile.avgNormX,
          avgNormY: profile.avgNormY,
          facesDetectedCount: track.facesDetectedCount,
          speakers: track.speakers,
          sourceWidth: track.sourceWidth,
          sourceHeight: track.sourceHeight,
        );
      }
    }
    _effectiveTrack = resolved;

    // Clean, editable keyframes: fold synthetic 1ms helpers into single
    // cut keyframes and flag every >= 0.10 jump as an instant cut.
    _aiKeyframes = FaceDetectionService.normalizeKeyframesForEditing(
      resolved.keyframes,
    );
    _workingKeyframes = List<FaceTrackPoint>.of(_aiKeyframes);
  }

  // ---------------------------------------------------------------------------
  // Manual keyframe editor
  // ---------------------------------------------------------------------------

  /// Working-keyframe position at [timeSec], honoring `isCut` holds/snaps.
  (double, double) _currentSampledPosition(double timeSec) {
    final keyframes = _workingKeyframes;
    if (keyframes.isEmpty) {
      return _effectiveTrack?.sampleAt(timeSec) ?? (0.5, 0.42);
    }
    return FaceTrackResult.sampleKeyframes(keyframes, timeSec);
  }

  /// Index of the keyframe nearest to [timeSec] (`-1` when there is none).
  int _nearestKfIndex(double timeSec) {
    final keyframes = _workingKeyframes;
    if (keyframes.isEmpty) return -1;
    var best = 0;
    var bestDelta = double.infinity;
    for (var i = 0; i < keyframes.length; i++) {
      final delta = (keyframes[i].timeSec - timeSec).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = i;
      }
    }
    return best;
  }

  /// Insert-or-update a manual keyframe at [timeSec] (±0.35s window).
  void _upsertManualKeyframeAt(double timeSec, double normX, double normY) {
    setState(() {
      _workingKeyframes = FaceDetectionService.upsertManualKeyframe(
        _workingKeyframes,
        timeSec: timeSec,
        normX: normX,
        normY: normY,
      );
    });
  }

  void _seekToTime(double timeSec) {
    final controller = _controller;
    if (controller == null || _durationSeconds <= 0) return;
    final clamped = timeSec.clamp(0.0, _durationSeconds);
    controller.seekTo(Duration(milliseconds: (clamped * 1000).round()));
    setState(() {});
  }

  /// "+ Add / Set KF": keyframes the crop position at the playhead.
  void _addOrSetKeyframeAtPlayhead() {
    final (x, y) = _currentSampledPosition(_positionSeconds);
    _upsertManualKeyframeAt(_positionSeconds, x, y);
  }

  /// Toggles the transition of the current keyframe. Marked `isManual` so the
  /// automatic cut heuristics never override the user's choice.
  void _toggleCutForCurrentKeyframe() {
    final index = _nearestKfIndex(_positionSeconds);
    if (index < 0) return;
    setState(() {
      final updated = List<FaceTrackPoint>.of(_workingKeyframes);
      final point = updated[index];
      updated[index] = point.copyWith(isCut: !point.isCut, isManual: true);
      _workingKeyframes = updated;
    });
  }

  void _deleteCurrentKeyframe() {
    if (_workingKeyframes.length <= 1) return;
    final index = _nearestKfIndex(_positionSeconds);
    if (index < 0) return;
    setState(() {
      _workingKeyframes = FaceDetectionService.deleteKeyframe(
        _workingKeyframes,
        index,
      );
    });
  }

  void _resetKeyframes() {
    setState(() => _workingKeyframes = List<FaceTrackPoint>.of(_aiKeyframes));
  }

  /// -1 = previous keyframe before the playhead, +1 = next one after it.
  void _jumpKeyframe(int direction) {
    final position = _positionSeconds;
    double? target;
    if (direction < 0) {
      for (final point in _workingKeyframes) {
        if (point.timeSec < position - 0.05) target = point.timeSec;
      }
    } else {
      for (final point in _workingKeyframes) {
        if (point.timeSec > position + 0.05) {
          target = point.timeSec;
          break;
        }
      }
    }
    if (target != null) _seekToTime(target);
  }

  /// Output crop aspect after `frameFill` (mirrors the FFmpeg inner box).
  double _effectiveCropAspect() {
    final (outW, outH) = _config.outputSize;
    final box = FfmpegAutoReframeService.innerBoxForFill(
      outW: outW,
      outH: outH,
      frameFill: _config.frameFillClamped,
    );
    return box.boxW / box.boxH;
  }

  /// Keeps the crop window fully inside the source frame while dragging.
  (double, double) _clampCropCenter(
    double normX,
    double normY,
    double previewW,
    double previewH,
  ) {
    if (previewW <= 0 || previewH <= 0) return (normX, normY);
    final sourceAspect = previewW / previewH;
    final effectiveAspect = _effectiveCropAspect();
    double cropW;
    double cropH;
    if (sourceAspect > effectiveAspect) {
      cropH = 1.0;
      cropW = effectiveAspect / sourceAspect;
    } else {
      cropW = 1.0;
      cropH = sourceAspect / effectiveAspect;
    }
    return (
      normX.clamp(cropW / 2, 1 - cropW / 2),
      normY.clamp(cropH / 2, 1 - cropH / 2),
    );
  }

  // --- Direct crop-box dragging ---------------------------------------------

  void _onCropPanStart() {
    final controller = _controller;
    if (controller != null && controller.value.isPlaying) controller.pause();
    _dragOrigin = _currentSampledPosition(_positionSeconds);
  }

  void _onCropPanUpdate(
    double deltaXPx,
    double deltaYPx,
    double previewW,
    double previewH,
  ) {
    if (previewW <= 0 || previewH <= 0) return;
    final origin = _dragOrigin ?? _currentSampledPosition(_positionSeconds);
    _dragOrigin = origin;
    final (clampedX, clampedY) = _clampCropCenter(
      origin.$1 + deltaXPx / previewW,
      origin.$2 + deltaYPx / previewH,
      previewW,
      previewH,
    );
    _upsertManualKeyframeAt(_positionSeconds, clampedX, clampedY);
  }

  void _onCropPanEnd() => _dragOrigin = null;

  void _selectSpeaker(int? speakerId) {
    setState(() {
      _config = _config.copyWith(selectedSpeakerId: speakerId);
      _recomputeEffectiveTrack();
    });
  }

  /// Tap-to-lock: snaps the selection to the detected person nearest the tap.
  void _onPreviewTap(double normX, double normY) {
    final track = _track;
    if (track == null || track.speakers.isEmpty) return;

    DetectedSpeakerProfile? nearest;
    var bestDistance = double.infinity;
    for (final profile in track.speakers) {
      final (px, py) = _positionAt(profile.rawPoints, _positionSeconds);
      final dx = px - normX;
      final dy = py - normY;
      final distance = dx * dx + dy * dy;
      if (distance < bestDistance) {
        bestDistance = distance;
        nearest = profile;
      }
    }
    if (nearest == null) return;
    _selectSpeaker(nearest.id);
  }

  /// Position of a trajectory at one instant (nearest sampled point).
  static (double, double) _positionAt(
    List<FaceTrackPoint> points,
    double timeSec,
  ) {
    if (points.isEmpty) return (0.5, 0.42);
    var best = points.first;
    var bestDelta = double.infinity;
    for (final point in points) {
      final delta = (point.timeSec - timeSec).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = point;
      }
    }
    return (best.normX, best.normY);
  }

  /// One marker per detected person at [timeSec]; the explicitly selected one
  /// is flagged so the painter can highlight it.
  List<ReframeFaceMarker> _faceMarkersAt(double timeSec) {
    final track = _track;
    if (track == null || track.speakers.isEmpty) return const [];
    final selectedId = _config.selectedSpeakerId;
    return [
      for (final profile in track.speakers)
        ReframeFaceMarker(
          normX: _positionAt(profile.rawPoints, timeSec).$1,
          normY: _positionAt(profile.rawPoints, timeSec).$2,
          label: profile.label,
          locked: profile.id == selectedId,
        ),
    ];
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
          speakers: track.speakers,
          sourceWidth: track.sourceWidth,
          sourceHeight: track.sourceHeight,
        );
      }
      _recomputeEffectiveTrack();
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

    // Working keyframes are the source of truth after manual edits; expand
    // effective cuts into 1ms steps (idempotent) so FFmpeg snaps exactly.
    final base = _effectiveTrack;
    final working = _workingKeyframes;
    final renderTrack = working.isEmpty
        ? base
        : FaceTrackResult(
            rawPoints: base?.rawPoints ?? working,
            keyframes: FaceDetectionService.materializeKeyframesForFfmpeg(
              working,
            ),
            avgNormX: base?.avgNormX ?? 0.5,
            avgNormY: base?.avgNormY ?? 0.42,
            facesDetectedCount: base?.facesDetectedCount ?? 0,
            speakers: base?.speakers ?? const [],
            sourceWidth: base?.sourceWidth ?? 0,
            sourceHeight: base?.sourceHeight ?? 0,
          );

    final result = await _reframeService.reframe(
      videoPath: widget.videoPath,
      outputPath: outputPath,
      config: _config,
      track: renderTrack,
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
            _buildKeyframeEditor(),
            if (_analyzing) _buildAnalysisBanner(),
            if (_track != null) _buildTrackSummary(),
            if (_track != null && _track!.speakers.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildSpeakerSelector(),
            ],
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
            if (_config.style != AutoReframeStyle.blurBackgroundFrame) ...[
              const SizedBox(height: 16),
              _buildFrameFillControl(),
            ],
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
    final effective = _effectiveTrack;
    final (normX, normY) = _currentSampledPosition(_positionSeconds);
    final faces = _faceMarkersAt(_positionSeconds);

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: aspect,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final previewW = constraints.maxWidth;
                final previewH = constraints.maxHeight;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Drag the purple crop box directly on the video.
                  onPanStart: (_) => _onCropPanStart(),
                  onPanUpdate: (details) => _onCropPanUpdate(
                    details.delta.dx,
                    details.delta.dy,
                    previewW,
                    previewH,
                  ),
                  onPanEnd: (_) => _onCropPanEnd(),
                  onTapUp: (details) {
                    if (previewW <= 0 || previewH <= 0) return;
                    final rawX =
                        (details.localPosition.dx / previewW).clamp(0.0, 1.0);
                    final rawY =
                        (details.localPosition.dy / previewH).clamp(0.0, 1.0);
                    if (_editMode) {
                      // Edit mode: tap places the crop center right there.
                      final (cx, cy) = _clampCropCenter(
                        rawX,
                        rawY,
                        previewW,
                        previewH,
                      );
                      _upsertManualKeyframeAt(_positionSeconds, cx, cy);
                      return;
                    }
                    _onPreviewTap(rawX, rawY);
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoPlayer(controller),
                      CustomPaint(
                        painter: ReframeOverlayPainter(
                          targetAspect: _config.aspectRatio,
                          outW: _config.outputSize.$1,
                          outH: _config.outputSize.$2,
                          frameFill: _config.frameFillClamped,
                          normX: normX,
                          normY: normY,
                          style: _config.style,
                          speakerLocked: effective != null,
                          faces: faces,
                        ),
                      ),
                      if (_editMode)
                        const Positioned(
                          left: 8,
                          top: 8,
                          child: _EditModeBadge(),
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
                );
              },
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

  // ---------------------------------------------------------------------------
  // Interactive keyframe editor
  // ---------------------------------------------------------------------------

  Widget _buildKeyframeEditor() {
    final keyframes = _workingKeyframes;
    final duration = _durationSeconds > 0 ? _durationSeconds : 0.0;
    final position = _positionSeconds.clamp(0.0, duration > 0 ? duration : 0.0);
    final currentIdx = _nearestKfIndex(position);
    final selected = currentIdx >= 0 ? keyframes[currentIdx] : null;
    final hasPrev = keyframes.any((k) => k.timeSec < position - 0.05);
    final hasNext = keyframes.any((k) => k.timeSec > position + 0.05);

    return Card(
      color: AppColors.surfaceLight,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Keyframe Editor',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                FilterChip(
                  avatar: Icon(
                    Icons.edit,
                    size: 16,
                    color: _editMode ? Colors.black : AppColors.textTertiary,
                  ),
                  label: const Text('Edit Keyframes'),
                  selected: _editMode,
                  visualDensity: VisualDensity.compact,
                  onSelected: (value) => setState(() => _editMode = value),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Drag the crop box on the video (or tap with Edit Keyframes on) '
              'to place keyframes.',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 8),

            // Visual keyframe timeline: AI cyan, manual gold, active magenta;
            // filled diamond = instant cut, hollow = smooth pan.
            SizedBox(
              height: 46,
              width: double.infinity,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      if (duration <= 0 || keyframes.isEmpty) return;
                      final tapped =
                          details.localPosition.dx.clamp(0.0, width);
                      final tappedTime = tapped / width * duration;
                      // Snap to a marker within ~14px, else plain seek.
                      var target = tappedTime;
                      var bestDelta = 14.0 / width * duration;
                      for (final kf in keyframes) {
                        final delta = (kf.timeSec - tappedTime).abs();
                        if (delta <= bestDelta) {
                          bestDelta = delta;
                          target = kf.timeSec;
                        }
                      }
                      _seekToTime(target);
                    },
                    child: CustomPaint(
                      size: Size(width, 46),
                      painter: KeyframeTimelinePainter(
                        keyframes: keyframes,
                        duration: duration,
                        position: position,
                        selectedIndex: currentIdx,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '◆ AI cyan · ◆ manual gold · ◆ active magenta · '
              'filled = cut · hollow = smooth',
              style: TextStyle(fontSize: 10, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 8),

            // Keyframe action toolbar.
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _editorButton(
                  icon: Icons.chevron_left,
                  label: 'Prev KF',
                  onPressed:
                      hasPrev ? () => _jumpKeyframe(-1) : null,
                ),
                _editorButton(
                  icon: Icons.chevron_right,
                  label: 'Next KF',
                  onPressed:
                      hasNext ? () => _jumpKeyframe(1) : null,
                ),
                _editorButton(
                  icon: Icons.add_location_alt,
                  label: 'Add / Set KF',
                  onPressed: duration > 0
                      ? _addOrSetKeyframeAtPlayhead
                      : null,
                ),
                _editorButton(
                  icon: selected != null && !selected.isCut
                      ? Icons.waves
                      : Icons.flash_on,
                  label: selected == null
                      ? 'Cut / Smooth'
                      : (selected.isCut ? 'Cut ⚡' : 'Smooth 〰️'),
                  highlighted: selected?.isCut ?? false,
                  onPressed:
                      selected != null ? _toggleCutForCurrentKeyframe : null,
                ),
                _editorButton(
                  icon: Icons.delete_outline,
                  label: 'Delete 🗑️',
                  onPressed: _workingKeyframes.length > 1
                      ? _deleteCurrentKeyframe
                      : null,
                ),
                _editorButton(
                  icon: Icons.restart_alt,
                  label: 'Reset AI ↺',
                  onPressed: _aiKeyframes.isNotEmpty ? _resetKeyframes : null,
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Scrollable keyframe chips.
            if (keyframes.isNotEmpty)
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: keyframes.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) {
                    final kf = keyframes[i];
                    final marker =
                        '${kf.isManual ? '✋' : ''}${kf.isCut ? '⚡' : '〰️'}';
                    return ChoiceChip(
                      label: Text(
                        '#${i + 1} ${_formatTime(kf.timeSec)} $marker',
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: i == currentIdx,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => _seekToTime(kf.timeSec),
                    );
                  },
                ),
              )
            else
              const Text(
                'No keyframes yet — play the video and press '
                '"Add / Set KF", or drag the crop box.',
                style:
                    TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _editorButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool highlighted = false,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        foregroundColor:
            highlighted ? const Color(0xFFE040FB) : null,
      ),
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

  /// `45% .. 100%` video-fill slider with quick presets. Lower fill widens the
  /// crop (more scene visible) and adds proportional black bars.
  Widget _buildFrameFillControl() {
    final fill = _config.frameFillClamped;
    final (outW, outH) = _config.outputSize;
    final box = FfmpegAutoReframeService.innerBoxForFill(
      outW: outW,
      outH: outH,
      frameFill: fill,
    );
    final barText = outH >= outW
        ? 'Black bars: '
            '${(((outH - box.boxH) / 2) / outH * 100).toStringAsFixed(0)}% '
            'top + bottom'
        : 'Black bars: '
            '${(((outW - box.boxW) / 2) / outW * 100).toStringAsFixed(0)}% '
            'left + right';

    const presets = <(double, String)>[
      (1.0, '100% Full'),
      (0.8, '80%'),
      (0.65, '65%'),
      (0.5, '50%'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Video Fill / Black Space',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              '${(fill * 100).toStringAsFixed(0)}%',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE040FB),
              ),
            ),
          ],
        ),
        Slider(
          value: fill,
          min: 0.45,
          max: 1.0,
          divisions: 106,
          label: '${(fill * 100).toStringAsFixed(0)}%',
          onChanged: (value) =>
              setState(() => _config = _config.copyWith(frameFill: value)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (value, label) in presets)
              ChoiceChip(
                label: Text(label),
                selected: (fill - value).abs() < 0.005,
                onSelected: (_) =>
                    setState(() => _config = _config.copyWith(frameFill: value)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Lower fill shows more of the scene around the speaker · $barText',
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  /// `Auto Active Speaker` + one chip per detected person; tapping a face on
  /// the preview selects the same person.
  Widget _buildSpeakerSelector() {
    final track = _track;
    if (track == null || track.speakers.isEmpty) return const SizedBox.shrink();
    final selectedId = _config.selectedSpeakerId;
    String? selectedLabel;
    for (final profile in track.speakers) {
      if (profile.id == selectedId) selectedLabel = profile.label;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Target Face / Speaker',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              avatar: Icon(
                Icons.record_voice_over,
                size: 18,
                color: selectedId == null
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              label: const Text('Auto Active Speaker'),
              selected: selectedId == null,
              onSelected: (_) => _selectSpeaker(null),
            ),
            for (final profile in track.speakers)
              ChoiceChip(
                avatar: Icon(
                  Icons.person,
                  size: 18,
                  color: selectedId == profile.id
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                label: Text(profile.label),
                selected: selectedId == profile.id,
                onSelected: (_) => _selectSpeaker(profile.id),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          selectedId == null
              ? 'Switches to whoever is speaking · tap a face to lock'
              : 'Locked on $selectedLabel · tap a face to switch',
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
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

/// One detected person drawn on the preview (average trajectory position at
/// the current instant).
class ReframeFaceMarker {
  final double normX;
  final double normY;
  final String label;
  final bool locked;

  const ReframeFaceMarker({
    required this.normX,
    required this.normY,
    required this.label,
    this.locked = false,
  });
}

/// Live overlay: dimmed area outside the crop window, all detected faces with
/// the selected speaker highlighted, black-bar bands for `frameFill`, and a
/// "Speaker Locked" marker.
class ReframeOverlayPainter extends CustomPainter {
  final double targetAspect;
  final int outW;
  final int outH;
  final double frameFill;
  final double normX;
  final double normY;
  final AutoReframeStyle style;
  final bool speakerLocked;
  final List<ReframeFaceMarker> faces;

  const ReframeOverlayPainter({
    required this.targetAspect,
    required this.outW,
    required this.outH,
    required this.frameFill,
    required this.normX,
    required this.normY,
    required this.style,
    required this.speakerLocked,
    this.faces = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Mirror the FFmpeg geometry exactly: effective aspect of the inner box
    // after `frameFill`, then the source crop window, then the black bars.
    final fill = frameFill.clamp(0.45, 1.0);
    var boxW = outW;
    var boxH = outH;
    if (fill < 0.99) {
      final box = FfmpegAutoReframeService.innerBoxForFill(
        outW: outW,
        outH: outH,
        frameFill: fill,
      );
      boxW = box.boxW;
      boxH = box.boxH;
    }
    final effectiveAspect = boxW / boxH > 0 ? boxW / boxH : 1.0;

    double cropW;
    double cropH;
    if (size.width / size.height > effectiveAspect) {
      cropH = size.height;
      cropW = cropH * effectiveAspect;
    } else {
      cropW = size.width;
      cropH = cropW / effectiveAspect;
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

    // Black bars added by `pad=...:black`, drawn at the exact final proportion
    // inside the crop window (portrait → top/bottom, landscape → left/right).
    // The preview must NOT hide the speaker's face with opaque bars: use a
    // translucent letterbox band + dashed guide lines instead, so the full
    // cropped area stays visible while dragging the box.
    final portrait = outH >= outW;
    final barFraction = (1 - (portrait ? boxH / outH : boxW / outW)) / 2;
    if (barFraction > 0.004) {
      final barPaint = Paint()..color = Colors.black26;
      final guidePaint = Paint()
        ..color = Colors.white70
        ..strokeWidth = 1.2;
      if (portrait) {
        final barH = cropRect.height * barFraction;
        canvas.drawRect(
          Rect.fromLTWH(cropRect.left, cropRect.top, cropRect.width, barH),
          barPaint,
        );
        canvas.drawRect(
          Rect.fromLTWH(
            cropRect.left,
            cropRect.bottom - barH,
            cropRect.width,
            barH,
          ),
          barPaint,
        );
        _drawDashedLine(
          canvas,
          Offset(cropRect.left, cropRect.top + barH),
          Offset(cropRect.right, cropRect.top + barH),
          guidePaint,
        );
        _drawDashedLine(
          canvas,
          Offset(cropRect.left, cropRect.bottom - barH),
          Offset(cropRect.right, cropRect.bottom - barH),
          guidePaint,
        );
      } else {
        final barW = cropRect.width * barFraction;
        canvas.drawRect(
          Rect.fromLTWH(cropRect.left, cropRect.top, barW, cropRect.height),
          barPaint,
        );
        canvas.drawRect(
          Rect.fromLTWH(
            cropRect.right - barW,
            cropRect.top,
            barW,
            cropRect.height,
          ),
          barPaint,
        );
        _drawDashedLine(
          canvas,
          Offset(cropRect.left + barW, cropRect.top),
          Offset(cropRect.left + barW, cropRect.bottom),
          guidePaint,
        );
        _drawDashedLine(
          canvas,
          Offset(cropRect.right - barW, cropRect.top),
          Offset(cropRect.right - barW, cropRect.bottom),
          guidePaint,
        );
      }
    }

    // Every detected person; the selected speaker gets a filled highlight.
    for (final face in faces) {
      final center = Offset(face.normX * size.width, face.normY * size.height);
      final color = face.locked
          ? const Color(0xFFE040FB)
          : const Color(0xFF00E5FF);
      canvas.drawCircle(
        center,
        15,
        Paint()
          ..color = color.withValues(alpha: face.locked ? 0.35 : 0.18),
      );
      canvas.drawCircle(
        center,
        15,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = face.locked ? 3 : 1.6,
      );
      if (face.locked) {
        final label = TextPainter(
          text: TextSpan(
            text: face.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              backgroundColor: Color(0xAA9C27B0),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(
          canvas,
          Offset(
            (center.dx - label.width / 2).clamp(0.0, size.width - label.width),
            (center.dy + 18).clamp(0.0, size.height - label.height),
          ),
        );
      }
    }

    // Crosshair at the actual tracked face center (the crop center).
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

  /// Dashed helper line for the letterbox guide in the preview.
  static void _drawDashedLine(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint, {
    double dash = 8,
    double gap = 6,
  }) {
    final total = (to - from).distance;
    if (total <= 0) return;
    final unit = (to - from) / total;
    var traveled = 0.0;
    while (traveled < total) {
      final dashEnd = min(traveled + dash, total);
      canvas.drawLine(
        from + unit * traveled,
        from + unit * dashEnd,
        paint,
      );
      traveled = dashEnd + gap;
    }
  }

  @override
  bool shouldRepaint(covariant ReframeOverlayPainter oldDelegate) {
    return oldDelegate.normX != normX ||
        oldDelegate.normY != normY ||
        oldDelegate.targetAspect != targetAspect ||
        oldDelegate.outW != outW ||
        oldDelegate.outH != outH ||
        oldDelegate.frameFill != frameFill ||
        oldDelegate.style != style ||
        oldDelegate.speakerLocked != speakerLocked ||
        oldDelegate.faces.length != faces.length;
  }
}

/// Small hint badge shown on the preview while "Edit Keyframes" mode is on.
class _EditModeBadge extends StatelessWidget {
  const _EditModeBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xCCCDDC39),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit, size: 14, color: Colors.black),
          SizedBox(width: 4),
          Text(
            'Edit mode: tap/drag to move crop',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}

/// Timeline strip painting diamond keyframe markers.
///
/// * AI keyframes: cyan `#00E5FF`
/// * manual/edited keyframes: amber `#FFD54F`
/// * nearest/active keyframe: magenta `#E040FB` (drawn larger)
/// * `isCut` keyframes are **filled** diamonds, smooth ones are **hollow**
class KeyframeTimelinePainter extends CustomPainter {
  final List<FaceTrackPoint> keyframes;
  final double duration;
  final double position;
  final int selectedIndex;

  const KeyframeTimelinePainter({
    required this.keyframes,
    required this.duration,
    required this.position,
    required this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final midY = size.height / 2;

    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      Paint()
        ..color = Colors.white24
        ..strokeWidth = 2,
    );

    // Playhead marker.
    if (duration > 0) {
      final playX = (position / duration).clamp(0.0, 1.0) * size.width;
      canvas.drawLine(
        Offset(playX, 3),
        Offset(playX, size.height - 3),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.4,
      );
    }

    if (duration <= 0) return;
    for (var i = 0; i < keyframes.length; i++) {
      final kf = keyframes[i];
      final x = (kf.timeSec / duration).clamp(0.0, 1.0) * size.width;
      final selected = i == selectedIndex;
      final color = selected
          ? const Color(0xFFE040FB)
          : (kf.isManual
              ? const Color(0xFFFFD54F)
              : const Color(0xFF00E5FF));
      final radius = selected ? 8.0 : 5.5;
      final diamond = Path()
        ..moveTo(x, midY - radius)
        ..lineTo(x + radius, midY)
        ..lineTo(x, midY + radius)
        ..lineTo(x - radius, midY)
        ..close();

      if (kf.isCut) {
        // Instant cut: filled diamond.
        canvas.drawPath(diamond, Paint()..color = color);
        if (selected) {
          canvas.drawPath(
            diamond,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4,
          );
        }
      } else {
        // Smooth pan: hollow diamond.
        canvas.drawPath(
          diamond,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant KeyframeTimelinePainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.duration != duration ||
        oldDelegate.selectedIndex != selectedIndex ||
        oldDelegate.keyframes.length != keyframes.length ||
        !_sameKeyframes(oldDelegate.keyframes, keyframes);
  }

  static bool _sameKeyframes(
    List<FaceTrackPoint> a,
    List<FaceTrackPoint> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].timeSec != b[i].timeSec ||
          a[i].normX != b[i].normX ||
          a[i].normY != b[i].normY ||
          a[i].isCut != b[i].isCut ||
          a[i].isManual != b[i].isManual) {
        return false;
      }
    }
    return true;
  }
}
