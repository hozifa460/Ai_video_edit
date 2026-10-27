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

/// Result of one face-analysis pass: the raw samples plus a stabilized,
/// FFmpeg-safe keyframe trajectory.
class FaceTrackResult {
  /// Speaker position for every sampled analysis frame.
  final List<FaceTrackPoint> rawPoints;

  /// Dead-zone + zero-phase EMA + RDP simplified trajectory (<= 18 points).
  final List<FaceTrackPoint> keyframes;

  final double avgNormX;
  final double avgNormY;
  final int facesDetectedCount;

  /// Probed source dimensions (0 when unknown). Used by the legacy
  /// pixel-based Shorts API.
  final int sourceWidth;
  final int sourceHeight;

  const FaceTrackResult({
    required this.rawPoints,
    required this.keyframes,
    required this.avgNormX,
    required this.avgNormY,
    required this.facesDetectedCount,
    this.sourceWidth = 0,
    this.sourceHeight = 0,
  });

  /// Linearly interpolated speaker position at [timeSec], for the live preview
  /// overlay. Outside the sampled range the nearest keyframe is held.
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

/// Internal per-person state used while selecting the active speaker.
class _SpeakerTrack {
  _SpeakerTrack(this.key);

  final int key;
  int hits = 0;
  int lastSeenFrame = -1;
  double normX = 0.5;
  double normY = 0.42;
  double areaNorm = 0;
  double mouthActivity = 0;
  double? lastMouthOpen;
  double lastMouthX = 0;
  double lastMouthY = 0;
  bool hasMouth = false;

  /// Mouth movement dominates (that is what "speaker" means), face area breaks
  /// ties, and persistence keeps a long-lived subject preferred.
  double get score =>
      mouthActivity * 2.0 + areaNorm + 0.05 * (min(hits, 10) / 10);
}

/// Real ML Kit + FFmpeg speaker tracking.
///
/// Pipeline: **one** FFmpeg frame-extraction pass → one `FaceDetector` for all
/// frames → per-frame speaker selection with mouth-activity scoring and
/// hysteresis → dead-zone + bidirectional EMA + RDP keyframe simplification.
class FaceDetectionService {
  FaceDetectionService._();

  static const double defaultDeadZone = 0.045;
  static const double defaultSmoothness = 0.28;
  static const int maxKeyframes = 18;

  // ---------------------------------------------------------------------------
  // Analysis
  // ---------------------------------------------------------------------------

  /// Analyzes [videoPath] and returns the stabilized 2D speaker trajectory, or
  /// `null` when no face could be detected at all.
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

    // Dense sampling for short clips, sparse for long ones: analysis cost stays
    // roughly constant instead of growing with the video length.
    final double sampleFps;
    if (clipDuration <= 60) {
      sampleFps = 2.0;
    } else if (clipDuration <= 180) {
      sampleFps = 1.0;
    } else {
      sampleFps = max(0.5, 120.0 / clipDuration);
    }

    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory(
      '${tempDir.path}/face_track_${DateTime.now().millisecondsSinceEpoch}',
    );

    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: false,
        enableLandmarks: true,
        enableContours: false,
        enableTracking: true,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );

    try {
      await framesDir.create(recursive: true);
      onProgress?.call(0.05, 'Extracting analysis frames...');

      // ONE FFmpeg pass for the whole clip (the old per-second loop spawned a
      // process per sample and was the main analysis bottleneck).
      final command =
          '-ss ${startSec.toStringAsFixed(3)} '
          '-t ${clipDuration.toStringAsFixed(3)} -i "$videoPath" '
          '-vf "fps=$sampleFps,scale=480:-2" -q:v 4 '
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

      // Real decoded dimensions: normalized coordinates must be exact, not
      // derived from the probed (possibly rotated) stream size.
      final firstImage = await _decodeImage(File(frames.first.path));
      final imgWidth = firstImage.width.toDouble();
      final imgHeight = firstImage.height.toDouble();
      firstImage.dispose();
      if (imgWidth <= 0 || imgHeight <= 0) return null;

      final tracks = <int, _SpeakerTrack>{};
      final rawPoints = <FaceTrackPoint>[];
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
          final nx = (box.center.dx / imgWidth).clamp(0.0, 1.0);
          final ny = (box.center.dy / imgHeight).clamp(0.0, 1.0);
          final area =
              ((box.width / imgWidth) * (box.height / imgHeight)).clamp(
                0.0,
                1.0,
              );

          final track = _associateFace(tracks, face, nx, ny);
          track.hits++;
          track.lastSeenFrame = i;
          track.normX = nx;
          track.normY = ny;
          track.areaNorm = area;
          _updateMouthActivity(track, face, box);
          present.add(track);
        }

