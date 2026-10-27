import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/utils/result.dart';
import '../../../../core/errors/failures.dart';
import '../../../audio_processing/domain/entities/waveform_data.dart';
import '../../../audio_processing/data/repositories/audio_processor_repository_impl.dart';
import '../../data/repositories/silence_detector_repository_impl.dart';
import '../../data/services/adaptive_threshold_service.dart';
import '../../domain/entities/silence_detection_blocker.dart';
import '../../data/datasources/media_probe_datasource.dart';
import '../../domain/entities/detection_params.dart';
import '../../domain/entities/media_timeline.dart';
import '../../domain/entities/silence_removal_plan.dart';
import '../../domain/services/editor_services.dart';

/// Lifecycle of a single detection attempt for one editor file.
enum DetectionStatus { idle, detecting, ready, failed }

/// Owns every piece of state that belongs to **one** editor file, so that a
/// plan produced for file A can never be read, previewed, exported or cut for
/// file B, and a settings change can never leave an old plan looking valid.
///
/// Identity is the whole point (SR-04): [sessionId] is minted when the
/// controller is created and bumped on [close], [detectionRequestId] is minted
/// per attempt, and [paramsVersion] / [renderRecipeVersion] are bumped on every
/// relevant settings change. A late result is committed only when **all** of
/// them still match at commit time (SR-04.3).
class EditorDetectionController extends ChangeNotifier {
  EditorDetectionController({
    required this.videoPath,
    MediaProbeService? probeService,
    AudioExtractionService? audioService,
    SilenceDetectionService? detectionService,
    ProcessingService? processingService,
    AdaptiveThresholdService? autoThresholdService,
  })  : _probeService = probeService ?? _DefaultMediaProbeService(),
        _audioService = audioService ?? _DefaultAudioExtractionService(),
        _detectionService =
            detectionService ?? _DefaultSilenceDetectionService(),
        _processingService = processingService ?? _DefaultProcessingService(),
        _autoThresholdService =
            autoThresholdService ?? AdaptiveThresholdService() {
    _sessionId = _nextSessionId++;
  }

  static int _nextSessionId = 0;

  final String videoPath;
  final MediaProbeService _probeService;
  // ignore: unused_field
  final AudioExtractionService _audioService;
  // ignore: unused_field
  final SilenceDetectionService _detectionService;
  // ignore: unused_field
  final ProcessingService _processingService;
  final AdaptiveThresholdService _autoThresholdService;

  int _sessionId = 0;
  int get sessionId => _sessionId;

  String? _audioPath;
  String? get audioPath => _audioPath;

  MediaTimeline _timeline = MediaTimeline.unknown;
  MediaTimeline get timeline => _timeline;

  WaveformData? _waveform;
  WaveformData? get waveform => _waveform;

  double _waveformZoom = 1.0;
  double get waveformZoom => _waveformZoom;

  DetectionParams _params = DetectionParams.defaults();
  DetectionParams get params => _params;

  /// Bumped on every change to a detection-relevant setting (threshold, min
  /// silence, guards, VAD, breathing). Smart Zoom does **not** bump this, so
  /// editing the zoom never invalidates a detection.
  int _paramsVersion = 0;
  int get paramsVersion => _paramsVersion;

  int? _detectionRequestId;
  int? get detectionRequestId => _detectionRequestId;

  DetectionStatus _status = DetectionStatus.idle;
  DetectionStatus get status => _status;

  String? _detectionError;
  String? get detectionError => _detectionError;

  SilenceRemovalPlan? _plan;
  SilenceRemovalPlan? get plan => _plan;

  int? _planParamsVersion;
  int? get planParamsVersion => _planParamsVersion;

  int? _planSessionId;
  int? get planSessionId => _planSessionId;

  int? _planRequestId;
  int? get planRequestId => _planRequestId;

