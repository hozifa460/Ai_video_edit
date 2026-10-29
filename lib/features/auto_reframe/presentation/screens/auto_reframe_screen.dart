import 'dart:io';
import 'dart:math';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/services/face_detection_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/logger.dart';
import '../../data/services/ffmpeg_auto_reframe_service.dart';
import '../../domain/entities/reframe_config.dart';

class AutoReframeScreen extends StatefulWidget {
  final String videoPath;

  const AutoReframeScreen({super.key, required this.videoPath});

  static (double, double) clampCenterForAspect(
    double normX,
    double normY,
    double previewW,
    double previewH,
    double effectiveAspect,
  ) {
    if (previewW <= 0 || previewH <= 0) return (normX, normY);
    final sourceAspect = previewW / previewH;
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

  static (double, double) dragStepCenter({
    required (double, double) origin,
    required double deltaXPx,
    required double deltaYPx,
    required double previewW,
    required double previewH,
    required double effectiveAspect,
  }) {
    if (previewW <= 0 || previewH <= 0) return origin;
    return clampCenterForAspect(
      origin.$1 + deltaXPx / previewW,
      origin.$2 + deltaYPx / previewH,
      previewW,
      previewH,
      effectiveAspect,
    );
  }

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
  FaceTrackResult? _effectiveTrack;

  List<SceneShot> _shots = const [];
  final Map<int, ShotTrackingOverride> _shotOverrides =
      <int, ShotTrackingOverride>{};

  List<FaceTrackPoint> _aiKeyframes = const [];
  List<FaceTrackPoint> _workingKeyframes = const [];

  static const double magneticSnapPx = 12.0;
  double? _lastSnappedKfSec;
  (double, double)? _dragOrigin;

  bool _cameraViewMode = true;
  bool _showTapBoxesOnPreview = true;

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
      _analysisStatus = 'جاري تجهيز محرك التتبع الصوتي والبصري...';
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
      _shotOverrides.clear();
      if (result == null) {
        _analysisStatus = 'No face found — center crop will be used';
        _shots = _durationSeconds > 0
            ? [SceneShot(id: 0, startSec: 0, endSec: _durationSeconds)]
            : const [];
      } else {
        _shots = result.shots.isNotEmpty
            ? List<SceneShot>.of(result.shots)
            : [
                SceneShot(
                  id: 0,
                  startSec: 0,
                  endSec: max(
                    _durationSeconds,
                    result.rawPoints.isNotEmpty
                        ? result.rawPoints.last.timeSec
                        : 1.0,
                  ),
                ),
              ];
      }
      _recomputeEffectiveTrack();
    });
  }

  void _recomputeEffectiveTrack() {
    final track = _track;
    if (track == null) {
      _effectiveTrack = null;
      _aiKeyframes = const [];
      _workingKeyframes = const [];
      return;
    }

    final globalSpeakerId = _config.selectedSpeakerId;
    List<FaceTrackPoint> computedKeyframes;

    if (_shots.isNotEmpty &&
        (_shotOverrides.isNotEmpty || globalSpeakerId != null)) {
      computedKeyframes = FaceDetectionService.buildKeyframesWithShotOverrides(
        track: track,
        shots: _shots,
        shotOverrides: _shotOverrides,
        globalSpeakerId: globalSpeakerId,
        deadZone: _config.motion.deadZone,
        smoothness: _config.motion.smoothness,
      );
    } else if (globalSpeakerId != null) {
      DetectedSpeakerProfile? profile;
      for (final candidate in track.speakers) {
        if (candidate.id == globalSpeakerId) {
          profile = candidate;
          break;
        }
      }
      computedKeyframes = profile != null
          ? FaceDetectionService.buildKeyframes(
              profile.rawPoints,
              deadZone: _config.motion.deadZone,
              smoothness: _config.motion.smoothness,
            )
          : track.keyframes;
    } else {
      computedKeyframes = FaceDetectionService.buildKeyframes(
        track.rawPoints,
        deadZone: _config.motion.deadZone,
        smoothness: _config.motion.smoothness,
      );
    }

    final resolved = FaceTrackResult(
      rawPoints: track.rawPoints,
      keyframes: computedKeyframes,
      avgNormX: track.avgNormX,
      avgNormY: track.avgNormY,
      facesDetectedCount: track.facesDetectedCount,
      speakers: track.speakers,
      shots: _shots,
      sourceWidth: track.sourceWidth,
      sourceHeight: track.sourceHeight,
    );

    _effectiveTrack = resolved;
    _aiKeyframes = FaceDetectionService.normalizeKeyframesForEditing(
      resolved.keyframes,
    );
    _workingKeyframes = List<FaceTrackPoint>.of(_aiKeyframes);
  }

  int _currentShotIndexAt(double timeSec) {
    if (_shots.isEmpty) return -1;
    for (var i = 0; i < _shots.length; i++) {
      if (_shots[i].contains(timeSec)) return i;
    }
    if (timeSec <= _shots.first.startSec) return 0;
    return _shots.length - 1;
  }

  SceneShot? _currentShotAt(double timeSec) {
    final idx = _currentShotIndexAt(timeSec);
    return idx >= 0 && idx < _shots.length ? _shots[idx] : null;
  }

  void _splitShotAtPlayhead() {
    if (_shots.isEmpty) {
      if (_durationSeconds <= 0.6) return;
      setState(() {
        _shots = [
          SceneShot(id: 0, startSec: 0, endSec: _durationSeconds),
        ];
      });
    }
    final t = _positionSeconds;
    final idx = _currentShotIndexAt(t);
    if (idx < 0) return;
    final shot = _shots[idx];
    if (t - shot.startSec < 0.30 || shot.endSec - t < 0.30) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'حرك المؤشر داخل اللقطة (بفارق 0.3 ثانية على الأقل عن البداية/النهاية) لتقسيمها',
          ),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final maxId = _shots.fold<int>(0, (m, s) => max(m, s.id));
    final firstHalf = SceneShot(
      id: shot.id,
      startSec: shot.startSec,
      endSec: t,
    );
    final secondHalf = SceneShot(
      id: maxId + 1,
      startSec: t,
      endSec: shot.endSec,
    );

    setState(() {
      final updated = List<SceneShot>.of(_shots);
      updated[idx] = firstHalf;
      updated.insert(idx + 1, secondHalf);
      if (_shotOverrides.containsKey(shot.id)) {
        _shotOverrides[secondHalf.id] = _shotOverrides[shot.id]!;
      }
      _shots = updated;
      _recomputeEffectiveTrack();
    });
    HapticFeedback.mediumImpact();
  }

  void _mergeCurrentShot() {
    if (_shots.length <= 1) return;
    final idx = _currentShotIndexAt(_positionSeconds);
    if (idx < 0) return;
    setState(() {
      final updated = List<SceneShot>.of(_shots);
      if (idx > 0) {
        final prev = updated[idx - 1];
        final curr = updated[idx];
        updated[idx - 1] = prev.copyWith(endSec: curr.endSec);
        _shotOverrides.remove(curr.id);
        updated.removeAt(idx);
      } else {
        final curr = updated[0];
        final next = updated[1];
        updated[0] = curr.copyWith(endSec: next.endSec);
        _shotOverrides.remove(next.id);
        updated.removeAt(1);
      }
      _shots = updated;
      _recomputeEffectiveTrack();
    });
  }

  void _jumpShot(int direction) {
    if (_shots.isEmpty) return;
    final idx = _currentShotIndexAt(_positionSeconds);
    if (idx < 0) return;
    if (direction < 0) {
      final current = _shots[idx];
      if (_positionSeconds - current.startSec > 0.4) {
        _seekToTime(current.startSec + 0.02);
      } else if (idx > 0) {
        _seekToTime(_shots[idx - 1].startSec + 0.02);
      } else {
        _seekToTime(0);
      }
    } else {
      if (idx + 1 < _shots.length) {
        _seekToTime(_shots[idx + 1].startSec + 0.02);
      }
    }
  }

  void _setShotModeAutoSpeaker(SceneShot shot) {
    setState(() {
      _shotOverrides[shot.id] = const ShotTrackingOverride(
        mode: ShotLockMode.autoSpeaker,
      );
      _recomputeEffectiveTrack();
    });
  }

  void _setShotModePerson(SceneShot shot, int speakerId) {
    setState(() {
      _shotOverrides[shot.id] = ShotTrackingOverride(
        mode: ShotLockMode.specificPerson,
        speakerId: speakerId,
      );
      _recomputeEffectiveTrack();
    });
  }

  void _setShotModeStaticPosition(
    SceneShot shot,
    double normX,
    double normY,
  ) {
    setState(() {
      _shotOverrides[shot.id] = ShotTrackingOverride(
        mode: ShotLockMode.staticPosition,
        staticNormX: normX,
        staticNormY: normY,
      );
      _recomputeEffectiveTrack();
    });
  }

  void _toggleTapLockOnPerson(DetectedSpeakerProfile profile) {
    HapticFeedback.selectionClick();
    final currentShot = _currentShotAt(_positionSeconds);
    if (currentShot != null) {
      final existing = _shotOverrides[currentShot.id];
      final alreadyLocked = existing?.mode == ShotLockMode.specificPerson &&
          existing?.speakerId == profile.id;
      if (alreadyLocked) {
        _setShotModeAutoSpeaker(currentShot);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '🎤 تم إلغاء القفل والعودة لتتبع المتكلم تلقائياً في هذه اللقطة',
            ),
            duration: Duration(milliseconds: 1300),
          ),
        );
      } else {
        _setShotModePerson(currentShot, profile.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🔒 تم تثبيت اللقطة الحالية على ${profile.label}',
            ),
            duration: const Duration(milliseconds: 1300),
          ),
        );
      }
    } else {
      final nextId = _config.selectedSpeakerId == profile.id ? null : profile.id;
      _selectSpeaker(nextId);
    }
  }

  (double, double) _currentSampledPosition(double timeSec) {
    final keyframes = _workingKeyframes;
    if (keyframes.isEmpty) {
      return _effectiveTrack?.sampleAt(timeSec) ?? (0.5, 0.42);
    }
    return FaceTrackResult.sampleKeyframes(keyframes, timeSec);
  }

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

  void _upsertManualKeyframeAt(double timeSec, double normX, double normY) {
    final currentShot = _currentShotAt(timeSec);
    final currentOverride =
        currentShot != null ? _shotOverrides[currentShot.id] : null;
    if (currentShot != null &&
        currentOverride?.mode == ShotLockMode.staticPosition) {
      _setShotModeStaticPosition(currentShot, normX, normY);
      return;
    }
    setState(() {
      _workingKeyframes = FaceDetectionService.upsertManualKeyframe(
        _workingKeyframes,
        timeSec: timeSec,
        normX: normX,
        normY: normY,
        isCut: false,
        clearNearbyAiKeyframes: true,
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

  int _keyframeAtPlayheadIndex() {
    final keyframes = _workingKeyframes;
    if (keyframes.isEmpty) return -1;
    var best = -1;
    var bestDelta = FaceDetectionService.manualKeyframeToleranceSec;
    for (var i = 0; i < keyframes.length; i++) {
      final delta = (keyframes[i].timeSec - _positionSeconds).abs();
      if (delta <= bestDelta) {
        bestDelta = delta;
        best = i;
      }
    }
    return best;
  }

  void _smartKeyframeToggle() {
    final index = _keyframeAtPlayheadIndex();
    if (index >= 0) {
      _deleteKeyframeAt(index);
      return;
    }
    final (x, y) = _currentSampledPosition(_positionSeconds);
    _upsertManualKeyframeAt(_positionSeconds, x, y);
  }

  void _deleteKeyframeAt(int index) {
    setState(() {
      _workingKeyframes = FaceDetectionService.deleteKeyframe(
        _workingKeyframes,
        index,
      );
    });
  }

  void _centerCurrentKeyframe() {
    final onIdx = _keyframeAtPlayheadIndex();
    final index = onIdx >= 0 ? onIdx : _nearestKfIndex(_positionSeconds);
    if (index < 0) return;
    setState(() {
      final updated = List<FaceTrackPoint>.of(_workingKeyframes);
      updated[index] = updated[index].copyWith(
        normX: 0.5,
        normY: 0.45,
        isCut: false,
        isManual: true,
      );
      _workingKeyframes = updated;
    });
  }

  void _clearAllKeyframes() {
    setState(() {
      _shotOverrides.clear();
      _workingKeyframes = [
        const FaceTrackPoint(
          timeSec: 0,
          normX: 0.5,
          normY: 0.45,
          isCut: false,
          isManual: true,
        ),
      ];
    });
  }

  void _toggleCutForCurrentKeyframe() {
    final onIdx = _keyframeAtPlayheadIndex();
    final index = onIdx >= 0 ? onIdx : _nearestKfIndex(_positionSeconds);
    if (index < 0) return;
    setState(() {
      final updated = List<FaceTrackPoint>.of(_workingKeyframes);
      final point = updated[index];
      updated[index] = point.copyWith(isCut: !point.isCut, isManual: true);
      _workingKeyframes = updated;
    });
  }

  void _resetKeyframes() {
    setState(() {
      _shotOverrides.clear();
      _recomputeEffectiveTrack();
    });
  }

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

  double _effectiveCropAspect() {
    final (outW, outH) = _config.outputSize;
    final box = FfmpegAutoReframeService.innerBoxForFill(
      outW: outW,
      outH: outH,
      frameFill: _config.frameFillClamped,
    );
    return box.boxW / box.boxH;
  }

  (double, double) _clampCropCenter(
    double normX,
    double normY,
    double previewW,
    double previewH,
  ) {
    return AutoReframeScreen.clampCenterForAspect(
      normX,
      normY,
      previewW,
      previewH,
      _effectiveCropAspect(),
    );
  }

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
    final (clampedX, clampedY) = _clampCropCenter(
      origin.$1 + deltaXPx / previewW,
      origin.$2 + deltaYPx / previewH,
      previewW,
      previewH,
    );
    _dragOrigin = (clampedX, clampedY);
    _upsertManualKeyframeAt(_positionSeconds, clampedX, clampedY);
  }

  void _onCropPanEnd() => _dragOrigin = null;

  void _selectSpeaker(int? speakerId) {
    setState(() {
      _config = _config.copyWith(selectedSpeakerId: speakerId);
      _recomputeEffectiveTrack();
    });
  }

  static const double tapLockDistance = 0.14;

  bool _selectSpeakerNearTap(double normX, double normY) {
    final track = _track;
    if (track == null || track.speakers.isEmpty) return false;
    DetectedSpeakerProfile? nearest;
    var bestScore = double.infinity;

    for (final profile in track.speakers) {
      final sample = _sampleProfileAt(profile, _positionSeconds);
      final px = sample.normX;
      final py = sample.normY;
      final halfW = max(0.08, sample.normW * 0.85);
      final halfH = max(0.12, sample.normH * 1.15);

      final insideBox = (normX - px).abs() <= halfW &&
          (normY >= py - halfH * 0.65 && normY <= py + halfH * 1.35);
      final dx = px - normX;
      final dy = py - normY;
      final distSq = dx * dx + dy * dy;
      final effScore = insideBox ? distSq * 0.25 : distSq;

      if (effScore < bestScore &&
          (insideBox || distSq < tapLockDistance * tapLockDistance)) {
        bestScore = effScore;
        nearest = profile;
      }
    }
    if (nearest == null) return false;
    _toggleTapLockOnPerson(nearest);
    return true;
  }

  static FaceTrackPoint _sampleProfileAt(
    DetectedSpeakerProfile profile,
    double timeSec,
  ) {
    final points = profile.rawPoints;
    if (points.isEmpty) {
      return FaceTrackPoint(
        timeSec: timeSec,
        normX: profile.avgNormX,
        normY: profile.avgNormY,
        normW: profile.avgNormW,
        normH: profile.avgNormH,
      );
    }
    var best = points.first;
    var bestDelta = double.infinity;
    for (final point in points) {
      final delta = (point.timeSec - timeSec).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = point;
      }
    }
    return best;
  }

  List<ReframeFaceMarker> _faceMarkersAt(double timeSec) {
    final track = _track;
    if (track == null || track.speakers.isEmpty) return const [];
    final currentShot = _currentShotAt(timeSec);
    final shotOverride =
        currentShot != null ? _shotOverrides[currentShot.id] : null;
    final lockedSpeakerId =
        shotOverride?.mode == ShotLockMode.specificPerson
            ? shotOverride?.speakerId
            : _config.selectedSpeakerId;

    final (activeX, activeY) = track.sampleAt(timeSec);
    int? aiActiveSpeakerId;
    var bestDist = 0.09;
    for (final profile in track.speakers) {
      final pt = _sampleProfileAt(profile, timeSec);
      if ((pt.timeSec - timeSec).abs() > 1.8) continue;
      final d = sqrt(
        (pt.normX - activeX) * (pt.normX - activeX) +
            (pt.normY - activeY) * (pt.normY - activeY),
      );
      if (d < bestDist) {
        bestDist = d;
        aiActiveSpeakerId = profile.id;
      }
    }

    final markers = <ReframeFaceMarker>[];
    for (final profile in track.speakers) {
      final pt = _sampleProfileAt(profile, timeSec);
      final visibleNow = (pt.timeSec - timeSec).abs() <= 2.2;
      if (!visibleNow && profile.id != lockedSpeakerId) continue;
      markers.add(
        ReframeFaceMarker(
          speakerId: profile.id,
          normX: pt.normX,
          normY: pt.normY,
          normW: pt.normW > 0 ? pt.normW : profile.avgNormW,
          normH: pt.normH > 0 ? pt.normH : profile.avgNormH,
          label: profile.label,
          locked: profile.id == lockedSpeakerId,
          isSpeaking: profile.id == aiActiveSpeakerId || pt.isSpeaking,
          hasVoiceFingerprint: profile.boundVoiceClusterId != null,
        ),
      );
    }
    return markers;
  }

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
          shots: _shots,
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
        preset: AspectRatioPreset.custom,
        customWidthRatio: width,
        customHeightRatio: height,
      ),
    );
  }

  Future<void> _render() async {
    if (_rendering) return;
    _controller?.pause();
    setState(() {
      _rendering = true;
      _error = null;
    });

    final tempDir = await getTemporaryDirectory();
    final outputPath =
        '${tempDir.path}/reframe_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final progress = ValueNotifier<double>(0);
    final status = ValueNotifier<String>('Starting FFmpeg...');
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Rendering Auto Reframe'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: value > 0 ? value : null),
                const SizedBox(height: 12),
                ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (_, text, _) => Text(
                    '${(value * 100).toStringAsFixed(0)}% · $text',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

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
            shots: _shots,
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
            tooltip: 'إظهار/إخفاء مربعات اللمس على الفيديو (Tap-to-Track)',
            onPressed: () => setState(
              () => _showTapBoxesOnPreview = !_showTapBoxesOnPreview,
            ),
            icon: Icon(
              _showTapBoxesOnPreview
                  ? Icons.touch_app
                  : Icons.touch_app_outlined,
              color: _showTapBoxesOnPreview ? const Color(0xFF00E676) : null,
            ),
          ),
          IconButton(
            tooltip: 'Re-Analyze Face & Voice',
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
            if (!_analyzing && _track != null) ...[
              _buildShotLockCard(),
              const SizedBox(height: 12),
            ],
            _buildKeyframeEditor(),
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
    final srcAspect = size.width > 0 && size.height > 0
        ? size.width / size.height
        : 16 / 9;
    final effective = _effectiveTrack;
    final (rawNormX, rawNormY) = _currentSampledPosition(_positionSeconds);
    final faceTracking = _config.style == AutoReframeStyle.smartFaceCrop;
    final normX = faceTracking ? rawNormX : 0.5;
    final normY = faceTracking ? rawNormY : 0.5;
    final faces = _faceMarkersAt(_positionSeconds);
    final effectiveAspect = _effectiveCropAspect();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(
                  value: true,
                  icon: Icon(Icons.videocam, size: 16),
                  label: Text('Camera View', style: TextStyle(fontSize: 12)),
                ),
                ButtonSegment<bool>(
                  value: false,
                  icon: Icon(Icons.crop_free, size: 16),
                  label: Text('Full Frame', style: TextStyle(fontSize: 12)),
                ),
              ],
              selected: {_cameraViewMode},
              onSelectionChanged: (s) =>
                  setState(() => _cameraViewMode = s.first),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_track != null && _track!.speakers.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        Icons.touch_app,
                        size: 15,
                        color: _showTapBoxesOnPreview
                            ? const Color(0xFF00E676)
                            : Colors.white54,
                      ),
                      label: Text(
                        _showTapBoxesOnPreview ? 'اللمس مفعل' : 'اللمس مخفي',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onPressed: () => setState(
                        () => _showTapBoxesOnPreview = !_showTapBoxesOnPreview,
                      ),
                    ),
                  ),
                IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    setState(() {
                      controller.value.isPlaying
                          ? controller.pause()
                          : controller.play();
                    });
                  },
                  icon: Icon(
                    controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_cameraViewMode &&
            _config.style != AutoReframeStyle.blurBackgroundFrame) ...[
          Container(
            height: 310,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFE040FB).withValues(alpha: 0.7),
                width: 1.5,
              ),
            ),
            child: Center(
              child: AspectRatio(
                aspectRatio: _config.aspectRatio,
                child: LayoutBuilder(
                  builder: (context, outerConstraints) {
                    final canvasW = outerConstraints.maxWidth;
                    final canvasH = outerConstraints.maxHeight;
                    final (outW, outH) = _config.outputSize;
                    final fill = _config.frameFillClamped;
                    final innerBox = FfmpegAutoReframeService.innerBoxForFill(
                      outW: outW,
                      outH: outH,
                      frameFill: fill,
                    );
                    final activeW = canvasW * (innerBox.boxW / outW);
                    final activeH = canvasH * (innerBox.boxH / outH);

                    final cropFracW = srcAspect > effectiveAspect
                        ? (effectiveAspect / srcAspect).clamp(0.05, 1.0)
                        : 1.0;
                    final cropFracH = srcAspect > effectiveAspect
                        ? 1.0
                        : (srcAspect / effectiveAspect).clamp(0.05, 1.0);
                    final halfW = cropFracW / 2;
                    final halfH = cropFracH / 2;
                    final cx = normX.clamp(halfW, 1.0 - halfW);
                    final cy = normY.clamp(halfH, 1.0 - halfH);

                    final fullVideoW = activeW / cropFracW;
                    final fullVideoH = activeH / cropFracH;
                    final offsetX = -(cx - halfW) * fullVideoW;
                    final offsetY = -(cy - halfH) * fullVideoH;

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => _onCropPanStart(),
                      onPanUpdate: (details) => _onCropPanUpdate(
                        -details.delta.dx,
                        -details.delta.dy,
                        fullVideoW,
                        fullVideoH,
                      ),
                      onPanEnd: (_) => _onCropPanEnd(),
                      onTapUp: (details) {
                        if (activeW <= 0 || activeH <= 0) return;
                        final padX = (canvasW - activeW) * 0.5;
                        final padY = (canvasH - activeH) * 0.5;
                        final localX =
                            ((details.localPosition.dx - padX) / activeW)
                                .clamp(0.0, 1.0);
                        final localY =
                            ((details.localPosition.dy - padY) / activeH)
                                .clamp(0.0, 1.0);
                        final srcTapX =
                            ((cx - halfW) + localX * cropFracW).clamp(0.0, 1.0);
                        final srcTapY =
                            ((cy - halfH) + localY * cropFracH).clamp(0.0, 1.0);
                        _selectSpeakerNearTap(srcTapX, srcTapY);
                      },
                      child: Container(
                        color: Colors.black,
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: activeW,
                          height: activeH,
                          child: ClipRect(
                            child: Stack(
                              clipBehavior: Clip.hardEdge,
                              children: [
                                Positioned(
                                  left: offsetX,
                                  top: offsetY,
                                  width: fullVideoW,
                                  height: fullVideoH,
                                  child: VideoPlayer(controller),
                                ),
                                if (_showTapBoxesOnPreview && faces.isNotEmpty)
                                  ..._buildCameraViewTapBoxes(
                                    faces: faces,
                                    cx: cx,
                                    cy: cy,
                                    halfW: halfW,
                                    halfH: halfH,
                                    cropFracW: cropFracW,
                                    cropFracH: cropFracH,
                                    activeW: activeW,
                                    activeH: activeH,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _buildCameraStripMiniMap(
            srcAspect: srcAspect,
            effectiveAspect: effectiveAspect,
            normX: normX,
            normY: normY,
            faces: faces,
          ),
        ] else
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: srcAspect,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final previewW = constraints.maxWidth;
                  final previewH = constraints.maxHeight;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
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
                      final tapX =
                          (details.localPosition.dx / previewW).clamp(0.0, 1.0);
                      final tapY =
                          (details.localPosition.dy / previewH).clamp(0.0, 1.0);
                      if (_selectSpeakerNearTap(tapX, tapY)) return;
                      final (cx, cy) = _clampCropCenter(
                        tapX,
                        tapY,
                        previewW,
                        previewH,
                      );
                      _upsertManualKeyframeAt(_positionSeconds, cx, cy);
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
                            faces: _showTapBoxesOnPreview ? faces : const [],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildCameraViewTapBoxes({
    required List<ReframeFaceMarker> faces,
    required double cx,
    required double cy,
    required double halfW,
    required double halfH,
    required double cropFracW,
    required double cropFracH,
    required double activeW,
    required double activeH,
  }) {
    final track = _track;
    if (track == null) return const [];
    final widgets = <Widget>[];

    for (final face in faces) {
      final relX = (face.normX - (cx - halfW)) / cropFracW;
      final relY = (face.normY - (cy - halfH)) / cropFracH;
      if (relX < -0.25 || relX > 1.25 || relY < -0.25 || relY > 1.25) {
        continue;
      }

      final double boxW = ((face.normW / cropFracW) * activeW * 1.25)
          .clamp(48.0, activeW * 0.78)
          .toDouble();
      final double boxH = ((face.normH / cropFracH) * activeH * 1.45)
          .clamp(58.0, activeH * 0.70)
          .toDouble();
      final double maxLeft = max<double>(2.0, activeW - boxW - 2.0);
      final double maxTop = max<double>(2.0, activeH - boxH - 2.0);
      final double left =
          (relX * activeW - boxW * 0.5).clamp(2.0, maxLeft).toDouble();
      final double top =
          (relY * activeH - boxH * 0.42).clamp(2.0, maxTop).toDouble();

      final Color borderColor;
      final String statusBadge;
      if (face.locked) {
        borderColor = const Color(0xFFE040FB);
        statusBadge = '🔒 مثبت';
      } else if (face.isSpeaking) {
        borderColor = const Color(0xFF00E676);
        statusBadge = '🎤 يتحدث';
      } else {
        borderColor = const Color(0xFF00E5FF);
        statusBadge = '👆 المس للتثبيت';
      }

      final shortName = face.label.split(' ').take(2).join(' ');

      widgets.add(
        Positioned(
          left: left,
          top: top,
          width: boxW,
          height: boxH,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: borderColor.withValues(
                    alpha: face.locked || face.isSpeaking ? 0.90 : 0.65,
                  ),
                  width: face.locked || face.isSpeaking ? 2.0 : 1.3,
                ),
              ),
              alignment: Alignment.topCenter,
              child: Transform.translate(
                offset: const Offset(0, -1),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: borderColor.withValues(alpha: 0.85),
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(5),
                    ),
                  ),
                  child: Text(
                    '$shortName · $statusBadge',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 8.5,
                      color: Colors.black,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _buildCameraStripMiniMap({
    required double srcAspect,
    required double effectiveAspect,
    required double normX,
    required double normY,
    required List<ReframeFaceMarker> faces,
  }) {
    final cropFracW = srcAspect > effectiveAspect
        ? (effectiveAspect / srcAspect).clamp(0.08, 1.0)
        : 1.0;
    final halfW = cropFracW / 2;
    final cx = normX.clamp(halfW, 1.0 - halfW);

    return SizedBox(
      height: 44,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stripW = constraints.maxWidth;
          final stripH = constraints.maxHeight;
          final winW = stripW * cropFracW;
          final winLeft = ((cx - halfW) * stripW).clamp(0.0, stripW - winW);

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _onCropPanStart(),
            onPanUpdate: (details) => _onCropPanUpdate(
              details.delta.dx,
              0,
              stripW,
              stripW / srcAspect,
            ),
            onPanEnd: (_) => _onCropPanEnd(),
            onTapUp: (details) {
              if (stripW <= 0) return;
              final tapX = (details.localPosition.dx / stripW).clamp(0.0, 1.0);
              if (_selectSpeakerNearTap(tapX, normY)) return;
              final (clampedX, clampedY) = _clampCropCenter(
                tapX,
                normY,
                stripW,
                stripW / srcAspect,
              );
              _upsertManualKeyframeAt(_positionSeconds, clampedX, clampedY);
            },
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24),
              ),
              child: Stack(
                children: [
                  for (final face in faces)
                    Positioned(
                      left: (face.normX * stripW - 26).clamp(2.0, stripW - 58),
                      top: 8,
                      child: GestureDetector(
                        onTap: () {
                          final track = _track;
                          if (track == null) return;
                          for (final p in track.speakers) {
                            if (p.id == face.speakerId) {
                              _toggleTapLockOnPerson(p);
                              break;
                            }
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: face.locked
                                ? const Color(0xFFE040FB)
                                : (face.isSpeaking
                                    ? const Color(0xFF00E676)
                                    : Colors.cyan.withValues(alpha: 0.80)),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${face.locked ? '🔒 ' : (face.isSpeaking ? '🎤 ' : '')}'
                            '${face.label.split(' ').take(2).join(' ')}',
                            style: TextStyle(
                              fontSize: 9.5,
                              color: face.isSpeaking && !face.locked
                                  ? Colors.black
                                  : Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: winLeft,
                    top: 2,
                    width: winW,
                    height: stripH - 4,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFFE040FB).withValues(alpha: 0.20),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFFE040FB),
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.open_with,
                          size: 14,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildShotLockCard() {
    final track = _track;
    if (track == null || _shots.isEmpty) return const SizedBox.shrink();

    final shotIdx = _currentShotIndexAt(_positionSeconds);
    if (shotIdx < 0 || shotIdx >= _shots.length) return const SizedBox.shrink();
    final shot = _shots[shotIdx];
    final override = _shotOverrides[shot.id];
    final effectiveMode = override?.mode ??
        (_config.selectedSpeakerId != null
            ? ShotLockMode.specificPerson
            : ShotLockMode.autoSpeaker);
    final activePersonId = override?.mode == ShotLockMode.specificPerson
        ? override?.speakerId
        : (override == null ? _config.selectedSpeakerId : null);

    return Card(
      color: AppColors.surfaceLight,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '🎯 تثبيت الهدف في اللقطة #${shotIdx + 1}/${_shots.length} '
                    '(${_formatTimeTenths(shot.startSec)} - ${_formatTimeTenths(shot.endSec)})',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (_shotOverrides.containsKey(shot.id))
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE040FB).withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'مُخصّص',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFFE040FB),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _editorButton(
                  icon: Icons.skip_previous,
                  label: '‹ اللقطة السابقة',
                  onPressed: _shots.length > 1 || _positionSeconds > 0.4
                      ? () => _jumpShot(-1)
                      : null,
                ),
                _editorButton(
                  icon: Icons.content_cut,
                  label: '✂️ تقسيم لقطة هنا',
                  highlighted: true,
                  onPressed: _splitShotAtPlayhead,
                ),
                if (_shots.length > 1)
                  _editorButton(
                    icon: Icons.merge_type,
                    label: 'دمج اللقطة',
                    onPressed: _mergeCurrentShot,
                  ),
                _editorButton(
                  icon: Icons.skip_next,
                  label: 'اللقطة التالية ›',
                  onPressed:
                      shotIdx + 1 < _shots.length ? () => _jumpShot(1) : null,
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'اختر لمن تثبت الكاميرا أثناء هذه اللقطة (أو المس الشخص مباشرة داخل الفيديو):',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  avatar: const Icon(Icons.record_voice_over, size: 16),
                  label: const Text(
                    'المتكلم تلقائياً (صوت + شفاه)',
                    style: TextStyle(fontSize: 12),
                  ),
                  selected: effectiveMode == ShotLockMode.autoSpeaker,
                  onSelected: (_) => _setShotModeAutoSpeaker(shot),
                ),
                for (final profile in track.speakers)
                  ChoiceChip(
                    avatar: const Icon(Icons.person_pin_circle, size: 16),
                    label: Text(
                      'تثبيت: ${profile.label}'
                      '${profile.boundVoiceClusterId != null ? ' 🔊' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: effectiveMode == ShotLockMode.specificPerson &&
                        activePersonId == profile.id,
                    onSelected: (_) => _setShotModePerson(shot, profile.id),
                  ),
                ChoiceChip(
                  avatar: const Icon(Icons.lock_outline, size: 16),
                  label: const Text(
                    'تثبيت الكاميرا هنا طوال اللقطة',
                    style: TextStyle(fontSize: 12),
                  ),
                  selected: effectiveMode == ShotLockMode.staticPosition,
                  onSelected: (_) {
                    final (cx, cy) = _currentSampledPosition(_positionSeconds);
                    _setShotModeStaticPosition(shot, cx, cy);
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '💡 ميزة Tap-to-Track: المس أي شخص مباشرة على شاشة الفيديو لقفل الكاميرا عليه في هذه اللقطة، والمسه مرة أخرى للعودة للتتبع التلقائي.',
              style: TextStyle(fontSize: 10.5, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyframeEditor() {
    final keyframes = _workingKeyframes;
    final currentIdx = _nearestKfIndex(_positionSeconds);
    final selected = currentIdx >= 0 ? keyframes[currentIdx] : null;
    final onPlayheadIdx = _keyframeAtPlayheadIndex();
    final onKeyframe = onPlayheadIdx >= 0;
    final duration = _durationSeconds;
    final position =
        duration > 0 ? _positionSeconds.clamp(0.0, duration) : 0.0;
    final (currX, currY) = _currentSampledPosition(_positionSeconds);
    final effectiveAspect = _effectiveCropAspect();
    final controllerSize = _controller?.value.size;
    final srcAspect =
        controllerSize != null &&
                controllerSize.width > 0 &&
                controllerSize.height > 0
            ? controllerSize.width / controllerSize.height
            : 16 / 9;
    final halfW = srcAspect > effectiveAspect
        ? (effectiveAspect / srcAspect).clamp(0.05, 1.0) / 2
        : 0.5;
    final minX = halfW.clamp(0.0, 0.49);
    final maxX = (1.0 - halfW).clamp(0.51, 1.0);
    final sliderX = currX.clamp(minX, maxX);

    return Card(
      color: AppColors.surfaceLight,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Keyframes · ${keyframes.length}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                Text(
                  '${_formatTimeTenths(position)} / '
                  '${_formatTimeTenths(duration)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.swap_horiz, size: 16, color: Color(0xFFE040FB)),
                const SizedBox(width: 6),
                const Text(
                  'تحريك الكاميرا:',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                Expanded(
                  child: Slider(
                    value: sliderX,
                    min: minX,
                    max: maxX,
                    onChangeStart: (_) {
                      final c = _controller;
                      if (c != null && c.value.isPlaying) c.pause();
                    },
                    onChanged: (newX) {
                      _upsertManualKeyframeAt(_positionSeconds, newX, currY);
                    },
                  ),
                ),
                Text(
                  '${(currX * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            _buildMagneticTimeline(
              keyframes: keyframes,
              duration: duration,
              position: position,
              currentIdx: currentIdx,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _editorButton(
                  icon: Icons.skip_previous,
                  label: '‹ Prev',
                  onPressed:
                      keyframes.isNotEmpty ? () => _jumpKeyframe(-1) : null,
                ),
                _editorButton(
                  icon: onKeyframe ? Icons.remove_circle_outline : Icons.add,
                  label: onKeyframe ? '◆- Delete KF' : '◆+ Add KF',
                  highlighted: onKeyframe,
                  onPressed: _smartKeyframeToggle,
                ),
                _editorButton(
                  icon: Icons.skip_next,
                  label: 'Next ›',
                  onPressed:
                      keyframes.isNotEmpty ? () => _jumpKeyframe(1) : null,
                ),
                _editorButton(
                  icon: (selected?.isCut ?? false)
                      ? Icons.flash_on
                      : Icons.timeline,
                  label: selected == null
                      ? 'Smooth 〰️'
                      : (selected.isCut ? 'Cut ⚡' : 'Smooth 〰️'),
                  highlighted: selected?.isCut ?? false,
                  onPressed:
                      selected != null ? _toggleCutForCurrentKeyframe : null,
                ),
                _editorButton(
                  icon: Icons.center_focus_strong,
                  label: 'Center ⌖',
                  onPressed: keyframes.isNotEmpty
                      ? _centerCurrentKeyframe
                      : null,
                ),
                _editorButton(
                  icon: Icons.delete_sweep,
                  label: 'Clear All 🗑️',
                  onPressed: _clearAllKeyframes,
                ),
                _editorButton(
                  icon: Icons.restart_alt,
                  label: 'Reset AI ↺',
                  onPressed: _aiKeyframes.isNotEmpty ? _resetKeyframes : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (keyframes.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: keyframes.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) {
                    final kf = keyframes[i];
                    final marker =
                        '${kf.isManual ? '✋' : ''}${kf.isCut ? '⚡' : '〰️'}';
                    return InputChip(
                      label: Text(
                        '#${i + 1} ${_formatTimeTenths(kf.timeSec)} $marker',
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: i == currentIdx,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => _seekToTime(kf.timeSec),
                      onDeleted: () => _deleteKeyframeAt(i),
                      deleteIcon: const Icon(Icons.cancel, size: 16),
                    );
                  },
                ),
              )
            else
              const Text(
                'No keyframes yet — drag the camera or press "◆+ Add KF".',
                style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMagneticTimeline({
    required List<FaceTrackPoint> keyframes,
    required double duration,
    required double position,
    required int currentIdx,
  }) {
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;

          double? scrubTime(double dx) {
            if (duration <= 0 || width <= 0) return null;
            final t = (dx.clamp(0.0, width) / width) * duration;
            final timeTolerance = magneticSnapPx / width * duration;
            var snapped = t;
            var bestDelta = timeTolerance;
            for (final kf in keyframes) {
              final delta = (kf.timeSec - t).abs();
              if (delta <= bestDelta) {
                bestDelta = delta;
                snapped = kf.timeSec;
              }
            }
            if ((snapped - t).abs() > 1e-9 && snapped != _lastSnappedKfSec) {
              _lastSnappedKfSec = snapped;
              HapticFeedback.selectionClick();
            }
            return snapped;
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (details) {
              _lastSnappedKfSec = null;
              final t = scrubTime(details.localPosition.dx);
              if (t != null) _seekToTime(t);
            },
            onHorizontalDragUpdate: (details) {
              final t = scrubTime(details.localPosition.dx);
              if (t != null) _seekToTime(t);
            },
            onHorizontalDragEnd: (_) => _lastSnappedKfSec = null,
            onHorizontalDragCancel: () => _lastSnappedKfSec = null,
            onTapDown: (details) {
              _lastSnappedKfSec = null;
              final t = scrubTime(details.localPosition.dx);
              if (t != null) _seekToTime(t);
            },
            child: CustomPaint(
              size: Size(width, 54),
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
    );
  }

  String _formatTimeTenths(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '0:00.0';
    final whole = seconds.floor();
    final tenths = ((seconds - whole) * 10).floor();
    return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}.'
        '$tenths';
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
        foregroundColor: highlighted ? const Color(0xFFE040FB) : null,
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
    final voiceBoundCount =
        track.speakers.where((s) => s.boundVoiceClusterId != null).length;
    return Card(
      color: AppColors.surfaceLight,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.record_voice_over, color: Color(0xFFE040FB)),
        title: Text(
          '3-Layer AI · ${track.speakers.length} people ($voiceBoundCount voice-locked) · '
          '${_workingKeyframes.length} keyframes · ${_shots.length} shots',
          style: const TextStyle(fontSize: 12.5),
        ),
        subtitle: Text(
          '${track.facesDetectedCount} face detections · Tap any person on video to lock/unlock',
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
          'وضع التتبع العام للفيديو بالكامل (Target Face / Speaker)',
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
              label: const Text('Auto Active Speaker (المتكلم تلقائياً)'),
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
                label: Text(
                  '${profile.label}'
                  '${profile.boundVoiceClusterId != null ? ' 🔊' : ''}',
                ),
                selected: selectedId == profile.id,
                onSelected: (_) => _selectSpeaker(profile.id),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          selectedLabel == null
              ? 'الوضع العام: الكاميرا تتبع الشخص المتكلم تلقائياً (بصمة الصوت + حركة الشفاه الداخلية + الجسد العلوي).'
              : 'الوضع العام: الكاميرا مثبتة على $selectedLabel طوال الفيديو.',
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ],
    );
  }
}

class ReframeFaceMarker {
  final int speakerId;
  final double normX;
  final double normY;
  final double normW;
  final double normH;
  final String label;
  final bool locked;
  final bool isSpeaking;
  final bool hasVoiceFingerprint;

  const ReframeFaceMarker({
    this.speakerId = 0,
    required this.normX,
    required this.normY,
    this.normW = 0.14,
    this.normH = 0.22,
    required this.label,
    this.locked = false,
    this.isSpeaking = false,
    this.hasVoiceFingerprint = false,
  });
}

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
      canvas.drawPath(
        dimPath,
        Paint()..color = Colors.black.withValues(alpha: 0.55),
      );
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

    for (final face in faces) {
      final center = Offset(face.normX * size.width, face.normY * size.height);
      final boxW = (face.normW * size.width * 1.25).clamp(38.0, size.width * 0.45);
      final boxH = (face.normH * size.height * 1.55).clamp(48.0, size.height * 0.65);
      final personRect = Rect.fromLTWH(
        (center.dx - boxW * 0.5).clamp(2.0, size.width - boxW - 2.0),
        (center.dy - boxH * 0.38).clamp(2.0, size.height - boxH - 2.0),
        boxW,
        boxH,
      );

      final Color color;
      final String statusText;
      if (face.locked) {
        color = const Color(0xFFE040FB);
        statusText = '🔒 مثبت';
      } else if (face.isSpeaking) {
        color = const Color(0xFF00E676);
        statusText = '🎤 يتحدث';
      } else {
        color = const Color(0xFF00E5FF);
        statusText = '👆 المس للتثبيت';
      }

      final rrect = RRect.fromRectAndRadius(personRect, const Radius.circular(8));
      canvas.drawRRect(
        rrect,
        Paint()..color = color.withValues(alpha: face.locked || face.isSpeaking ? 0.16 : 0.08),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = face.locked || face.isSpeaking ? 2.4 : 1.5,
      );

      final shortLabel = face.label.split(' ').take(2).join(' ');
      final label = TextPainter(
        text: TextSpan(
          text: ' $shortLabel · $statusText ',
          style: TextStyle(
            color: face.isSpeaking && !face.locked ? Colors.black : Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            backgroundColor: face.locked
                ? const Color(0xDD9C27B0)
                : (face.isSpeaking
                    ? const Color(0xDD00E676)
                    : const Color(0xCC006064)),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(
          personRect.left.clamp(0.0, size.width - label.width),
          max(0.0, personRect.top - label.height - 2),
        ),
      );
    }

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
          text: ' 3-Layer AI Speaker Lock ',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10.5,
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
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.timeSec != y.timeSec ||
          x.normX != y.normX ||
          x.normY != y.normY ||
          x.isCut != y.isCut ||
          x.isManual != y.isManual) {
        return false;
      }
    }
    return true;
  }
}