        currentSpeaker = _selectSpeaker(
          present,
          currentSpeaker,
          frameIndex: i,
        );

        if (currentSpeaker != null && present.contains(currentSpeaker)) {
          lastX = currentSpeaker.normX;
          lastY = currentSpeaker.normY;
        }
        // Frames without any usable face hold the last camera position rather
        // than snapping back to center.
        rawPoints.add(
          FaceTrackPoint(timeSec: timeSec, normX: lastX, normY: lastY),
        );

        if (i % 4 == 0 || i == frames.length - 1) {
          onProgress?.call(
            0.1 + 0.8 * ((i + 1) / frames.length),
            'Tracking speaker ${i + 1}/${frames.length}...',
          );
        }
      }

      if (facesDetectedCount == 0 || rawPoints.isEmpty) {
        AppLogger().i('FaceTrack: no faces detected in ${frames.length} frames');
        return null;
      }

      final keyframes = buildKeyframes(
        rawPoints,
        deadZone: deadZone,
        smoothness: smoothness,
      );
      final avgX =
          rawPoints.map((p) => p.normX).reduce((a, b) => a + b) /
          rawPoints.length;
      final avgY =
          rawPoints.map((p) => p.normY).reduce((a, b) => a + b) /
          rawPoints.length;

      onProgress?.call(1.0, 'Speaker track ready');
      AppLogger().i(
        'FaceTrack: ${frames.length} frames, ${tracks.length} track(s), '
        '$facesDetectedCount face(s), ${keyframes.length} keyframes',
      );

      return FaceTrackResult(
        rawPoints: rawPoints,
        keyframes: keyframes,
        avgNormX: avgX,
        avgNormY: avgY,
        facesDetectedCount: facesDetectedCount,
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

  /// Associates a detected face with an existing track using ML Kit's
  /// `trackingId`, falling back to nearest-center matching when it is absent.
  static _SpeakerTrack _associateFace(
    Map<int, _SpeakerTrack> tracks,
    Face face,
    double nx,
    double ny,
  ) {
    final trackingId = face.trackingId;
    if (trackingId != null && tracks.containsKey(trackingId)) {
      return tracks[trackingId]!;
    }

    _SpeakerTrack? best;
    var bestDistance = 0.22; // normalized center distance threshold
    for (final track in tracks.values) {
      final dx = track.normX - nx;
      final dy = track.normY - ny;
      final distance = sqrt(dx * dx + dy * dy);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = track;
      }
    }
    if (best != null) return best;

    final key = trackingId ?? (1000000 + tracks.length);
    final track = _SpeakerTrack(key);
    tracks[key] = track;
    return track;
  }

  /// Normalized mouth openness/movement from the mouth + nose landmarks.
  static void _updateMouthActivity(
    _SpeakerTrack track,
    Face face,
    ui.Rect box,
  ) {
    final bottom = face.landmarks[FaceLandmarkType.bottomMouth]?.position;
    final left = face.landmarks[FaceLandmarkType.leftMouth]?.position;
    final right = face.landmarks[FaceLandmarkType.rightMouth]?.position;
    final nose = face.landmarks[FaceLandmarkType.noseBase]?.position;
    final height = box.height > 0 ? box.height : 1.0;

    double? openness;
    if (bottom != null && nose != null) {
      openness = ((bottom.y - nose.y) / height).clamp(0.0, 2.0);
    }

    var mx = 0.0;
    var my = 0.0;
    var count = 0;
    void add(Point<int>? p) {
      if (p == null) return;
      mx += p.x.toDouble();
      my += p.y.toDouble();
      count++;
    }

    add(bottom);
    add(left);
    add(right);

    if (count == 0 && openness == null) {
      track.hasMouth = false;
      return;
    }
    if (count == 0) {
      mx = box.center.dx;
      my = box.center.dy + box.height * 0.15;
      count = 1;
    }
    mx /= count;
    my /= count;

    var movement = 0.0;
    if (track.hasMouth) {
      final dx = (mx - track.lastMouthX) / height;
      final dy = (my - track.lastMouthY) / height;
      movement = sqrt(dx * dx + dy * dy);
      if (openness != null && track.lastMouthOpen != null) {
        // Opening/closing the mouth is a stronger speech cue than translation.
        movement += (openness - track.lastMouthOpen!).abs() * 2.0;
      }
    }
    track.mouthActivity = track.mouthActivity * 0.6 + movement * 0.4;
    track.lastMouthOpen = openness ?? track.lastMouthOpen;
    track.lastMouthX = mx;
    track.lastMouthY = my;
    track.hasMouth = true;
  }

  /// Picks the speaker for this frame with hysteresis so two talking faces do
  /// not make the camera ping-pong between them.
  static _SpeakerTrack? _selectSpeaker(
    List<_SpeakerTrack> present,
    _SpeakerTrack? current, {
    required int frameIndex,
  }) {
    if (present.isEmpty) return current;
    if (current != null && present.contains(current)) {
      var best = current;
      for (final candidate in present) {
        if (candidate.score > best.score) best = candidate;
      }
      // A challenger must be clearly better and have been seen more than once.
      if (!identical(best, current) &&
          best.hits >= 2 &&
          best.score > current.score * 1.3 + 0.02) {
        return best;
      }
      return current;
    }

    // The current speaker disappeared: allow an immediate handover after a few
    // frames, otherwise hold the last camera position.
    if (current != null && frameIndex - current.lastSeenFrame < 4) {
      return current;
    }
    var best = present.first;
    for (final candidate in present) {
      if (candidate.score > best.score) best = candidate;
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // Camera stabilization (pure, unit-testable)
  // ---------------------------------------------------------------------------

  /// Stage A (dead-zone) + Stage B (zero-phase bidirectional EMA) + Stage C
  /// (RDP simplification to at most [maxKeyframes] keyframes).
  static List<FaceTrackPoint> buildKeyframes(
    List<FaceTrackPoint> rawPoints, {
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    int maxKeyframes = FaceDetectionService.maxKeyframes,
  }) {
    final smoothed = stabilizeTrack(
      rawPoints,
      deadZone: deadZone,
      smoothness: smoothness,
    );
    return simplifyKeyframes(smoothed, maxKeyframes: maxKeyframes);
  }

  /// Dead-zone anchor filtering followed by forward+backward EMA.
  ///
  /// Small natural head movements stay inside the dead-zone and produce **no**
  /// camera motion at all; real moves are smoothed in both directions so pans
  /// start and stop gently without a lag spike at the end of the clip.
  static List<FaceTrackPoint> stabilizeTrack(
    List<FaceTrackPoint> rawPoints, {
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
  }) {
    if (rawPoints.isEmpty) return const [];

    // Stage A — dead-zone / safe margin.
    final anchored = <FaceTrackPoint>[];
    var anchorX = rawPoints.first.normX;
    var anchorY = rawPoints.first.normY;
    for (final point in rawPoints) {
      if ((point.normX - anchorX).abs() > deadZone) anchorX = point.normX;
      if ((point.normY - anchorY).abs() > deadZone) anchorY = point.normY;
      anchored.add(
        FaceTrackPoint(timeSec: point.timeSec, normX: anchorX, normY: anchorY),
      );
    }

    // Stage B — forward EMA then backward EMA (zero-phase).
    final alpha = smoothness.clamp(0.01, 1.0);
    final forward = List<FaceTrackPoint>.from(anchored);
    for (var i = 1; i < forward.length; i++) {
      forward[i] = FaceTrackPoint(
        timeSec: anchored[i].timeSec,
        normX:
            alpha * anchored[i].normX + (1 - alpha) * forward[i - 1].normX,
        normY:
            alpha * anchored[i].normY + (1 - alpha) * forward[i - 1].normY,
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

  /// Ramer-Douglas-Peucker simplification of the camera trajectory.
  ///
  /// FFmpeg evaluates the crop `x`/`y` expressions for every frame, and a
  /// piecewise expression built from hundreds of points exceeds its parser
  /// nesting limit. The result is therefore always capped at [maxKeyframes].
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
      // Uniform + peak-preserving fallback, always keeping both ends.
      final result = <FaceTrackPoint>[];
      final step = (points.length - 1) / (maxKeyframes - 1);
      for (var i = 0; i < maxKeyframes; i++) {
        result.add(points[(i * step).round().clamp(0, points.length - 1)]);
      }
      return List<FaceTrackPoint>.unmodifiable(result);
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

    // Time is normalized into [0,1] so it is comparable with the normalized
    // face coordinates when measuring perpendicular distance.
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

  /// Average speaker face center X in **source pixels**, or `null` when no face
  /// was found. Delegates to the single-pass 2D analysis.
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