  /// Render recipe version. Bumped whenever Smart Zoom changes, so a render
  /// produced under an older recipe is recognised as stale (SR-07 / render).
  int _renderRecipeVersion = 0;
  int get renderRecipeVersion => _renderRecipeVersion;

  int? _renderedRecipeVersion;
  int? get renderedRecipeVersion => _renderedRecipeVersion;

  String? _renderedOutputPath;
  String? get renderedOutputPath => _renderedOutputPath;

  bool _closed = false;
  bool get isClosed => _closed;

  // ---------- derived barriers ----------

  /// True while a detection is in flight for this session.
  bool get isDetecting => _status == DetectionStatus.detecting;

  /// The plan was produced for this session's current params and request.
  bool get planIsValid =>
      _plan != null &&
      _planSessionId == _sessionId &&
      _planParamsVersion == _paramsVersion &&
      _planRequestId != null;

  /// Ready to preview: a valid, non-stale plan exists for this file.
  bool get canPreview => planIsValid && _status == DetectionStatus.ready;

  /// Ready to process/export: a valid plan plus an extracted audio path.
  bool get canProcess =>
      canPreview && _audioPath != null && _audioPath!.isNotEmpty;

  /// True when the current plan was built under older detection params.
  bool get planIsStale =>
      _plan != null && _planParamsVersion != _paramsVersion;

  /// True when the rendered output no longer matches the current render recipe.
  bool get renderIsStale =>
      _renderedOutputPath != null &&
      _renderedRecipeVersion != _renderRecipeVersion;

  /// True when a render is needed to (re)produce the output for the current
  /// recipe. Detection itself is not required to change for a zoom-only edit.
  bool get needsRender =>
      planIsValid && (_renderedOutputPath == null || renderIsStale);

  // ---------- settings (versioned) ----------

  void setParams(DetectionParams next) {
    final detectionChanged = _detectionRelevantChanged(_params, next);
    final renderChanged = _params.smartZoom != next.smartZoom;
    _params = next;
    if (detectionChanged) _paramsVersion++;
    if (renderChanged) _renderRecipeVersion++;
    notifyListeners();
  }

  void updateThreshold(double value) =>
      setParams(_params.copyWith(silenceThreshold: value));

  void updateMinDuration(double value) =>
      setParams(_params.copyWith(minSilenceDuration: value));

  void updatePaddingBefore(double value) =>
      setParams(_params.copyWith(paddingBefore: value));

  void updatePaddingAfter(double value) =>
      setParams(_params.copyWith(paddingAfter: value));

  void toggleVad() => setParams(_params.copyWith(useVad: !_params.useVad));

  void toggleBreathingProtection() => setParams(
        _params.copyWith(
          useBreathingProtection: !_params.useBreathingProtection,
        ),
      );

  void toggleSmartZoom() => setParams(
        _params.copyWith(
          smartZoom: _params.smartZoom.copyWith(
            enabled: !_params.smartZoom.enabled,
          ),
        ),
      );

  void setSmartZoomAmount(double amount) => setParams(
        _params.copyWith(
          smartZoom: _params.smartZoom.copyWith(zoomAmount: amount),
        ),
      );

  int _autoRequestId = 0;

