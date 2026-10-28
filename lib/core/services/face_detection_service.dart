import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/logger.dart';

/// One sampled speaker position on the source frame.
///
/// Coordinates are **normalized** (`0.0 .. 1.0`) so the same track can drive a
/// 9:16, 16:9, 1:1, 4:5 or custom crop without knowing the source resolution.
class FaceTrackPoint {
  final double timeSec;
  final double normX;
  final double normY;

  const FaceTrackPoint({
    required this.timeSec,
    this.normX = 0.5,
    this.normY = 0.42,
  });

  @override
  String toString() =>
      'FaceTrackPoint(t=${timeSec.toStringAsFixed(3)}, '
      'x=${normX.toStringAsFixed(3)}, y=${normY.toStringAsFixed(3)})';
}

/// One detected person, locked across the whole clip.
///
/// Selecting a profile pins the camera on that human only, which is what the
/// "Target Face / Speaker" chips use.
class DetectedSpeakerProfile {
  /// Index inside [FaceTrackResult.speakers], left-to-right by average X.
  final int id;

  /// Human label, e.g. `Person 1 (Left)`.
  final String label;

  final double avgNormX;
  final double avgNormY;

  /// Trajectory when locked exclusively onto this person.
  final List<FaceTrackPoint> rawPoints;

  const DetectedSpeakerProfile({
    required this.id,
    required this.label,
    required this.avgNormX,
    required this.avgNormY,
    required this.rawPoints,
  });
}

/// Result of one face-analysis pass: the active-speaker trajectory plus every
/// individual person profile.
class FaceTrackResult {
  /// Active-speaker position for every sampled analysis frame.
  final List<FaceTrackPoint> rawPoints;

  /// Shot-aware trajectory (<= [FaceDetectionService.maxKeyframes] points) with
  /// **instant cuts** at speaker switches instead of a slow crawl.
  final List<FaceTrackPoint> keyframes;

  final double avgNormX;
  final double avgNormY;
  final int facesDetectedCount;

  /// Every distinct person found, sorted left-to-right.
  final List<DetectedSpeakerProfile> speakers;

  /// Probed source dimensions (0 when unknown), for the legacy pixel API.
  final int sourceWidth;
  final int sourceHeight;

  const FaceTrackResult({
    required this.rawPoints,
    required this.keyframes,
    required this.avgNormX,
    required this.avgNormY,
    required this.facesDetectedCount,
    this.speakers = const [],
    this.sourceWidth = 0,
    this.sourceHeight = 0,
  });

  /// Linearly interpolated speaker position at [timeSec], for the live preview
  /// overlay. Speaker switches are step transitions, never interpolations.
  (double normX, double normY) sampleAt(double timeSec) {
    if (keyframes.isEmpty) return (0.5, 0.42);
    if (keyframes.length == 1) {
      return (keyframes.first.normX, keyframes.first.normY);
    }
    if (timeSec <= keyframes.first.timeSec) {
      return (keyframes.first.normX, keyframes.first.normY);
    }
    if (timeSec >= keyframes.last.timeSec) {
      return (keyframes.last.normX, keyframes.last.normY);
    }

    for (var i = 0; i < keyframes.length - 1; i++) {
      final a = keyframes[i];
      final b = keyframes[i + 1];
      if (timeSec >= a.timeSec && timeSec <= b.timeSec) {
        final span = b.timeSec - a.timeSec;
        if (span <= 0) return (b.normX, b.normY);
        final f = ((timeSec - a.timeSec) / span).clamp(0.0, 1.0);
        return (
          a.normX + (b.normX - a.normX) * f,
          a.normY + (b.normY - a.normY) * f,
        );
      }
    }
    return (keyframes.last.normX, keyframes.last.normY);
  }
}

/// Per-person state used while selecting the active speaker.
class _SpeakerTrack {
  _SpeakerTrack(this.id);

  final int id;
  int hits = 0;
  double lastSeenSec = -1;

  /// Last normalized bounding box of this person.
  double normX = 0.5;
  double normY = 0.42;
  double normW = 0;
  double normH = 0;

  /// Previous **relative** lip geometry (never absolute image coordinates).
  double? lastOpen;
  double? lastWidth;

  /// Rolling window of the last 4 lip deltas.
  final List<double> lipDeltas = <double>[];