  Future<void> autoDetectThreshold() async {
    if (_closed || _audioPath == null) return;
    final requestId = ++_autoRequestId;
    final snapshotSessionId = _sessionId;
    final snapshotParams = _params;
    final snapshotParamsVersion = _paramsVersion;
    final statusBefore = _status;
    _status = DetectionStatus.detecting;
    notifyListeners();

    DetectionParams? updated;
    try {
      final service = _autoThresholdService;
      updated = await service.analyze(
        audioPath: _audioPath!,
        currentParams: snapshotParams,
      );
    } catch (e) {
      if (_closed || _sessionId != snapshotSessionId || _autoRequestId != requestId) {
        return;
      }
      _detectionError = e.toString();
      _status = statusBefore;
      notifyListeners();
      return;
    }

    if (_closed || _sessionId != snapshotSessionId || _autoRequestId != requestId) {
      return; // stale: do not commit or notify
    }
    if (_paramsVersion != snapshotParamsVersion) {
      // A newer manual edit won the race: keep it, discard Auto's answer.
      _status = statusBefore;
      notifyListeners();
      return;
    }
    final changed = updated != snapshotParams &&
        (updated.silenceThreshold != _params.silenceThreshold ||
            updated.minSilenceDuration != _params.minSilenceDuration ||
            updated.paddingBefore != _params.paddingBefore ||
            updated.paddingAfter != _params.paddingAfter ||
            updated.useVad != _params.useVad ||
            updated.useBreathingProtection != _params.useBreathingProtection ||
            updated.smartZoom != _params.smartZoom);
    if (changed) {
      setParams(updated);
      _status = DetectionStatus.idle;
    } else {
      // Nothing changed: preserve the current plan/status (ready stays ready).
      _status = statusBefore;
    }
    if (!_closed) notifyListeners();
  }

  static bool _detectionRelevantChanged(
    DetectionParams a,
    DetectionParams b,
  ) {
    return a.silenceThreshold != b.silenceThreshold ||
        a.minSilenceDuration != b.minSilenceDuration ||
        a.paddingBefore != b.paddingBefore ||
        a.paddingAfter != b.paddingAfter ||
        a.useVad != b.useVad ||
        a.useBreathingProtection != b.useBreathingProtection;
  }

  // ---------- file lifecycle ----------

  Future<void> load({
    required String audioPath,
    MediaTimeline? timeline,
  }) async {
    if (_closed) return;
    _audioPath = audioPath;
    if (timeline != null) {
      _timeline = timeline;
    } else {
      final probeResult = await _probeService.probe(videoPath);
      if (_closed) return;
      if (probeResult is Success<MediaTimeline>) {
        _timeline = probeResult.value;
      } else {
        _timeline = MediaTimeline.probed(
          videoDurationSeconds: 0,
          hasAudio: false,
        );
      }
    }
    // Reset any plan from a previous file: identity is now this session's.
    _plan = null;
    _planParamsVersion = null;
    _planSessionId = null;
    _planRequestId = null;
    _status = DetectionStatus.idle;
    _detectionError = null;
    notifyListeners();
  }

  void setTimeline(MediaTimeline timeline) {
    _timeline = timeline;
    notifyListeners();
  }

  void setWaveform(WaveformData? waveform) {
    _waveform = waveform;
    notifyListeners();
  }

  void setWaveformZoom(double zoom) {
    // Display-only: never touches detection or render identity (SR-07).
    _waveformZoom = zoom;
    notifyListeners();
  }

  // ---------- detection ----------

  Future<void> detect() async {
    if (_closed) return;
    if (_audioPath == null || _audioPath!.isEmpty) return;

    final blocker = SilenceDetectionGate.blockerFor(_timeline);
    if (blocker != null) {
      _status = DetectionStatus.failed;
      _detectionError = SilenceDetectionGate.messageFor(blocker);
      notifyListeners();
      return;
    }

    final requestId = _nextRequestId();
    _detectionRequestId = requestId;
    final snapshotSessionId = _sessionId;
    final snapshotParams = _params;
    final snapshotParamsVersion = _paramsVersion;
    _status = DetectionStatus.detecting;
    _detectionError = null;
    notifyListeners();

    Result<SilenceRemovalPlan> result;
    try {
      result = await _detectionService.detect(
        audioPath: _audioPath!,
        params: snapshotParams,
        timeline: _timeline,
      );
    } catch (e) {
      result = AppError<SilenceRemovalPlan>(
        SilenceDetectionFailure(message: e.toString()),
      );
    }

    // Commit only if identity still matches (SR-04.3).
    if (_closed) return;
    if (_sessionId != snapshotSessionId) return;
    if (_detectionRequestId != requestId) return;
    if (_paramsVersion != snapshotParamsVersion) {
      // Stale request: end its detecting state without clobbering a newer one.
      _status = DetectionStatus.idle;
      notifyListeners();
      return;
    }

    if (result is Success<SilenceRemovalPlan>) {
      _plan = result.value;
      _planParamsVersion = snapshotParamsVersion;
      _planSessionId = snapshotSessionId;
      _planRequestId = requestId;
      _status = DetectionStatus.ready;
      _detectionError = null;
      // A new plan needs a new render.
      _renderedOutputPath = null;
      _renderedRecipeVersion = null;
    } else if (result is AppError<SilenceRemovalPlan>) {
      _status = DetectionStatus.failed;
      _detectionError = result.error.message;
      // Leave any previous plan in place only if it belongs to THIS session
      // and is still current; otherwise clear so a failed B never shows A.
      if (_planSessionId != _sessionId || _planParamsVersion != _paramsVersion) {
        _plan = null;
        _planParamsVersion = null;
        _planRequestId = null;
        _planSessionId = null;
      }
    }
    notifyListeners();
  }

  int _nextRequestId() => ++_requestCounter;
  static int _requestCounter = 0;

  // ---------- keep this range ----------

  void keepInterval(int index) {
    if (!planIsValid) return;
    final current = _plan!;
    final updated = current.withoutRemoval(index);
    _plan = updated;
    // Same session, same request, same params version: only the removal set
    // changed, so staleness flags are untouched. But the rendered output was
    // produced from the previous removal set, so it is now stale.
    _planParamsVersion = _paramsVersion;
    _planSessionId = _sessionId;
    _renderedOutputPath = null;
    _renderedRecipeVersion = null;
    notifyListeners();
  }

  // ---------- render recipe ----------

  void markRendered(String outputPath) {
    if (_closed) return;
    if (!planIsValid) return;
    _renderedOutputPath = outputPath;
    _renderedRecipeVersion = _renderRecipeVersion;
    notifyListeners();
  }

  void invalidateRender() {
    _renderedOutputPath = null;
    _renderedRecipeVersion = null;
    notifyListeners();
  }

  // ---------- session lifecycle ----------

  void close() {
    _closed = true;
    _sessionId++; // bump so any in-flight result is discarded
    _plan = null;
    _planParamsVersion = null;
    _planSessionId = null;
    _planRequestId = null;
    _audioPath = null;
    _status = DetectionStatus.idle;
    _detectionError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

// ---------- default service adapters ----------

class _DefaultMediaProbeService implements MediaProbeService {
  @override
  Future<Result<MediaTimeline>> probe(String videoPath) async {
    final probe = MediaProbeDatasource();
    return probe.probe(videoPath);
  }
}

class _DefaultAudioExtractionService implements AudioExtractionService {
  final _repo = AudioProcessorRepositoryImpl();

  @override
  Future<Result<String>> extractAudio(String videoPath) =>
      _repo.extractAudio(videoPath);

  @override
  Future<Result<WaveformData>> analyzeWaveform(String audioPath) =>
      _repo.analyzeWaveform(audioPath);
}

class _DefaultSilenceDetectionService implements SilenceDetectionService {
  final _repo = SilenceDetectorRepositoryImpl();

  @override
  Future<Result<SilenceRemovalPlan>> detect({
    required String audioPath,
    required DetectionParams params,
    required MediaTimeline timeline,
  }) {
    return _repo.buildRemovalPlan(
      audioPath: audioPath,
      params: params,
      timeline: timeline,
    );
  }
}

class _DefaultProcessingService implements ProcessingService {
  @override
  Future<Result<String>> process({
    required String videoPath,
    required String audioPath,
    required SilenceRemovalPlan plan,
    required DetectionParams params,
  }) async {
    return const AppError<String>(
      VideoProcessingFailure(message: 'processing is wired by the screen'),
    );
  }
}