  /// Every frame in which this person was visible, with its own trajectory.
  final List<FaceTrackPoint> points = <FaceTrackPoint>[];

  double? lockStartSec;

  double get areaNorm => (normW * normH).clamp(0.0, 1.0);

  double get recentActivity {
    if (lipDeltas.isEmpty) return 0;
    var total = 0.0;
    for (final delta in lipDeltas) {
      total += delta;
    }
    return total / lipDeltas.length;
  }

  /// Mouth movement dominates (that is what "speaking" means); face area and
  /// persistence break ties for people who are silent in every sample.
  double get score =>
      recentActivity * 2.0 + areaNorm + 0.05 * (min(hits, 10) / 10);
}

/// Real ML Kit + FFmpeg speaker tracking.
///
/// Pipeline: **one** FFmpeg frame-extraction pass (960px, dense fps) → one
/// accurate `FaceDetector` for all frames → IoU/center association per person →
/// lip-relative speech activity with a 1.2s speaker lock → shot segmentation
/// (no smoothing across jumps) → per-shot dead-zone + bidirectional EMA →
/// RDP simplification capped at [maxKeyframes] keyframes with instant cuts.
class FaceDetectionService {
  FaceDetectionService._();

  static const double defaultDeadZone = 0.045;
  static const double defaultSmoothness = 0.28;

  /// FFmpeg-safe keyframe cap. With the balanced binary-tree expression the
  /// nesting depth is `log2(60) ≈ 6`, so this never overflows the parser.
  static const int maxKeyframes = 60;

  /// A normalized move this large (in one sample) is a **speaker switch or
  /// scene cut**, not camera motion: smoothing must stop at the boundary.
  static const double speakerJumpThreshold = 0.10;

  /// Association tolerances (normalized frame units).
  static const double associationDistance = 0.15;
  static const double minFaceOverlap = 0.1;

  /// Minimum time the camera stays on one speaker before it may switch.
  static const double speakerLockSeconds = 1.2;

  /// Frames kept in the rolling lip-delta window.
  static const int lipWindow = 4;

  // ---------------------------------------------------------------------------
  // Analysis
  // ---------------------------------------------------------------------------

  /// Analyzes [videoPath] and returns the stabilized 2D speaker trajectory,
  /// every detected person profile, or `null` when no face was found at all.
  static Future<FaceTrackResult?> analyzeVideoFaceTrack(
    String videoPath, {
    double startSec = 0,
    double? endSec,
    double? durationSec,
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    void Function(double progress, String status)? onProgress,
  }) async {
    final probe = await _probeSource(videoPath);
    final clipDuration = _resolveClipDuration(
      startSec: startSec,
      endSec: endSec,
      durationSec: durationSec,
      probedDuration: probe.durationSec,
    );
    if (clipDuration <= 0) {
      AppLogger().e('FaceTrack: unknown clip duration for $videoPath');
      return null;
    }

    // Dense sampling keeps lip deltas meaningful; the old 1-2 fps pass made
    // wide 16:9 multi-speaker faces too small and too sparse to compare.
    final double sampleFps;
    if (clipDuration <= 90) {
      sampleFps = 4.0;
    } else if (clipDuration <= 240) {
      sampleFps = 2.5;
    } else {
      sampleFps = max(1.5, 240.0 / clipDuration);
    }

    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory(
      '${tempDir.path}/face_track_${DateTime.now().millisecondsSinceEpoch}',
    );

    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableLandmarks: true,
        enableContours: true,
        // Contours/landmarks and cross-frame tracking are mutually exclusive in
        // ML Kit, so people are matched by box IoU + center distance instead.
        enableTracking: false,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );

    try {
      await framesDir.create(recursive: true);
      onProgress?.call(0.05, 'Extracting analysis frames...');

      final command =
          '-ss ${startSec.toStringAsFixed(3)} '
          '-t ${clipDuration.toStringAsFixed(3)} -i "$videoPath" '
          '-vf "fps=$sampleFps,scale=960:-2" -q:v 3 '
          '-y "${framesDir.path}/frame_%04d.jpg"';
      final session = await FFmpegKit.execute(command);
      if (!ReturnCode.isSuccess(await session.getReturnCode())) {
        AppLogger().e(
          'FaceTrack: frame extraction failed: '
          '${await session.getAllLogsAsString()}',
        );
        return null;
      }

      final frames = await framesDir
          .list()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList();
      frames.sort((a, b) => a.path.compareTo(b.path));
      if (frames.isEmpty) {
        AppLogger().e('FaceTrack: no analysis frames produced');
        return null;
      }

      // Real decoded dimensions: normalized coordinates must be exact.
      final firstImage = await _decodeImage(File(frames.first.path));
      final imgWidth = firstImage.width.toDouble();
      final imgHeight = firstImage.height.toDouble();
      firstImage.dispose();
      if (imgWidth <= 0 || imgHeight <= 0) return null;

      final tracks = <int, _SpeakerTrack>{};
      final activePoints = <FaceTrackPoint>[];
      var facesDetectedCount = 0;
      _SpeakerTrack? currentSpeaker;
      var lastX = 0.5;
      var lastY = 0.42;

      for (var i = 0; i < frames.length; i++) {
        final timeSec = startSec + i / sampleFps;
        final inputImage = InputImage.fromFilePath(frames[i].path);
        List<Face> faces;
        try {
          faces = await detector.processImage(inputImage);
        } catch (e) {
          AppLogger().e('FaceTrack: detector failed on frame $i', e);
          faces = const [];
        }
        facesDetectedCount += faces.length;

        final present = <_SpeakerTrack>[];
        for (final face in faces) {
          final box = face.boundingBox;
          final nx0 = (box.left / imgWidth).clamp(0.0, 1.0);
          final ny0 = (box.top / imgHeight).clamp(0.0, 1.0);
          final nx1 = (box.right / imgWidth).clamp(0.0, 1.0);
          final ny1 = (box.bottom / imgHeight).clamp(0.0, 1.0);
          final cx = ((nx0 + nx1) / 2).clamp(0.0, 1.0);
          final cy = ((ny0 + ny1) / 2).clamp(0.0, 1.0);

          final track = _associateFace(
            tracks,
            nowSec: timeSec,
            nx0: nx0,
            ny0: ny0,
            nx1: nx1,
            ny1: ny1,
            cx: cx,
            cy: cy,
          );
          if (track == null) {
            final created = _SpeakerTrack(tracks.length);
            tracks[created.id] = created;
            present.add(created);
            _updateTrack(created, timeSec, cx, cy, nx1 - nx0, ny1 - ny0);
            _updateLipActivity(created, face, box);
            created.points.add(
              FaceTrackPoint(timeSec: timeSec, normX: cx, normY: cy),
            );
            continue;
          }

          _updateTrack(track, timeSec, cx, cy, nx1 - nx0, ny1 - ny0);
          _updateLipActivity(track, face, box);
          track.points.add(
            FaceTrackPoint(timeSec: timeSec, normX: cx, normY: cy),
          );
          present.add(track);
        }

        currentSpeaker = _selectSpeaker(
          present,
          currentSpeaker,
          nowSec: timeSec,
        );
        if (currentSpeaker != null && present.contains(currentSpeaker)) {
          lastX = currentSpeaker.normX;
          lastY = currentSpeaker.normY;
        }
        // A frame without faces holds the last camera position.
        activePoints.add(
          FaceTrackPoint(timeSec: timeSec, normX: lastX, normY: lastY),
        );

        if (i % 8 == 0 || i == frames.length - 1) {
          onProgress?.call(
            0.1 + 0.8 * ((i + 1) / frames.length),
            'Tracking speaker ${i + 1}/${frames.length}...',
          );
        }
      }

      if (facesDetectedCount == 0 || activePoints.isEmpty) {
        AppLogger().i('FaceTrack: no faces detected in ${frames.length} frames');
        return null;
      }

      final keyframes = buildKeyframes(
        activePoints,
        deadZone: deadZone,
        smoothness: smoothness,
      );
      final profiles = _buildProfiles(tracks);
      final avgX =
          activePoints.map((p) => p.normX).reduce((a, b) => a + b) /
          activePoints.length;
      final avgY =
          activePoints.map((p) => p.normY).reduce((a, b) => a + b) /
          activePoints.length;

      onProgress?.call(1.0, 'Speaker track ready');
      AppLogger().i(
        'FaceTrack: ${frames.length} frames, ${profiles.length} people, '
        '$facesDetectedCount faces, ${keyframes.length} keyframes',
      );

      return FaceTrackResult(
        rawPoints: activePoints,
        keyframes: keyframes,
        avgNormX: avgX,
        avgNormY: avgY,
        facesDetectedCount: facesDetectedCount,
        speakers: profiles,
        sourceWidth: probe.width,
        sourceHeight: probe.height,
      );
    } catch (e, stack) {
      AppLogger().e('FaceTrack analysis failed', e, stack);
      return null;
    } finally {
      await detector.close();
      try {
        if (await framesDir.exists()) {
          await framesDir.delete(recursive: true);
        }
      } catch (e) {
        AppLogger().e('FaceTrack: could not clean analysis frames', e);
      }
    }
  }

  static void _updateTrack(
    _SpeakerTrack track,
    double timeSec,
    double cx,
    double cy,
    double w,
    double h,
  ) {
    track.hits++;
    track.lastSeenSec = timeSec;
    track.normX = cx;
    track.normY = cy;
    track.normW = w.clamp(0.0, 1.0);
    track.normH = h.clamp(0.0, 1.0);
  }

  /// True lip/speech activity: frame-to-frame change of mouth geometry
  /// **relative to the face's own bounding box** (invariant to head motion).
  static void _updateLipActivity(
    _SpeakerTrack track,
    Face face,
    ui.Rect box,
  ) {
    final metrics = _lipMetrics(face, box);
    final open = metrics.$1;
    final width = metrics.$2;

    var delta = 0.0;
    if (open != null) {
      final previous = track.lastOpen;
      if (previous != null) delta += (open - previous).abs() * 4.5;
      track.lastOpen = open;
    }
    if (width != null) {
      final previous = track.lastWidth;
      if (previous != null) delta += (width - previous).abs() * 2.5;
      track.lastWidth = width;
    }

    track.lipDeltas.add(delta);
    if (track.lipDeltas.length > lipWindow) {
      track.lipDeltas.removeAt(0);
    }
  }

  /// Relative lip gap / mouth width for one face, each normalized by the face
  /// box so a silent head movement cannot out-score a moving mouth.
  static (double?, double?) _lipMetrics(Face face, ui.Rect box) {
    final height = box.height > 0 ? box.height : 1.0;
    final width = box.width > 0 ? box.width : 1.0;

    double? open;

    // Contour-based lip gap (most accurate when available).
    final upperLip = face.contours[FaceContourType.upperLipBottom]?.points;
    final lowerLip = face.contours[FaceContourType.lowerLipTop]?.points;
    if (upperLip != null &&
        upperLip.isNotEmpty &&
        lowerLip != null &&
        lowerLip.isNotEmpty) {
      final upperY =
          upperLip.fold<double>(0.0, (sum, p) => sum + p.y) / upperLip.length;
      final lowerY =
          lowerLip.fold<double>(0.0, (sum, p) => sum + p.y) / lowerLip.length;
      open = (lowerY - upperY).abs() / height;
    }

    // Landmark-based fallback: bottom of the mouth relative to the nose base.
    if (open == null) {
      final bottom = face.landmarks[FaceLandmarkType.bottomMouth]?.position;
      final nose = face.landmarks[FaceLandmarkType.noseBase]?.position;
      if (bottom != null && nose != null) {
        open = (bottom.y - nose.y).abs() / height;
      }
    }

    double? mouthWidth;
    final left = face.landmarks[FaceLandmarkType.leftMouth]?.position;
    final right = face.landmarks[FaceLandmarkType.rightMouth]?.position;
    if (left != null && right != null) {
      mouthWidth = (right.x - left.x).abs() / width;
    }

    return (open, mouthWidth);
  }

  /// Associates a detected face with an existing track by **box IoU**, then by
  /// normalized center distance. Stale tracks (invisible for a while) are not
  /// re-matched, so a new shot does not hijack an old person's history.
  static _SpeakerTrack? _associateFace(
    Map<int, _SpeakerTrack> tracks, {
    required double nowSec,
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    required double cx,
    required double cy,
  }) {
    _SpeakerTrack? best;
    var bestIou = minFaceOverlap;
    for (final track in tracks.values) {
      if (nowSec - track.lastSeenSec > 2.5) continue;
      final iou = _boxOverlap(track, nx0, ny0, nx1, ny1);
      if (iou > bestIou) {
        bestIou = iou;
        best = track;
      }
    }
    if (best != null) return best;

    _SpeakerTrack? nearest;
    var bestDistance = associationDistance;
    for (final track in tracks.values) {
      if (nowSec - track.lastSeenSec > 2.5) continue;
      final dx = track.normX - cx;
      final dy = track.normY - cy;
      final distance = sqrt(dx * dx + dy * dy);
      if (distance < bestDistance) {
        bestDistance = distance;
        nearest = track;
      }
    }
    return nearest;
  }

  static double _boxOverlap(
    _SpeakerTrack track,
    double nx0,
    double ny0,
    double nx1,
    double ny1,
  ) {
    final tx0 = track.normX - track.normW / 2;
    final ty0 = track.normY - track.normH / 2;
    final tx1 = track.normX + track.normW / 2;
    final ty1 = track.normY + track.normH / 2;

    final ix0 = max(tx0, nx0);
    final iy0 = max(ty0, ny0);
    final ix1 = min(tx1, nx1);
    final iy1 = min(ty1, ny1);
    final intersection = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0);
    if (intersection <= 0) return 0;

    final union = track.normW * track.normH + (nx1 - nx0) * (ny1 - ny0) -
        intersection;
    return union > 0 ? intersection / union : 0;
  }

  /// Picks the active speaker, holding a 1.2s lock so the camera does not
  /// ping-pong; a face that leaves the frame releases the lock immediately.
  static _SpeakerTrack? _selectSpeaker(
    List<_SpeakerTrack> present,
    _SpeakerTrack? current, {
    required double nowSec,
  }) {
    if (present.isEmpty) return null;

    if (current != null && present.contains(current)) {
      current.lockStartSec ??= nowSec;
      final lockedFor = nowSec - (current.lockStartSec ?? nowSec);

      var best = current;
      for (final candidate in present) {
        if (candidate.score > best.score) best = candidate;
      }
      if (!identical(best, current) &&
          lockedFor >= speakerLockSeconds &&
          best.hits >= 2 &&
          best.score > current.score * 1.2 + 0.01) {
        best.lockStartSec = nowSec;
        return best;
      }
      return current;
    }

    // The current speaker is gone from this frame: switch right away.
    _SpeakerTrack? best;
    for (final candidate in present) {
      if (best == null || candidate.score > best.score) best = candidate;
    }
    best?.lockStartSec = nowSec;
    return best;
  }

  /// Groups tracks into people (a person re-detected after a cut may own more
  /// than one track) and labels them left-to-right.
  static List<DetectedSpeakerProfile> _buildProfiles(
    Map<int, _SpeakerTrack> tracks,
  ) {
    final used = tracks.values.where((t) => t.points.length >= 2).toList();
    if (used.isEmpty) return const [];

    double avgOf(List<_SpeakerTrack> group, {required bool x}) {
      var total = 0.0;
      var count = 0;
      for (final track in group) {
        for (final point in track.points) {
          total += x ? point.normX : point.normY;
          count++;
        }
      }
      return count == 0 ? 0.5 : total / count;
    }

    final groups = <List<_SpeakerTrack>>[];
    for (final track in used) {
      final trackX = avgOf([track], x: true);
      final trackY = avgOf([track], x: false);
      List<_SpeakerTrack>? target;
      for (final group in groups) {
        if ((trackX - avgOf(group, x: true)).abs() < 0.12 &&
            (trackY - avgOf(group, x: false)).abs() < 0.12) {
          target = group;
          break;
        }
      }
      if (target != null) {
        target.add(track);
      } else {
        groups.add([track]);
      }
    }

    groups.sort((a, b) => avgOf(a, x: true).compareTo(avgOf(b, x: true)));

    final profiles = <DetectedSpeakerProfile>[];
    for (var i = 0; i < groups.length; i++) {
      final points = <FaceTrackPoint>[];
      for (final track in groups[i]) {
        points.addAll(track.points);
      }
      points.sort((a, b) => a.timeSec.compareTo(b.timeSec));

      var xTotal = 0.0;
      var yTotal = 0.0;
      for (final point in points) {
        xTotal += point.normX;
        yTotal += point.normY;
      }

      profiles.add(
        DetectedSpeakerProfile(
          id: i,
          label: _speakerLabel(i, groups.length),
          avgNormX: xTotal / points.length,
          avgNormY: yTotal / points.length,
          rawPoints: List<FaceTrackPoint>.unmodifiable(points),
        ),
      );
    }
    return profiles;
  }

  static String _speakerLabel(int index, int total) {
    if (total <= 1) return 'Person 1';
    if (index == 0) return 'Person 1 (Left)';
    if (index == total - 1) return 'Person ${index + 1} (Right)';
    return 'Person ${index + 1}';
  }

  static double _resolveClipDuration({
    required double startSec,
    required double? endSec,
    required double? durationSec,
    required double probedDuration,
  }) {
    if (endSec != null && endSec > startSec) return endSec - startSec;
    final total = durationSec != null && durationSec > 0
        ? durationSec
        : probedDuration;
    if (total <= startSec) return 0;
    return total - startSec;
  }

  static Future<({double durationSec, int width, int height})> _probeSource(
    String path,
  ) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info != null) {
        final duration = double.tryParse(info.getDuration() ?? '') ?? 0.0;
        var width = 0;
        var height = 0;
        for (final stream in info.getStreams()) {
          if (stream.getType() == 'video') {
            width = stream.getWidth() ?? 0;
            height = stream.getHeight() ?? 0;
            break;
          }
        }
        return (durationSec: duration, width: width, height: height);
      }
    } catch (e) {
      AppLogger().e('FaceTrack: probe failed', e);
    }
    return (durationSec: 0.0, width: 0, height: 0);
  }

  static Future<ui.Image> _decodeImage(File file) async {
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Camera stabilization (pure, unit-testable)
  // ---------------------------------------------------------------------------

  /// Shot-aware stabilization: splits the raw trajectory into continuous
  /// single-speaker segments, smooths each one **independently**, and joins
  /// them with an instant cut (two keyframes 1ms apart).
  static List<FaceTrackPoint> buildKeyframes(
    List<FaceTrackPoint> rawPoints, {
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    int maxKeyframes = FaceDetectionService.maxKeyframes,
  }) {
    if (rawPoints.isEmpty) return const [];

    // A 1-2 sample track carries no shot structure: jump detection on it would
    // invent cuts, so it stays one segment.
    var ranges = rawPoints.length <= 2
        ? <(int, int)>[(0, rawPoints.length)]
        : _splitSegments(rawPoints, speakerJumpThreshold);
    if (ranges.length * 3 > maxKeyframes) {
      // Too many cuts for the budget: relax the cut detector rather than
      // starving every segment of keyframes.
      ranges = _splitSegments(rawPoints, speakerJumpThreshold * 1.8);
    }

    final boundaries = ranges.length - 1;
    final available = max(maxKeyframes - boundaries, ranges.length);
    final total = rawPoints.length;
    final out = <FaceTrackPoint>[];

    for (final (start, end) in ranges) {
      final segment = _stabilizeSegment(
        rawPoints.sublist(start, end),
        deadZone,
        smoothness,
      );
      final budget = max(2, (available * (end - start)) ~/ total);
      final simplified = _simplifySegment(segment, budget);

      if (out.isNotEmpty && simplified.isNotEmpty) {
        _appendInstantCut(out, simplified.first);
      }
      out.addAll(simplified);
    }

    return List<FaceTrackPoint>.unmodifiable(
      _enforceBudget(out, maxKeyframes),
    );
  }

  /// Dead-zone + EMA **without** crossing a speaker switch/scene jump.
  static List<FaceTrackPoint> stabilizeTrack(
    List<FaceTrackPoint> rawPoints, {
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    double jumpThreshold = speakerJumpThreshold,
  }) {
    if (rawPoints.isEmpty) return const [];

    final ranges = rawPoints.length <= 2
        ? <(int, int)>[(0, rawPoints.length)]
        : _splitSegments(rawPoints, jumpThreshold);
    final out = <FaceTrackPoint>[];
    for (final (start, end) in ranges) {
      final segment = _stabilizeSegment(
        rawPoints.sublist(start, end),
        deadZone,
        smoothness,
      );
      if (out.isNotEmpty && segment.isNotEmpty) {
        _appendInstantCut(out, segment.first);
      }
      out.addAll(segment);
    }
    return out;
  }

  /// Splits the timeline wherever the raw center jumps by >= [threshold] in X
  /// or Y — a speaker switch or a hard cut, never gradual camera motion — or
  /// wherever the person was invisible for a while (a time gap means a new
  /// shot too; smoothing across it would crawl through empty space).
  static List<(int, int)> _splitSegments(
    List<FaceTrackPoint> rawPoints,
    double threshold,
  ) {
    final ranges = <(int, int)>[];
    var start = 0;
    for (var i = 1; i < rawPoints.length; i++) {
      final dx = (rawPoints[i].normX - rawPoints[i - 1].normX).abs();
      final dy = (rawPoints[i].normY - rawPoints[i - 1].normY).abs();
      final gap = rawPoints[i].timeSec - rawPoints[i - 1].timeSec;
      if (dx >= threshold || dy >= threshold || gap > 1.5) {
        ranges.add((start, i));
        start = i;
      }
    }
    ranges.add((start, rawPoints.length));
    return ranges;
  }

  /// Keeps the previous position alive for 1ms past the boundary, then the new
  /// segment starts: FFmpeg snaps the crop with **zero** frames in between.
  static void _appendInstantCut(List<FaceTrackPoint> out, FaceTrackPoint next) {
    final previous = out.last;
    final stepTime = next.timeSec - 0.001;
    if (stepTime > previous.timeSec) {
      out.add(
        FaceTrackPoint(
          timeSec: stepTime,
          normX: previous.normX,
          normY: previous.normY,
        ),
      );
    }
  }

  /// Stage A (dead-zone anchor) + Stage B (zero-phase bidirectional EMA),
  /// run on a **single** continuous segment only.
  static List<FaceTrackPoint> _stabilizeSegment(
    List<FaceTrackPoint> points,
    double deadZone,
    double smoothness,
  ) {
    if (points.isEmpty) return const [];

    final anchored = <FaceTrackPoint>[];
    var anchorX = points.first.normX;
    var anchorY = points.first.normY;
    for (final point in points) {
      if ((point.normX - anchorX).abs() > deadZone) anchorX = point.normX;
      if ((point.normY - anchorY).abs() > deadZone) anchorY = point.normY;
      anchored.add(
        FaceTrackPoint(timeSec: point.timeSec, normX: anchorX, normY: anchorY),
      );
    }

    final alpha = smoothness.clamp(0.01, 1.0);
    final forward = List<FaceTrackPoint>.from(anchored);
    for (var i = 1; i < forward.length; i++) {
      forward[i] = FaceTrackPoint(
        timeSec: anchored[i].timeSec,
        normX: alpha * anchored[i].normX + (1 - alpha) * forward[i - 1].normX,
        normY: alpha * anchored[i].normY + (1 - alpha) * forward[i - 1].normY,
      );
    }
    final smoothed = List<FaceTrackPoint>.from(forward);
    for (var i = forward.length - 2; i >= 0; i--) {
      smoothed[i] = FaceTrackPoint(
        timeSec: forward[i].timeSec,
        normX: alpha * forward[i].normX + (1 - alpha) * smoothed[i + 1].normX,
        normY: alpha * forward[i].normY + (1 - alpha) * smoothed[i + 1].normY,
      );
    }
    return smoothed;
  }

  /// RDP with a growing epsilon until the segment fits its keyframe budget.
  static List<FaceTrackPoint> _simplifySegment(
    List<FaceTrackPoint> points,
    int budget,
  ) {
    if (points.length <= budget) return points;

    var epsilon = 0.002;
    for (var attempt = 0; attempt < 30; attempt++) {
      final simplified = _rdp(points, epsilon);
      if (simplified.length <= budget) return simplified;
      epsilon *= 1.6;
    }

    // Uniform + end-preserving fallback.
    final step = (points.length - 1) / max(1, budget - 1);
    final sampled = <FaceTrackPoint>[];
    for (var i = 0; i < budget; i++) {
      sampled.add(points[(i * step).round().clamp(0, points.length - 1)]);
    }
    return sampled;
  }

  /// Last-resort cap: keeps both ends and every instant cut, samples the rest.
  static List<FaceTrackPoint> _enforceBudget(
    List<FaceTrackPoint> points,
    int maxKeyframes,
  ) {
    if (points.length <= maxKeyframes) return points;

    final kept = <int>{0, points.length - 1};
    for (var i = 1; i < points.length; i++) {
      if (points[i].timeSec - points[i - 1].timeSec <= 0.0011) {
        kept
          ..add(i - 1)
          ..add(i);
      }
    }

    final remaining = maxKeyframes - kept.length;
    if (remaining > 0) {
      final rest = [
        for (var i = 0; i < points.length; i++)
          if (!kept.contains(i)) i,
      ];
      final step = rest.length / remaining;
      for (var i = 0; i < remaining; i++) {
        final index = (i * step).floor();
        if (index < rest.length) kept.add(rest[index]);
      }
    }

    final ordered = kept.toList()..sort();
    return ordered.map((i) => points[i]).toList();
  }

  /// Global RDP simplification, capped at [maxKeyframes].
  ///
  /// Kept as a public helper for callers that already hold a smooth single-shot
  /// trajectory; multi-speaker paths must go through [buildKeyframes].
  static List<FaceTrackPoint> simplifyKeyframes(
    List<FaceTrackPoint> points, {
    int maxKeyframes = FaceDetectionService.maxKeyframes,
  }) {
    if (points.length <= maxKeyframes) {
      return List<FaceTrackPoint>.unmodifiable(points);
    }

    var epsilon = 0.002;
    List<FaceTrackPoint> simplified = points;
    for (var attempt = 0; attempt < 40; attempt++) {
      simplified = _rdp(points, epsilon);
      if (simplified.length <= maxKeyframes) break;
      epsilon *= 1.5;
    }
    if (simplified.length > maxKeyframes) {
      simplified = _enforceBudget(points, maxKeyframes);
    }
    return List<FaceTrackPoint>.unmodifiable(simplified);
  }

  static List<FaceTrackPoint> _rdp(
    List<FaceTrackPoint> points,
    double epsilon,
  ) {
    final keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;

    final start = points.first.timeSec;
    final span = (points.last.timeSec - start).abs();
    final timeScale = span > 0 ? 1.0 / span : 0.0;

    double px(FaceTrackPoint p) => (p.timeSec - start) * timeScale;

    void recurse(int first, int last) {
      if (last <= first + 1) return;
      final a = points[first];
      final b = points[last];
      final ax = px(a);
      final bx = px(b);
      var maxDistance = -1.0;
      var index = -1;
      for (var i = first + 1; i < last; i++) {
        final p = points[i];
        final distance = max(
          _perpendicularDistance(px(p), p.normX, ax, a.normX, bx, b.normX),
          _perpendicularDistance(px(p), p.normY, ax, a.normY, bx, b.normY),
        );
        if (distance > maxDistance) {
          maxDistance = distance;
          index = i;
        }
      }
      if (index > 0 && maxDistance > epsilon) {
        keep[index] = true;
        recurse(first, index);
        recurse(index, last);
      }
    }

    recurse(0, points.length - 1);
    return [
      for (var i = 0; i < points.length; i++)
        if (keep[i]) points[i],
    ];
  }

  static double _perpendicularDistance(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final dx = bx - ax;
    final dy = by - ay;
    final length = sqrt(dx * dx + dy * dy);
    if (length == 0) {
      final ex = px - ax;
      final ey = py - ay;
      return sqrt(ex * ex + ey * ey);
    }
    return ((px - ax) * dy - (py - ay) * dx).abs() / length;
  }

  // ---------------------------------------------------------------------------
  // Backward-compatible Shorts API (pixel coordinates)
  // ---------------------------------------------------------------------------

  /// Average speaker face center X in **source pixels**, or `null`.
  static Future<double?> detectFaceCenterX(
    String videoPath,
    double startSec,
    double endSec, {
    int sampleCount = 6,
  }) async {
    final result = await analyzeVideoFaceTrack(
      videoPath,
      startSec: startSec,
      endSec: endSec,
    );
    if (result == null) return null;
    final width = result.sourceWidth > 0 ? result.sourceWidth : 1080;
    return result.avgNormX * width;
  }

  /// Smoothed speaker center X per second of the clip, in **source pixels**.
  static Future<List<double>?> detectFacePath(
    String videoPath,
    double startSec,
    double endSec,
  ) async {
    final clipDur = endSec - startSec;
    if (clipDur < 1) return null;

    final result = await analyzeVideoFaceTrack(
      videoPath,
      startSec: startSec,
      endSec: endSec,
    );
    if (result == null) return null;

    final sampleCount = clipDur.round().clamp(3, 120);
    final width = result.sourceWidth > 0 ? result.sourceWidth : 1080;
    return List<double>.generate(sampleCount, (i) {
      final t = startSec + clipDur * (i / max(sampleCount - 1, 1));
      final (nx, _) = result.sampleAt(t);
      return (nx * width).clamp(0.0, width.toDouble());
    });
  }
}
