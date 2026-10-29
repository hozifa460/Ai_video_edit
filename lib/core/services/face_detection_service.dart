import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
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

  /// `true` → the transition from the previous keyframe to this one is an
  /// **instant jump cut** (1ms step); `false` → smooth linear interpolation.
  final bool isCut;

  /// `true` when the user added/edited this keyframe in the manual editor.
  final bool isManual;

  const FaceTrackPoint({
    required this.timeSec,
    this.normX = 0.5,
    this.normY = 0.42,
    this.isCut = false,
    this.isManual = false,
  });

  FaceTrackPoint copyWith({
    double? timeSec,
    double? normX,
    double? normY,
    bool? isCut,
    bool? isManual,
  }) {
    return FaceTrackPoint(
      timeSec: timeSec ?? this.timeSec,
      normX: normX ?? this.normX,
      normY: normY ?? this.normY,
      isCut: isCut ?? this.isCut,
      isManual: isManual ?? this.isManual,
    );
  }

  @override
  String toString() =>
      'FaceTrackPoint(t=${timeSec.toStringAsFixed(3)}, '
      'x=${normX.toStringAsFixed(3)}, y=${normY.toStringAsFixed(3)}'
      '${isCut ? ', CUT' : ''}${isManual ? ', manual' : ''})';
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

  /// Interpolated speaker position at [timeSec], for the live preview overlay.
  ///
  /// Honors [FaceTrackPoint.isCut]: a cut keyframe holds the previous position
  /// until its timestamp and snaps immediately at `timeSec >= b.timeSec`.
  (double normX, double normY) sampleAt(double timeSec) =>
      sampleKeyframes(keyframes, timeSec);

  /// [sampleAt] over any keyframe list (used by the manual editor too).
  static (double normX, double normY) sampleKeyframes(
    List<FaceTrackPoint> keyframes,
    double timeSec,
  ) {
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
        if (FaceDetectionService.isEffectiveCut(a, b)) {
          // Instant cut: hold `a` right up to (but excluding) `b.timeSec`.
          return timeSec < b.timeSec
              ? (a.normX, a.normY)
              : (b.normX, b.normY);
        }
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

  /// Landmark-stabilized face box (prevents ML Kit box-padding jitter from
  /// shifting the mouth ROI across a static beard or collar).
  double stabNx0 = 0.4;
  double stabNy0 = 0.25;
  double stabNx1 = 0.6;
  double stabNy1 = 0.55;

  /// Previous **relative** lip geometry (never absolute image coordinates).
  double? lastOpen;
  double? lastWidth;

  /// Previous inner-mouth vs upper-cheek luma contrast (invariant to static
  /// beards and global lighting shifts).
  double? lastMouthContrast;

  /// Per-frame center displacement of this track (used to penalize fast-moving
  /// passersby with low mouth activity).
  double lastMoveDelta = 0;

  /// Activity score for a silhouette (anonymized) track, computed from head
  /// gesture + mask-edge motion + a solo floor for prominent silhouettes.
  double silhouetteActivity = 0;

  /// Track observed through the silhouette/motion fallback (ML Kit saw no
  /// face). Cleared as soon as a real face is associated with this track.
  bool isSilhouette = false;

  /// Rolling window of recent lip deltas.
  final List<double> lipDeltas = <double>[];

  /// Consecutive frames without speech-level lip articulation.
  int silentFrames = 0;

  /// Last timestamp where this person showed active lip articulation.
  double lastSpokeSec = -10.0;

  /// Every frame in which this person was visible, with its own trajectory.
  final List<FaceTrackPoint> points = <FaceTrackPoint>[];

  double? lockStartSec;

  /// Number of frames in the rolling window with speech-level mouth motion.
  int get speakingFrames {
    var count = 0;
    for (final d in lipDeltas) {
      if (d >= 0.014) count++;
    }
    return count;
  }

  void recordSpeechSample(
    double delta, {
    required double nowSec,
    required int window,
  }) {
    lipDeltas.add(delta);
    if (lipDeltas.length > window) {
      lipDeltas.removeAt(0);
    }
    if (delta >= 0.014) {
      silentFrames = 0;
      lastSpokeSec = nowSec;
    } else {
      silentFrames++;
    }
  }

  /// Sustained mouth movement dominates (that is what "speaking" means);
  /// face area is strictly a tiny tie-breaker when nobody in the shot has
  /// spoken, so a silent bystander standing closer to the camera can never
  /// outscore a smaller speaking face.
  double get score {
    if (isSilhouette) {
      return silhouetteActivity * 12.0 + areaNorm * 0.04;
    }
    final activeCount = speakingFrames;
    final mult = activeCount >= 2 ? 16.0 : (activeCount == 1 ? 8.5 : 4.0);
    var s = recentActivity * mult +
        areaNorm * 0.06 +
        0.01 * (min(hits, 6) / 6);
    if (lastMoveDelta > 0.045 && activeCount < 2) s *= 0.15;
    return s;
  }

  double get areaNorm => (normW * normH).clamp(0.0, 1.0);

  double get recentActivity {
    if (isSilhouette) return silhouetteActivity;
    if (lipDeltas.isEmpty) return 0;
    var total = 0.0;
    for (final delta in lipDeltas) {
      total += delta;
    }
    return total / lipDeltas.length;
  }
}

/// Foreground-subject observation produced by
/// [FaceDetectionService.detectSilhouetteOrMotionSubject] when ML Kit finds no
/// face (pitch-black silhouette guest, occluded/partially visible speaker).
typedef SilhouetteSubject = ({
  double normX,
  double normY,
  double normW,
  double normH,
  double mass,
  bool sceneChanged,
});

/// Real ML Kit + FFmpeg speaker tracking.
///
/// Pipeline: **one** FFmpeg frame-extraction pass (960px, dense fps) → one
/// accurate `FaceDetector` for all frames → IoU/center association per person →
/// lip-relative speech activity with sustained-speech hysteresis → shot
/// segmentation (no smoothing across speaker cuts) → per-shot dead-zone +
/// bidirectional EMA → RDP simplification capped at [maxKeyframes] keyframes.
class FaceDetectionService {
  FaceDetectionService._();

  static const double defaultDeadZone = 0.045;
  static const double defaultSmoothness = 0.28;

  /// FFmpeg-safe keyframe cap. With the balanced binary-tree expression the
  /// nesting depth is `log2(96) ≈ 7`, so this never overflows the parser.
  static const int maxKeyframes = 96;

  /// A normalized move this large (in one sample) is a **speaker switch or
  /// scene cut**, not camera motion: smoothing must stop at the boundary.
  static const double speakerJumpThreshold = 0.135;

  /// Association tolerances (normalized frame units).
  static const double associationDistance = 0.15;
  static const double minFaceOverlap = 0.1;

  /// Minimum time the camera stays on one speaker before a turn-taking switch.
  static const double speakerLockSeconds = 0.9;

  /// Frames kept in the rolling lip-delta window (~1.5s at 4fps).
  static const int lipWindow = 6;

  /// High-resolution grid used for mouth/upper-face luma analysis (4x4 source
  /// pixels per cell on 960x540 frames).
  static const int mouthGridWidth = 240;
  static const int mouthGridHeight = 135;

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
    if (clipDuration <= 180) {
      sampleFps = 4.0;
    } else if (clipDuration <= 360) {
      sampleFps = 3.0;
    } else {
      sampleFps = max(2.0, 540.0 / clipDuration);
    }

    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory(
      '${tempDir.path}/face_track_${DateTime.now().millisecondsSinceEpoch}',
    );

    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableLandmarks: true,
        // Contours are computed for ONLY the single largest face in ML Kit, so
        // secondary speakers would be starved of lip data. Disable contours and
        // rely on landmarks + the mouth-region pixel delta instead.
        enableContours: false,
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
      var silhouetteHits = 0;
      Uint8List? prevGridBytes;
      Uint8List? prevMouthGridBytes;
      _SpeakerTrack? currentSpeaker;
      var lastX = 0.5;
      var lastY = 0.45;
      double? lastFaceSeenSec;
      var sceneStartPointIdx = 0;
      var sceneSpeakerConfirmed = false;
      // Distant/background false-positive boxes (decor, small objects) must
      // never drive the camera: a person occupies a meaningful share of the
      // frame in any usable interview/podcast shot.
      final minFaceHeight = imgHeight * 0.06;
      final minFaceWidth = imgWidth * 0.035;

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

        final decodedGrids = await _decodeAnalysisGrids(frames[i].path);
        final grid = decodedGrids?.silhouetteGrid;
        final mouthGrid = decodedGrids?.mouthGrid;

        var cut = false;
        if (grid != null) {
          cut = isSceneChange(
            prevGridBytes,
            grid,
            silhouetteGridWidth,
            silhouetteGridHeight,
          );
          if (cut) {
            // Release any speaker lock with 0ms delay so the camera snaps on
            // the exact frame of the cut.
            currentSpeaker = null;
            sceneStartPointIdx = activePoints.length;
            sceneSpeakerConfirmed = false;
          }
        }

        // Process larger foreground faces first so they claim their track
        // before any smaller background faces in the same frame.
        final sortedFaces = List<Face>.of(faces)
          ..sort(
            (a, b) => (b.boundingBox.width * b.boundingBox.height)
                .compareTo(a.boundingBox.width * a.boundingBox.height),
          );

        final present = <_SpeakerTrack>[];
        final faceBoxes = <({double x0, double y0, double x1, double y1})>[];
        var maxFaceArea = 0.0;
        for (final face in sortedFaces) {
          final box = face.boundingBox;
          if (box.height < minFaceHeight || box.width < minFaceWidth) {
            continue; // background noise, not a person
          }
          facesDetectedCount++;
          lastFaceSeenSec = timeSec;
          final nx0 = (box.left / imgWidth).clamp(0.0, 1.0);
          final ny0 = (box.top / imgHeight).clamp(0.0, 1.0);
          final nx1 = (box.right / imgWidth).clamp(0.0, 1.0);
          final ny1 = (box.bottom / imgHeight).clamp(0.0, 1.0);
          final cx = ((nx0 + nx1) / 2).clamp(0.0, 1.0);
          final cy = ((ny0 + ny1) / 2).clamp(0.0, 1.0);

          final fw = nx1 - nx0;
          final fh = ny1 - ny0;
          final fcx = (nx0 + nx1) / 2;
          final area = fw * fh;
          if (area > maxFaceArea) maxFaceArea = area;
          // Expanded person+desk exclusion rect: masks out hat/hair/beard/mic/
          // dark suit/torso AND the studio table directly in front of the
          // visible speaker, so none of it is mistaken for a silhouette.
          faceBoxes.add((
            x0: (fcx - fw * 1.45).clamp(0.0, 1.0),
            y0: (ny0 - fh * 0.45).clamp(0.0, 1.0),
            x1: (fcx + fw * 1.45).clamp(0.0, 1.0),
            y1: (ny1 + fh * 3.20).clamp(0.0, 1.0),
          ));

          final track = _associateFace(
            tracks,
            nowSec: timeSec,
            nx0: nx0,
            ny0: ny0,
            nx1: nx1,
            ny1: ny1,
            cx: cx,
            cy: cy,
            allowExisting: !cut,
          );
          if (track == null) {
            final created = _SpeakerTrack(tracks.length)
              ..stabNx0 = nx0
              ..stabNy0 = ny0
              ..stabNx1 = nx1
              ..stabNy1 = ny1;
            tracks[created.id] = created;
            present.add(created);
            created.lastMoveDelta = 0;
            _updateLipActivity(
              created,
              face,
              box,
              imgWidth: imgWidth,
              imgHeight: imgHeight,
              nx0: nx0,
              ny0: ny0,
              nx1: nx1,
              ny1: ny1,
              prevNx0: nx0,
              prevNy0: ny0,
              prevNx1: nx1,
              prevNy1: ny1,
              hasPrev: false,
              currGrid: null,
              prevGrid: null,
              gridW: mouthGridWidth,
              gridH: mouthGridHeight,
              nowSec: timeSec,
            );
            _updateTrack(created, timeSec, cx, cy, nx1 - nx0, ny1 - ny0);
            created.points.add(
              FaceTrackPoint(timeSec: timeSec, normX: cx, normY: cy),
            );
            continue;
          }

          // Move delta measured against the track's previous position, BEFORE
          // _updateTrack overwrites it.
          final moveDelta = sqrt(
            (cx - track.normX) * (cx - track.normX) +
                (cy - track.normY) * (cy - track.normY),
          );
          track.lastMoveDelta = moveDelta;

          // A real ML Kit face proves this is a visible person: retire any
          // silhouette flag this track may have carried.
          track.isSilhouette = false;
          _updateLipActivity(
            track,
            face,
            box,
            imgWidth: imgWidth,
            imgHeight: imgHeight,
            nx0: nx0,
            ny0: ny0,
            nx1: nx1,
            ny1: ny1,
            prevNx0: track.stabNx0,
            prevNy0: track.stabNy0,
            prevNx1: track.stabNx1,
            prevNy1: track.stabNy1,
            hasPrev: track.hits > 0,
            currGrid: mouthGrid ?? grid,
            prevGrid: prevMouthGridBytes ?? prevGridBytes,
            gridW: mouthGrid != null ? mouthGridWidth : silhouetteGridWidth,
            gridH: mouthGrid != null ? mouthGridHeight : silhouetteGridHeight,
            nowSec: timeSec,
          );
          _updateTrack(track, timeSec, cx, cy, nx1 - nx0, ny1 - ny0);
          track.points.add(
            FaceTrackPoint(timeSec: timeSec, normX: cx, normY: cy),
          );
          present.add(track);
        }

        // Only run the black-mask silhouette detector when fewer than 2 real
        // faces are visible in the frame (in 2+ face crowd/interview shots,
        // dark patches outside faceBoxes are clothing, not a masked speaker).
        final visibleFaceCount = present.length;
        SilhouetteSubject? subject;
        if (grid != null && visibleFaceCount <= 1 && maxFaceArea < 0.035) {
          subject = detectSilhouetteOrMotionSubject(
            grid,
            silhouetteGridWidth,
            silhouetteGridHeight,
            prevGridBytes,
            excludeRects: faceBoxes,
          );
        }

        if (subject != null) {
          silhouetteHits++;
          final matched = _associateSubject(
            tracks,
            nowSec: timeSec,
            normX: subject.normX,
            normY: subject.normY,
            allowExisting: !subject.sceneChanged && !cut,
          );
          _SpeakerTrack subjectTrack;
          if (matched == null) {
            subjectTrack = _SpeakerTrack(tracks.length)
              ..isSilhouette = true;
            tracks[subjectTrack.id] = subjectTrack;
          } else {
            subjectTrack = matched;
            subjectTrack.isSilhouette = true;
          }

          double gestureDelta = 0;
          if (!cut && subjectTrack.hits > 0) {
            final dx = subject.normX - subjectTrack.normX;
            final dy = subject.normY - subjectTrack.normY;
            gestureDelta = sqrt(dx * dx + dy * dy) * 3.0;
          }
          double maskEdge = 0;
          if (prevGridBytes != null && !cut && grid != null) {
            final bx0 = (subject.normX - subject.normW * 0.65).clamp(0.0, 1.0);
            final by0 = (subject.normY - subject.normH * 0.55).clamp(0.0, 1.0);
            final bx1 = (subject.normX + subject.normW * 0.65).clamp(0.0, 1.0);
            final by1 = (subject.normY + subject.normH * 0.65).clamp(0.0, 1.0);
            maskEdge = computeMouthRegionDelta(
              prevGridBytes,
              grid,
              silhouetteGridWidth,
              silhouetteGridHeight,
              nx0: bx0,
              ny0: by0,
              nx1: bx1,
              ny1: by1,
              prevNx0: bx0,
              prevNy0: by0,
              prevNx1: bx1,
              prevNy1: by1,
            );
          }
          var activity = max(gestureDelta, maskEdge * 3.2);
          _SpeakerTrack? visibleFace;
          for (final t in present) {
            if (!t.isSilhouette) {
              visibleFace = t;
              break;
            }
          }
          if (visibleFace == null) {
            // Solo silhouette shot (no uncovered face in frame).
            activity = max(activity, 0.045);
            subjectTrack.silhouetteActivity = prevGridBytes != null && !cut
                ? subjectTrack.silhouetteActivity * 0.35 + activity * 0.65
                : activity;
            subjectTrack.lastSpokeSec = timeSec;
          } else {
            // 1 visible face + 1 silhouette/niqab subject: only activate the
            // silhouette when the visible face has been genuinely silent (not
            // just taking a 1-frame breath between words!).
            final visibleSpeaking = visibleFace.speakingFrames >= 1 ||
                visibleFace.recentActivity >= 0.015 ||
                (timeSec - visibleFace.lastSpokeSec) < 1.5;
            if (!visibleSpeaking && visibleFace.silentFrames >= 3) {
              activity = max(activity, 0.055);
              subjectTrack.silhouetteActivity = prevGridBytes != null && !cut
                  ? subjectTrack.silhouetteActivity * 0.35 + activity * 0.65
                  : activity;
              subjectTrack.lastSpokeSec = timeSec;
            } else {
              subjectTrack.silhouetteActivity = 0.002;
            }
          }

          _updateTrack(
            subjectTrack,
            timeSec,
            subject.normX,
            subject.normY,
            subject.normW,
            subject.normH,
          );
          subjectTrack.points.add(
            FaceTrackPoint(
              timeSec: timeSec,
              normX: subject.normX,
              normY: subject.normY,
            ),
          );
          present.add(subjectTrack);
        } else if (present.isEmpty) {
          final stale = lastFaceSeenSec == null ||
              timeSec - lastFaceSeenSec > emptyFrameCenterResetSec;
          if (cut || stale) {
            lastX = 0.5;
            lastY = 0.45;
          }
        }

        if (grid != null) prevGridBytes = grid;
        if (mouthGrid != null) prevMouthGridBytes = mouthGrid;

        final prevSpeaker = currentSpeaker;
        currentSpeaker = _selectSpeaker(
          present,
          currentSpeaker,
          nowSec: timeSec,
        );
        final switchedSpeaker = cut ||
            (currentSpeaker != null &&
                prevSpeaker != null &&
                !identical(currentSpeaker, prevSpeaker));
        if (currentSpeaker != null && present.contains(currentSpeaker)) {
          lastX = currentSpeaker.normX;
          lastY = currentSpeaker.normY;

          // Scene-Start Backfill: on the first frames after a scene cut (or
          // clip start), frame 0 has no prior lip delta so tie-breaking may
          // briefly pick a silent bystander before the real speaker's lips
          // move. Once the scene's speaker is confirmed within 2.5s of the
          // scene start, backfill the scene's initial frames so the camera
          // starts directly on the active speaker from the cut!
          final confirmedNow = (!currentSpeaker.isSilhouette &&
                  currentSpeaker.speakingFrames >= 1 &&
                  currentSpeaker.recentActivity >= 0.015) ||
              (currentSpeaker.isSilhouette &&
                  currentSpeaker.silhouetteActivity >= 0.045);
          if (!sceneSpeakerConfirmed && confirmedNow) {
            sceneSpeakerConfirmed = true;
            if (activePoints.length > sceneStartPointIdx &&
                (timeSec - activePoints[sceneStartPointIdx].timeSec) <= 2.5) {
              for (var k = sceneStartPointIdx; k < activePoints.length; k++) {
                final tK = activePoints[k].timeSec;
                var bx = currentSpeaker.normX;
                var by = currentSpeaker.normY;
                var bestDt = double.infinity;
                for (final pt in currentSpeaker.points) {
                  final dt = (pt.timeSec - tK).abs();
                  if (dt < bestDt && dt <= 2.6) {
                    bestDt = dt;
                    bx = pt.normX;
                    by = pt.normY;
                  }
                }
                activePoints[k] = FaceTrackPoint(
                  timeSec: tK,
                  normX: bx,
                  normY: by,
                  isCut: k == sceneStartPointIdx && sceneStartPointIdx > 0,
                );
              }
            }
          }
        }
        activePoints.add(
          FaceTrackPoint(
            timeSec: timeSec,
            normX: lastX,
            normY: lastY,
            isCut: switchedSpeaker && activePoints.isNotEmpty,
          ),
        );

        if (i % 8 == 0 || i == frames.length - 1) {
          onProgress?.call(
            0.1 + 0.8 * ((i + 1) / frames.length),
            'Tracking speaker ${i + 1}/${frames.length}...',
          );
        }
      }

      if ((facesDetectedCount == 0 && silhouetteHits == 0) ||
          activePoints.isEmpty) {
        AppLogger().i(
          'FaceTrack: no faces and no foreground subject in '
          '${frames.length} frames',
        );
        return null;
      }

      final keyframes = buildKeyframes(
        activePoints,
        deadZone: deadZone,
        smoothness: smoothness,
      );
      final profiles = _buildProfiles(tracks, frameCount: frames.length);
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

  // ---------------------------------------------------------------------------
  // Silhouette / occluded-speaker fallback
  // ---------------------------------------------------------------------------

  /// Analysis-grid size for the silhouette fallback (fast: 3.6k cells).
  static const int silhouetteGridWidth = 80;
  static const int silhouetteGridHeight = 45;

  /// Mean absolute luma difference (0..255) above which two grids count as a
  /// scene cut (identity must never carry over a hard cut).
  static const double silhouetteSceneChangeThreshold = 16.0;

  /// Normalized search region for the anonymized silhouette (keeps out
  /// letterbox bars, lower-third graphics and playback chrome). Widened so
  /// speakers near the left/right edges of wide or close shots are not
  /// clipped.
  static const double silhouetteRegionX0 = 0.0;
  static const double silhouetteRegionX1 = 1.0;
  static const double silhouetteRegionY0 = 0.12;
  static const double silhouetteRegionY1 = 0.92;

  /// An anonymized guest is masked with a **contiguous pitch-black** shape:
  /// near-zero luma AND almost no RGB channel spread (colored wood, bronze
  /// and warm studio decor never qualify). Sharp edges, gradients and generic
  /// motion are deliberately NOT person signals — studio furniture, glowing
  /// tables, microphones and wall decorations all have sharp edges, and
  /// locking onto them was a real-world false positive.
  static const int silhouetteMaxLuma = 24;
  static const int silhouetteNeighborhoodLuma = 28;
  static const int silhouetteMaxChannelSpread = 14;

  /// The studio background must be clearly brighter than the black mask.
  static const double silhouetteMinBackgroundLuma = 38;

  /// Human-torso credibility guards: the mask must be seat-sized (1.4%..48% of
  /// the grid), anchored low like a seated person and tall/wide enough to be
  /// a torso — anything smaller or higher is a prop or decoration.
  static const double silhouetteMinClusterFraction = 0.014;
  static const double silhouetteMaxClusterFraction = 0.48;
  static const double silhouetteMinBottomFraction = 0.52;
  static const double silhouetteMaxTopFraction = 0.65;
  static const double silhouetteMinHeightFraction = 0.15;
  static const double silhouetteMinWidthFraction = 0.055;

  /// With no credible subject at all (scene cut or empty wall for this long),
  /// the camera resets to the frame center instead of holding the previous
  /// closeup's off-center position.
  static const double emptyFrameCenterResetSec = 1.5;

  /// A segment where every sample stays within this distance (both axes) of
  /// its median collapses to ONE clean shot keyframe instead of a noisy RDP
  /// chain — the interview/podcast default. Raised to 0.20 so normal seated
  /// head/posture shifts (<=20% of frame) lock into a single tripod keyframe
  /// instead of drifting as smooth multi-second pans.
  /// Tight steady-shot threshold: seated jitter (<= 4% of frame) collapses to
  /// one clean keyframe, while any real speaker movement (> 4% of frame) is
  /// followed smoothly like a real cameraman.
  static const double shotSteadyTolerance = 0.04;

  /// Decodes one analysis JPEG once and returns both:
  ///  - `silhouetteGrid`: 80x45 box-averaged RGBA grid for scene-cut and
  ///    silhouette detection;
  ///  - `mouthGrid`: 240x135 box-averaged RGBA grid (9x finer) for accurate
  ///    lip-motion and upper-face rigid-motion cancellation.
  static Future<({Uint8List silhouetteGrid, Uint8List mouthGrid})?>
      _decodeAnalysisGrids(String path) async {
    try {
      final image = await _decodeImage(File(path));
      try {
        final byteData = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (byteData == null || image.width <= 0 || image.height <= 0) {
          return null;
        }
        final full = byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );
        final silhouetteGrid = _downsampleRgbaBox(
          full,
          image.width,
          image.height,
          silhouetteGridWidth,
          silhouetteGridHeight,
        );
        final mouthGrid = _downsampleRgbaBox(
          full,
          image.width,
          image.height,
          mouthGridWidth,
          mouthGridHeight,
        );
        return (silhouetteGrid: silhouetteGrid, mouthGrid: mouthGrid);
      } finally {
        image.dispose();
      }
    } catch (e) {
      AppLogger().e('FaceTrack: analysis grid decode failed', e);
      return null;
    }
  }

  /// 2x2 box-averaged RGBA downsampler: eliminates single-pixel nearest-neighbor
  /// aliasing on beards, collars, and background patterns.
  static Uint8List _downsampleRgbaBox(
    Uint8List full,
    int srcW,
    int srcH,
    int dstW,
    int dstH,
  ) {
    final grid = Uint8List(dstW * dstH * 4);
    for (var gy = 0; gy < dstH; gy++) {
      final y0 = (gy * srcH) ~/ dstH;
      final y1 = min(srcH - 1, ((gy + 1) * srcH - 1) ~/ dstH);
      final ym = (y0 + y1) >> 1;
      for (var gx = 0; gx < dstW; gx++) {
        final x0 = (gx * srcW) ~/ dstW;
        final x1 = min(srcW - 1, ((gx + 1) * srcW - 1) ~/ dstW);
        final xm = (x0 + x1) >> 1;

        final p00 = (y0 * srcW + x0) * 4;
        final p01 = (y0 * srcW + xm) * 4;
        final p10 = (ym * srcW + x0) * 4;
        final p11 = (ym * srcW + xm) * 4;

        final dst = (gy * dstW + gx) * 4;
        grid[dst] = (full[p00] + full[p01] + full[p10] + full[p11]) >> 2;
        grid[dst + 1] =
            (full[p00 + 1] + full[p01 + 1] + full[p10 + 1] + full[p11 + 1]) >>
                2;
        grid[dst + 2] =
            (full[p00 + 2] + full[p01 + 2] + full[p10 + 2] + full[p11 + 2]) >>
                2;
        grid[dst + 3] = 255;
      }
    }
    return grid;
  }

  /// Finds the **anonymized black-mask guest** in a frame where ML Kit
  /// returned no faces.
  ///
  /// [rgbaBytes] is a raw RGBA grid of `width x height` cells (the service
  /// uses 80x45); [prevRgbaBytes] is the previous decoded grid, used only for
  /// the scene-change score.
  ///
  /// Strict rules — a cell counts as silhouette mass ONLY when:
  ///  - `luma <= 18` AND the RGB channel spread is `<= 14` (a true
  ///    pitch-black mask, never colored wood/decor), on a background whose
  ///    mean luma is `>= 38`;
  ///  - at least 5 of its 9 (3x3) neighbors are also near-black
  ///    (`luma <= 22`), which rejects thin microphone arms, frame borders
  ///    and text overlays.
  ///
  /// The gradient/motion heuristics are GONE: sharp edges and motion are
  /// studio-wide properties (tables, props, decorations) and must never mark
  /// a person.
  ///
  /// Human-torso guards then apply: the largest 4-connected cluster must be
  /// 6%..48% of the grid, anchored low (`bottom >= 0.65h`), reaching into the
  /// upper frame (`top <= 0.55h`), at least `0.22h` tall and `0.10w` wide —
  /// otherwise `null` (wide shots, empty walls, props).
  ///
  /// On success `normX` is the centroid of the cluster's UPPER half
  /// (head/shoulders, not the chair/armrest) and
  /// `normY = (top + clusterHeight * 0.28) / height`.
  static SilhouetteSubject? detectSilhouetteOrMotionSubject(
    Uint8List rgbaBytes,
    int width,
    int height,
    Uint8List? prevRgbaBytes, {
    List<({double x0, double y0, double x1, double y1})>? excludeRects,
  }) {
    if (width <= 2 || height <= 2) return null;
    final count = width * height;
    if (rgbaBytes.length < count * 4) return null;

    // Luma pyramid.
    final luma = Int32List(count);
    var lumaSum = 0;
    for (var i = 0; i < count; i++) {
      final o = i * 4;
      final l =
          (77 * rgbaBytes[o] + 150 * rgbaBytes[o + 1] + 29 * rgbaBytes[o + 2]) >>
          8;
      luma[i] = l;
      lumaSum += l;
    }
    final meanLuma = lumaSum / count;

    // Scene-change score against the previous grid (identity must never
    // carry over a hard cut).
    var sceneChanged = false;
    if (prevRgbaBytes != null && prevRgbaBytes.length >= count * 4) {
      var diffSum = 0;
      for (var i = 0; i < count; i++) {
        final o = i * 4;
        final l =
            (77 * prevRgbaBytes[o] +
                    150 * prevRgbaBytes[o + 1] +
                    29 * prevRgbaBytes[o + 2]) >>
                8;
        diffSum += (luma[i] - l).abs();
      }
      sceneChanged = diffSum / count > silhouetteSceneChangeThreshold;
    }

    // Search region for the seated silhouette.
    final x0 = (silhouetteRegionX0 * width).ceil().clamp(0, width - 1);
    final x1 = (silhouetteRegionX1 * width).floor().clamp(0, width - 1);
    final y0 = (silhouetteRegionY0 * height).ceil().clamp(0, height - 1);
    final y1 = (silhouetteRegionY1 * height).floor().clamp(0, height - 1);
    if (x1 - x0 < 3 || y1 - y0 < 3) return null;
    if (meanLuma < silhouetteMinBackgroundLuma) {
      // Dark scene: no bright studio background to mask against.
      return null;
    }

    // Strict pitch-black mask + 3x3 neighborhood uniformity.
    final mask = Uint8List(count);
    for (var gy = y0; gy <= y1; gy++) {
      for (var gx = x0; gx <= x1; gx++) {
        final i = gy * width + gx;
        final l = luma[i];
        if (l > silhouetteMaxLuma) continue;

        final o = i * 4;
        final hi = max(rgbaBytes[o], max(rgbaBytes[o + 1], rgbaBytes[o + 2]));
        final lo = min(rgbaBytes[o], min(rgbaBytes[o + 1], rgbaBytes[o + 2]));
        if (hi - lo > silhouetteMaxChannelSpread) {
          continue; // colored decor/wood is not an anonymization mask
        }

        // Reject thin structures (mic arms, borders, text): most of the 3x3
        // window must be near-black too.
        var darkNeighbors = 0;
        for (var ny = gy - 1; ny <= gy + 1; ny++) {
          if (ny < 0 || ny >= height) continue;
          for (var nx = gx - 1; nx <= gx + 1; nx++) {
            if (nx < 0 || nx >= width) {
              darkNeighbors++;
              continue;
            }
            if (luma[ny * width + nx] <= silhouetteNeighborhoodLuma) {
              darkNeighbors++;
            }
          }
        }
        if (darkNeighbors >= 5) mask[i] = 1;
      }
    }

    // Top-down ceiling-pillar removal: a seated person's head never touches
    // the top ceiling border (gy = 0..3). Vertical black wall pillars (3-6
    // cells wide) that start at the ceiling and connect to a horizontal
    // microphone arm pull normX toward the empty wall — strip them.
    final pillarPrev = List<bool>.filled(width, false);
    final ceilRows = min(3, height - 1);
    for (var gx = 0; gx < width; gx++) {
      var darkCount = 0;
      for (var gy = 0; gy <= ceilRows; gy++) {
        final i = gy * width + gx;
        final l = luma[i];
        final o = i * 4;
        final hi = max(rgbaBytes[o], max(rgbaBytes[o + 1], rgbaBytes[o + 2]));
        final lo = min(rgbaBytes[o], min(rgbaBytes[o + 1], rgbaBytes[o + 2]));
        if (l <= silhouetteNeighborhoodLuma &&
            hi - lo <= silhouetteMaxChannelSpread + 2) {
          darkCount++;
        }
      }
      if (darkCount >= 2) {
        for (var k = gx - 1; k <= gx + 1; k++) {
          if (k >= 0 && k < width) pillarPrev[k] = true;
        }
      }
    }
    final ceilLimit = min(y1, (height * 0.72).floor());
    for (var gy = y0; gy <= ceilLimit; gy++) {
      final pillarCurr = List<bool>.filled(width, false);
      var gx = x0;
      while (gx <= x1) {
        if (mask[gy * width + gx] != 1) {
          gx++;
          continue;
        }
        final r0 = gx;
        while (gx <= x1 && mask[gy * width + gx] == 1) {
          gx++;
        }
        final r1 = gx - 1;
        final runWidth = r1 - r0 + 1;
        var touchesPillar = false;
        for (var k = max(0, r0 - 1); k <= min(width - 1, r1 + 1); k++) {
          if (pillarPrev[k]) {
            touchesPillar = true;
            break;
          }
        }
        if (runWidth <= 7 && touchesPillar) {
          for (var k = r0; k <= r1; k++) {
            mask[gy * width + k] = 0;
            pillarCurr[k] = true;
          }
        }
        // Carry pillarPrev forward for any column that was a pillar and is
        // still near-black.
        for (var k = r0; k <= r1; k++) {
          if (pillarPrev[k] &&
              luma[gy * width + k] <= silhouetteNeighborhoodLuma) {
            pillarCurr[k] = true;
          }
        }
      }
      // Carry forward pillars that remain near-black even outside runs.
      for (var k = 0; k < width; k++) {
        if (pillarPrev[k] &&
            luma[gy * width + k] <= silhouetteNeighborhoodLuma &&
            mask[gy * width + k] == 0) {
          // keep pillar alive downward only if the cell is near-black
          pillarCurr[k] = true;
        }
      }
      for (var k = 0; k < width; k++) {
        pillarPrev[k] = pillarCurr[k];
      }
    }

    // Strip thin vertical structures (wall moldings, mic boom arms, 1-2 cell
    // wide stripes) BEFORE clustering: clear any mask cell whose horizontal
    // contiguous run on its row is shorter than 3 cells. A human head/torso
    // is >= 5 cells wide on the 80-wide grid; thin studio props are 1-2.
    for (var gy = y0; gy <= y1; gy++) {
      var runStart = -1;
      for (var gx = x0; gx <= x1 + 1; gx++) {
        final inRegion = gx <= x1;
        final isMask = inRegion && mask[gy * width + gx] == 1;
        if (isMask) {
          if (runStart < 0) runStart = gx;
        } else {
          if (runStart >= 0) {
            final runLen = gx - runStart;
            if (runLen < 3) {
              for (var k = runStart; k < gx; k++) {
                mask[gy * width + k] = 0;
              }
            }
            runStart = -1;
          }
        }
      }
    }

    // Mask out any grid cells that fall inside a detected real face's
    // bounding box, so dark hair/beards/hats on visible faces are never
    // mistaken for the anonymized silhouette.
    if (excludeRects != null) {
      for (final r in excludeRects) {
        final fx0 = (r.x0 * width).floor().clamp(0, width);
        final fx1 = (r.x1 * width).ceil().clamp(0, width);
        final fy0 = (r.y0 * height).floor().clamp(0, height);
        final fy1 = (r.y1 * height).ceil().clamp(0, height);
        for (var gy = fy0; gy < fy1; gy++) {
          for (var gx = fx0; gx < fx1; gx++) {
            if (gx >= x0 && gx <= x1 && gy >= y0 && gy <= y1) {
              mask[gy * width + gx] = 0;
            }
          }
        }
      }
    }

    // Largest 4-connected pitch-black cluster inside the search region.
    final visited = Uint8List(count);
    var bestCells = 0;
    var bestTop = 0;
    var bestBottom = 0;
    var bestLeft = 0;
    var bestRight = 0;
    var bestUpperSumX = 0.0;
    var bestUpperCells = 1;
    var bestUpperWeightTotal = 1.0;
    final stack = <int>[];

    for (var gy = y0; gy <= y1; gy++) {
      for (var gx = x0; gx <= x1; gx++) {
        final start = gy * width + gx;
        if (visited[start] != 0 || mask[start] == 0) continue;

        var cells = 0;
        var top = gy;
        var bottom = gy;
        var left = gx;
        var right = gx;
        final members = <int>[];
        stack
          ..clear()
          ..add(start);
        visited[start] = 1;

        while (stack.isNotEmpty) {
          final index = stack.removeLast();
          members.add(index);
          final cy = index ~/ width;
          final cx = index % width;
          cells++;
          if (cy < top) top = cy;
          if (cy > bottom) bottom = cy;
          if (cx < left) left = cx;
          if (cx > right) right = cx;

          const deltas = <(int, int)>[(-1, 0), (1, 0), (0, -1), (0, 1)];
          for (final (dx, dy) in deltas) {
            final nx = cx + dx;
            final ny = cy + dy;
            if (nx < x0 || nx > x1 || ny < y0 || ny > y1) continue;
            final neighbor = ny * width + nx;
            if (visited[neighbor] != 0 || mask[neighbor] == 0) continue;
            visited[neighbor] = 1;
            stack.add(neighbor);
          }
        }

        if (cells > bestCells) {
          bestCells = cells;
          bestTop = top;
          bestBottom = bottom;
          bestLeft = left;
          bestRight = right;
          // Horizontal centroid of the upper-head / neck band (top .. top +
          // 0.30*height): weight each cell by the square of its column's
          // vertical thickness so horizontal microphone arms protruding to
          // the side (thin columns) are ignored and normX locks onto the
          // thickest vertical head+torso column.
          final clusterHeight = bottom - top + 1;
          final bandHeight = max(1, (clusterHeight * 0.30).round());
          final bandBottom = top + bandHeight;
          // Column thickness of the whole cluster.
          final colCount = List<int>.filled(width, 0);
          for (final index in members) {
            colCount[index % width]++;
          }
          var weightedSumX = 0.0;
          var weightTotal = 0.0;
          var bandCells = 0;
          for (final index in members) {
            final cy = index ~/ width;
            if (cy >= top && cy < bandBottom) {
              final cx = index % width;
              final w = (colCount[cx] * colCount[cx]).toDouble();
              weightedSumX += cx * w;
              weightTotal += w;
              bandCells++;
            }
          }
          if (bandCells == 0 || weightTotal == 0) {
            // Fallback: unweighted centroid of the band.
            var s = 0.0;
            var n = 0;
            for (final index in members) {
              final cy = index ~/ width;
              if (cy >= top && cy < bandBottom) {
                s += index % width;
                n++;
              }
            }
            bestUpperSumX = n == 0 ? 0.0 : s;
            bestUpperCells = max(n, 1);
          } else {
            bestUpperSumX = weightedSumX;
            bestUpperWeightTotal = weightTotal;
            bestUpperCells = bandCells;
          }
          // Add field bestUpperWeightTotal.
        }
      }
    }

    // Human-torso credibility guards: reject props, decorations and wide
    // empty shots instead of locking the camera onto them.
    final clusterHeight = bestBottom - bestTop + 1;
    final clusterWidth = bestRight - bestLeft + 1;
    if (bestCells < count * silhouetteMinClusterFraction ||
        bestCells > count * silhouetteMaxClusterFraction ||
        bestBottom < height * silhouetteMinBottomFraction ||
        bestTop > height * silhouetteMaxTopFraction ||
        clusterHeight < height * silhouetteMinHeightFraction ||
        clusterWidth < width * silhouetteMinWidthFraction) {
      return null;
    }

    final normX = bestUpperWeightTotal > 0
        ? (bestUpperSumX / bestUpperWeightTotal + 0.5) / width
        : (bestUpperSumX / bestUpperCells + 0.5) / width;
    // Bias Y to the head / upper-torso of the cluster.
    final normY = (bestTop + clusterHeight * 0.26) / height;
    return (
      normX: normX.clamp(0.0, 1.0),
      normY: normY.clamp(0.0, 1.0),
      normW: (clusterWidth / width).clamp(0.04, 1.0),
      normH: (clusterHeight / height).clamp(0.04, 1.0),
      mass: bestCells.toDouble(),
      sceneChanged: sceneChanged,
    );
  }

  /// Mean-absolute-luma scene-change check between two analysis grids, usable
  /// by the caller even when [detectSilhouetteOrMotionSubject] found nothing
  /// (a cut to an empty wall must still reset the camera to center).
  static bool isSceneChange(
    Uint8List? prevRgbaBytes,
    Uint8List rgbaBytes,
    int width,
    int height,
  ) {
    final count = width * height;
    if (prevRgbaBytes == null ||
        prevRgbaBytes.length < count * 4 ||
        rgbaBytes.length < count * 4) {
      return false;
    }
    var diffSum = 0;
    for (var i = 0; i < count; i++) {
      final o = i * 4;
      final l =
          (77 * rgbaBytes[o] + 150 * rgbaBytes[o + 1] + 29 * rgbaBytes[o + 2]) >>
              8;
      final p =
          (77 * prevRgbaBytes[o] +
                  150 * prevRgbaBytes[o + 1] +
                  29 * prevRgbaBytes[o + 2]) >>
              8;
      diffSum += (l - p).abs();
    }
    return diffSum / count > silhouetteSceneChangeThreshold;
  }

  /// Associates a detected foreground subject with a recently-seen track by
  /// center distance. Never matches across a scene cut (a hard cut starts a
  /// fresh identity), and never matches stale tracks.
  static _SpeakerTrack? _associateSubject(
    Map<int, _SpeakerTrack> tracks, {
    required double nowSec,
    required double normX,
    required double normY,
    required bool allowExisting,
  }) {
    if (!allowExisting) return null;
    _SpeakerTrack? nearest;
    var bestDistance = associationDistance;
    for (final track in tracks.values) {
      if (!track.isSilhouette) continue; // silhouette must never hijack a real face track
      if (nowSec - track.lastSeenSec > 2.5) continue;
      final dx = track.normX - normX;
      final dy = track.normY - normY;
      final distance = sqrt(dx * dx + dy * dy);
      if (distance < bestDistance) {
        bestDistance = distance;
        nearest = track;
      }
    }
    return nearest;
  }

  /// True lip/speech activity: combines Mouth Aspect Ratio (MAR), pitch-invariant
  /// jaw drop, inner-mouth vs cheek contrast modulation, and rigid-motion-canceled
  /// mouth pixel delta on the landmark-stabilized face box.
  static void _updateLipActivity(
    _SpeakerTrack track,
    Face face,
    ui.Rect box, {
    required double imgWidth,
    required double imgHeight,
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    required double prevNx0,
    required double prevNy0,
    required double prevNx1,
    required double prevNy1,
    required bool hasPrev,
    Uint8List? currGrid,
    Uint8List? prevGrid,
    int gridW = silhouetteGridWidth,
    int gridH = silhouetteGridHeight,
    required double nowSec,
  }) {
    // Stabilize the face box using rigid skull landmarks (eyes + nose) and
    // smoothed box dimensions so ML Kit bounding-box padding jitter never
    // shifts the mouth sampling window onto a beard or collar.
    final fw = nx1 - nx0;
    final fh = ny1 - ny0;
    final stabW = hasPrev && track.normW > 0 ? 0.68 * track.normW + 0.32 * fw : fw;
    final stabH = hasPrev && track.normH > 0 ? 0.68 * track.normH + 0.32 * fh : fh;
    var centerX = (nx0 + nx1) * 0.5;
    var centerY = (ny0 + ny1) * 0.5;
    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    final nose = face.landmarks[FaceLandmarkType.noseBase]?.position;
    if (leftEye != null && rightEye != null && nose != null &&
        imgWidth > 0 && imgHeight > 0) {
      final eyeCx = (leftEye.x + rightEye.x) * 0.5 / imgWidth;
      final eyeCy = (leftEye.y + rightEye.y) * 0.5 / imgHeight;
      final noseX = nose.x / imgWidth;
      final noseY = nose.y / imgHeight;
      centerX = (0.45 * eyeCx + 0.55 * noseX).clamp(0.0, 1.0);
      centerY = (0.35 * eyeCy + 0.65 * noseY).clamp(0.0, 1.0);
    }
    final stabNx0 = (centerX - stabW * 0.5).clamp(0.0, 1.0);
    final stabNy0 = (centerY - stabH * 0.5).clamp(0.0, 1.0);
    final stabNx1 = (centerX + stabW * 0.5).clamp(0.0, 1.0);
    final stabNy1 = (centerY + stabH * 0.5).clamp(0.0, 1.0);

    final metrics = _lipMetrics(face, box);
    final open = metrics.$1;
    final width = metrics.$2;

    var geomDelta = 0.0;
    if (open != null) {
      final previous = track.lastOpen;
      if (hasPrev && previous != null) {
        final dOpen = max(0.0, (open - previous).abs() - 0.010);
        geomDelta += dOpen * 2.2;
      }
      track.lastOpen = open;
    }
    if (width != null) {
      final previous = track.lastWidth;
      if (hasPrev && previous != null) {
        final dWidth = max(0.0, (width - previous).abs() - 0.010);
        geomDelta += dWidth * 1.4;
      }
      track.lastWidth = width;
    }
    // Dampen landmark jitter when the whole head is moving/nodding rapidly.
    if (track.lastMoveDelta > 0.020) {
      geomDelta *= 0.25;
    }

    var pixelDelta = 0.0;
    if (currGrid != null && currGrid.length >= gridW * gridH * 4) {
      final currContrast = _mouthToCheekContrast(
        currGrid,
        gridW,
        gridH,
        nx0: stabNx0,
        ny0: stabNy0,
        nx1: stabNx1,
        ny1: stabNy1,
      );
      final prevContrast = track.lastMouthContrast;
      track.lastMouthContrast = currContrast;

      if (hasPrev && prevGrid != null) {
        final regionDelta = computeMouthRegionDelta(
          prevGrid,
          currGrid,
          gridW,
          gridH,
          nx0: stabNx0,
          ny0: stabNy0,
          nx1: stabNx1,
          ny1: stabNy1,
          prevNx0: prevNx0,
          prevNy0: prevNy0,
          prevNx1: prevNx1,
          prevNy1: prevNy1,
        );
        final contrastDelta = prevContrast != null
            ? max(0.0, (currContrast - prevContrast).abs() - 0.008)
            : 0.0;
        pixelDelta = regionDelta * 3.8 + contrastDelta * 2.2;
      }
    }

    track
      ..stabNx0 = stabNx0
      ..stabNy0 = stabNy0
      ..stabNx1 = stabNx1
      ..stabNy1 = stabNy1;

    final delta = geomDelta + pixelDelta;
    track.recordSpeechSample(delta, nowSec: nowSec, window: lipWindow);
  }

  /// Within-frame contrast between the upper cheeks/nose bridge and the inner
  /// mouth cavity (normalized to 0..1). Static beards have constant contrast
  /// across frames, whereas an opening/closing mouth modulates this value on
  /// every syllable.
  static double _mouthToCheekContrast(
    Uint8List grid,
    int gridW,
    int gridH, {
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
  }) {
    final fw = nx1 - nx0;
    final fh = ny1 - ny0;
    if (fw <= 0 || fh <= 0) return 0;

    var cheekSum = 0.0;
    var mouthSum = 0.0;
    const n = 4;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final u = (c + 0.5) / n;
        final v = (r + 0.5) / n;
        cheekSum += _sampleLumaBilinear(
          grid,
          gridW,
          gridH,
          nx0 + fw * (0.28 + 0.44 * u),
          ny0 + fh * (0.24 + 0.20 * v),
        );
        mouthSum += _sampleLumaBilinear(
          grid,
          gridW,
          gridH,
          nx0 + fw * (0.34 + 0.32 * u),
          ny0 + fh * (0.64 + 0.18 * v),
        );
      }
    }
    return ((cheekSum - mouthSum) / (n * n)) / 255.0;
  }

  /// Bilinear luma lookup on an RGBA grid so sub-cell face-box movements
  /// interpolate smoothly instead of snapping across 12-pixel grid boundaries.
  static double _sampleLumaBilinear(
    Uint8List grid,
    int gridW,
    int gridH,
    double normX,
    double normY,
  ) {
    final gx = (normX * gridW - 0.5).clamp(0.0, (gridW - 1).toDouble());
    final gy = (normY * gridH - 0.5).clamp(0.0, (gridH - 1).toDouble());
    final x0 = gx.floor();
    final y0 = gy.floor();
    final x1 = min(x0 + 1, gridW - 1);
    final y1 = min(y0 + 1, gridH - 1);
    final fx = gx - x0;
    final fy = gy - y0;

    int lumaAt(int x, int y) {
      final o = (y * gridW + x) * 4;
      return (77 * grid[o] + 150 * grid[o + 1] + 29 * grid[o + 2]) >> 8;
    }

    final l00 = lumaAt(x0, y0);
    final l10 = lumaAt(x1, y0);
    final l01 = lumaAt(x0, y1);
    final l11 = lumaAt(x1, y1);
    final top = l00 + (l10 - l00) * fx;
    final bottom = l01 + (l11 - l01) * fx;
    return top + (bottom - top) * fy;
  }

  /// Pure helper: mean absolute luma difference inside the face's
  /// lower-central mouth box (`x: [0.25..0.75]`, `y: [0.58..0.88]` of face
  /// width/height) MINUS the rigid upper-face motion (`y: [0.16..0.44]`),
  /// sampled with bilinear interpolation in BOTH the current and the previous
  /// frame's face box so head nodding, camera shake, and beard edges do not
  /// fake mouth motion. Returns the difference divided by 255.0.
  static double computeMouthRegionDelta(
    Uint8List? prevGrid,
    Uint8List? currGrid,
    int gridW,
    int gridH, {
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    required double prevNx0,
    required double prevNy0,
    required double prevNx1,
    required double prevNy1,
  }) {
    if (prevGrid == null || currGrid == null) return 0;
    if (prevGrid.length < gridW * gridH * 4 ||
        currGrid.length < gridW * gridH * 4) {
      return 0;
    }
    final fw = nx1 - nx0;
    final fh = ny1 - ny0;
    final pfw = prevNx1 - prevNx0;
    final pfh = prevNy1 - prevNy0;
    if (fw <= 0 || fh <= 0 || pfw <= 0 || pfh <= 0) return 0;

    final cx0 = nx0 + fw * 0.25;
    final cx1 = nx0 + fw * 0.75;
    final cy0 = ny0 + fh * 0.58;
    final cy1 = ny0 + fh * 0.88;
    final px0 = prevNx0 + pfw * 0.25;
    final px1 = prevNx0 + pfw * 0.75;
    final py0 = prevNy0 + pfh * 0.58;
    final py1 = prevNy0 + pfh * 0.88;

    const cols = 6;
    const rows = 4;
    var mouthSum = 0.0;
    var n = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final tx = cx0 + (cx1 - cx0) * (c + 0.5) / cols;
        final ty = cy0 + (cy1 - cy0) * (r + 0.5) / rows;
        final px = px0 + (px1 - px0) * (c + 0.5) / cols;
        final py = py0 + (py1 - py0) * (r + 0.5) / rows;
        final currLuma = _sampleLumaBilinear(currGrid, gridW, gridH, tx, ty);
        final prevLuma = _sampleLumaBilinear(prevGrid, gridW, gridH, px, py);
        mouthSum += (currLuma - prevLuma).abs();
        n++;
      }
    }
    if (n == 0) return 0.0;
    final mouthDiff = (mouthSum / n) / 255.0;

    // Rigid upper-face reference (forehead / eye bridge / upper cheeks):
    // moves during head nods, head turns, and camera shake, but stays still
    // during pure lip articulation.
    final ucy0 = ny0 + fh * 0.16;
    final ucy1 = ny0 + fh * 0.44;
    final upy0 = prevNy0 + pfh * 0.16;
    final upy1 = prevNy0 + pfh * 0.44;
    var upperSum = 0.0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final tx = cx0 + (cx1 - cx0) * (c + 0.5) / cols;
        final ty = ucy0 + (ucy1 - ucy0) * (r + 0.5) / rows;
        final px = px0 + (px1 - px0) * (c + 0.5) / cols;
        final py = upy0 + (upy1 - upy0) * (r + 0.5) / rows;
        final currLuma = _sampleLumaBilinear(currGrid, gridW, gridH, tx, ty);
        final prevLuma = _sampleLumaBilinear(prevGrid, gridW, gridH, px, py);
        upperSum += (currLuma - prevLuma).abs();
      }
    }
    final upperDiff = (upperSum / n) / 255.0;
    final netDiff = max(0.0, mouthDiff - 0.82 * upperDiff);
    return max(0.0, netDiff - 0.0065);
  }

  /// Relative lip gap / mouth width for one face, normalized by mouth width
  /// (MAR) and rigid eye-to-nose height so head nodding cannot out-score a
  /// moving mouth.
  static (double?, double?) _lipMetrics(Face face, ui.Rect box) {
    final height = box.height > 0 ? box.height : 1.0;
    final width = box.width > 0 ? box.width : 1.0;

    double? open;

    // Contour-based lip gap (when available).
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

    final left = face.landmarks[FaceLandmarkType.leftMouth]?.position;
    final right = face.landmarks[FaceLandmarkType.rightMouth]?.position;
    final bottom = face.landmarks[FaceLandmarkType.bottomMouth]?.position;
    final nose = face.landmarks[FaceLandmarkType.noseBase]?.position;
    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;

    double? mouthWidth;
    if (left != null && right != null) {
      mouthWidth = (right.x - left.x).abs() / width;
    }

    // Landmark-based Mouth Aspect Ratio (MAR) + pitch-compensated jaw drop.
    if (open == null) {
      if (bottom != null && left != null && right != null) {
        final cornersMidY = (left.y + right.y) * 0.5;
        final mwPx = max(width * 0.18, (right.x - left.x).abs());
        final mar = max(0.0, bottom.y - cornersMidY) / mwPx;
        if (nose != null && leftEye != null && rightEye != null) {
          final eyeMidY = (leftEye.y + rightEye.y) * 0.5;
          final rigidUpperH = max(height * 0.18, (nose.y - eyeMidY).abs());
          final jawRatio = (bottom.y - nose.y).abs() / rigidUpperH;
          open = mar * 0.45 + jawRatio * 0.25;
        } else {
          open = mar * 0.55;
        }
      } else if (bottom != null && nose != null) {
        open = (bottom.y - nose.y).abs() / height;
      }
    }

    return (open, mouthWidth);
  }

  /// Associates a detected face with an existing track by **box IoU**, then by
  /// normalized center distance. Tracks already claimed in the current frame
  /// (`track.lastSeenSec == nowSec`) are skipped so two faces in one frame can
  /// never collide on the same track.
  static _SpeakerTrack? _associateFace(
    Map<int, _SpeakerTrack> tracks, {
    required double nowSec,
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    required double cx,
    required double cy,
    required bool allowExisting,
  }) {
    if (!allowExisting) return null;

    _SpeakerTrack? best;
    var bestIou = minFaceOverlap;
    for (final track in tracks.values) {
      if (track.isSilhouette) continue;
      if (track.lastSeenSec == nowSec) continue; // already matched in this frame
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
      if (track.isSilhouette) continue;
      if (track.lastSeenSec == nowSec) continue; // already matched in this frame
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

  /// Picks the active speaker with sustained-speech hysteresis:
  ///  - if the currently selected person has never spoken in this scene (e.g.
  ///    frame 0 after a scene cut picked a silent bystander), switch in 0ms as
  ///    soon as any candidate starts speaking;
  ///  - once a speaker is actively talking, hold the camera on them across
  ///    natural ~1.1s breath pauses between words;
  ///  - switch to a new speaker when the candidate has confirmed speech across
  ///    multiple samples (`speakingFrames >= 2`) and either the current
  ///    speaker has paused for >= 1.0s or the lock has elapsed with a clear
  ///    speech lead.
  static _SpeakerTrack? _selectSpeaker(
    List<_SpeakerTrack> present,
    _SpeakerTrack? current, {
    required double nowSec,
  }) {
    if (present.isEmpty) return null;

    if (current != null && present.contains(current)) {
      current.lockStartSec ??= nowSec;
      final lockedFor = nowSec - (current.lockStartSec ?? nowSec);
      final sinceCurrentSpoke = nowSec - current.lastSpokeSec;

      var best = current;
      for (final candidate in present) {
        if (candidate.score > best.score) best = candidate;
      }
      if (!identical(best, current)) {
        final bestConfirmed = (!best.isSilhouette &&
                best.speakingFrames >= 2 &&
                best.recentActivity >= 0.016) ||
            (best.isSilhouette && best.silhouetteActivity >= 0.045);

        // Fast initial lock acquisition: if the initial track picked at the
        // start of a scene has not spoken at all, snap immediately to the
        // first person who starts talking.
        final currentNeverSpoke = !current.isSilhouette &&
            current.lastSpokeSec < 0 &&
            current.speakingFrames == 0;
        final bestStartedSpeaking = (!best.isSilhouette &&
                best.speakingFrames >= 1 &&
                best.recentActivity >= 0.015) ||
            (best.isSilhouette && best.silhouetteActivity >= 0.045);
        if (currentNeverSpoke && bestStartedSpeaking) {
          best.lockStartSec = nowSec;
          return best;
        }

        // Turn-taking switch once the candidate has sustained speech.
        final currentPaused = sinceCurrentSpoke >= 1.0 || current.silentFrames >= 4;
        if (bestConfirmed &&
            ((currentPaused && best.score > current.score * 1.15 + 0.008) ||
                (lockedFor >= speakerLockSeconds &&
                    best.score > current.score * 1.40 + 0.014))) {
          best.lockStartSec = nowSec;
          return best;
        }
      }
      return current;
    }

    _SpeakerTrack? best;
    for (final candidate in present) {
      if (best == null || candidate.score > best.score) best = candidate;
    }
    best?.lockStartSec = nowSec;
    return best;
  }

  /// Groups tracks into people (a person re-detected after a cut may own more
  /// than one track) and labels them left-to-right.
  /// At most this many people are exposed to the speaker-chip UI; beyond that
  /// the extra "profiles" were fragments, not people.
  static const int maxProfiles = 4;

  /// Horizontal distance (normalized) under which two face tracks count as
  /// the same person.
  static const double profileMergeDistance = 0.18;

  /// Builds the real people of the video:
  ///  - a track must be seen often enough (>= max(3, frames/30) hits) —
  ///    single-frame flickers are noise, not people;
  ///  - face tracks are merged into one person when their average X is within
  ///    [profileMergeDistance] and they are the same kind (face vs
  ///    silhouette), which absorbs the fragmented tracks ML Kit produces when
  ///    a person briefly leaves the frame;
  ///  - only the top [maxProfiles] people by presence are returned.
  static List<DetectedSpeakerProfile> _buildProfiles(
    Map<int, _SpeakerTrack> tracks, {
    required int frameCount,
  }) {
    final minHits = max(3, frameCount ~/ 30);
    final used = tracks.values
        .where((t) => t.points.length >= 2 && t.hits >= minHits)
        .toList();
    if (used.isEmpty) return const [];

    double avgXOf(List<_SpeakerTrack> group) {
      var total = 0.0;
      var count = 0;
      for (final track in group) {
        for (final point in track.points) {
          total += point.normX;
          count++;
        }
      }
      return count == 0 ? 0.5 : total / count;
    }

    int hitsOf(List<_SpeakerTrack> group) =>
        group.fold(0, (sum, track) => sum + track.hits);

    final groups = <List<_SpeakerTrack>>[];
    for (final track in used) {
      final trackX = avgXOf([track]);
      List<_SpeakerTrack>? target;
      for (final group in groups) {
        if (group.first.isSilhouette == track.isSilhouette &&
            (trackX - avgXOf(group)).abs() < profileMergeDistance) {
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

    // Keep the most-present people only, then order left-to-right so the
    // labels stay stable.
    groups.sort((a, b) => hitsOf(b).compareTo(hitsOf(a)));
    final kept = groups.take(maxProfiles).toList()
      ..sort((a, b) => avgXOf(a).compareTo(avgXOf(b)));

    final profiles = <DetectedSpeakerProfile>[];
    final usedLabels = <String>{};
    for (var i = 0; i < kept.length; i++) {
      final points = <FaceTrackPoint>[];
      for (final track in kept[i]) {
        points.addAll(track.points);
      }
      points.sort((a, b) => a.timeSec.compareTo(b.timeSec));

      var xTotal = 0.0;
      var yTotal = 0.0;
      for (final point in points) {
        xTotal += point.normX;
        yTotal += point.normY;
      }

      String label = kept[i].any((t) => t.isSilhouette)
          ? 'Silhouette / Subject'
          : _speakerLabel(i, kept.length);
      if (usedLabels.contains(label) && label.startsWith('Silhouette')) {
        var suffix = 2;
        while (usedLabels.contains('$label $suffix')) {
          suffix++;
        }
        label = '$label $suffix';
      }
      usedLabels.add(label);

      profiles.add(
        DetectedSpeakerProfile(
          id: i,
          label: label,
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

  /// Shot-aware keyframes: splits the raw trajectory into continuous
  /// single-speaker/shot segments and smooths each one **independently**.
  ///
  /// A steady shot (every sample within [shotSteadyTolerance] of its median —
  /// the interview/podcast default) collapses to ONE clean keyframe at the
  /// shot start with `isCut: true`, so a typical video yields 6-12 exact
  /// shot-change markers instead of dozens of noisy RDP points. A shot where
  /// the speaker genuinely travels (>~0.14 across the frame) keeps smooth
  /// intermediate keyframes (`isCut: false`; only the shot entry is a cut).
  /// Cuts are expressed by `isCut` flags — the explicit 1ms FFmpeg step pairs
  /// are materialized later by [materializeKeyframesForFfmpeg].
  static List<FaceTrackPoint> buildKeyframes(
    List<FaceTrackPoint> rawPoints, {
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    int maxKeyframes = FaceDetectionService.maxKeyframes,
  }) {
    if (rawPoints.isEmpty) return const [];

    var ranges = _splitSegments(rawPoints, speakerJumpThreshold);
    // Never relax speakerJumpThreshold: adjacent speakers (0.14..0.17 apart)
    // must ALWAYS be split into separate segments and rendered as instant
    // 1ms jump cuts. Relaxing merges different people into one segment and
    // produces multi-second crawling pans across the frame.

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
      if (segment.isEmpty) continue;

      // Steady shot: collapse the whole segment into ONE clean keyframe.
      final median = _medianOf(segment);
      var maxDevX = 0.0;
      var maxDevY = 0.0;
      for (final point in segment) {
        final dx = (point.normX - median.$1).abs();
        final dy = (point.normY - median.$2).abs();
        if (dx > maxDevX) maxDevX = dx;
        if (dy > maxDevY) maxDevY = dy;
      }
      if (maxDevX <= shotSteadyTolerance && maxDevY <= shotSteadyTolerance) {
        out.add(
          FaceTrackPoint(
            timeSec: rawPoints[start].timeSec,
            normX: median.$1,
            normY: median.$2,
            isCut: true,
          ),
        );
        continue;
      }

      // Genuine travel across one shot: keep smooth intermediate keyframes
      // (`isCut: false` so the camera pans with the speaker), while the
      // segment ENTRY is an instant cut.
      final budget = max(3, (available * (end - start)) ~/ total);
      final simplified = _simplifySegment(segment, budget);
      if (simplified.isNotEmpty) {
        simplified[0] = simplified.first.copyWith(isCut: true);
        for (var k = 1; k < simplified.length; k++) {
          simplified[k] = simplified[k].copyWith(isCut: false);
        }
      }
      out.addAll(simplified);
    }

    return List<FaceTrackPoint>.unmodifiable(
      _enforceBudget(out, maxKeyframes),
    );
  }

  /// Per-axis medians of a segment — robust against the occasional outlier
  /// sample a mean would follow.
  static (double, double) _medianOf(List<FaceTrackPoint> points) {
    final xs = points.map((p) => p.normX).toList()..sort();
    final ys = points.map((p) => p.normY).toList()..sort();
    final mid = xs.length ~/ 2;
    final medX = xs.length.isOdd ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2;
    final medY = ys.length.isOdd ? ys[mid] : (ys[mid - 1] + ys[mid]) / 2;
    return (medX, medY);
  }

  // ---------------------------------------------------------------------------
  // Cut semantics + manual keyframe editing
  // ---------------------------------------------------------------------------

  /// Default tolerance (seconds) for "the keyframe at the playhead" updates:
  /// tight enough that two distinct keyframes a beat apart stay distinct
  /// (CapCut-style single-button add/remove relies on this).
  static const double manualKeyframeToleranceSec = 0.25;

  /// Whether the transition `a -> b` is an instant jump cut.
  ///
  /// 1. an explicit `b.isCut` always wins;
  /// 2. a **manual** keyframe with `isCut == false` is a deliberate smooth
  ///    camera pan, so heuristics never re-cut it;
  /// 3. otherwise only a sub-50ms step or a cross-screen jump (`>= 0.35`)
  ///    without explicit flags is treated as a cut — preserving smooth camera
  ///    tracking within a speaker's shot.
  static bool isEffectiveCut(FaceTrackPoint a, FaceTrackPoint b) {
    if (b.isCut) return true;
    if (b.isManual) return false;
    if (b.timeSec - a.timeSec <= 0.05) return true;
    return (b.normX - a.normX).abs() >= 0.35;
  }

  /// Expands every effective cut into an explicit **1ms step pair**:
  /// `(t: b.timeSec - 0.001, position of a)` followed by `b`, so FFmpeg's
  /// balanced time tree renders an exact 1ms instant snap, while `isCut == false`
  /// keyframes stay a smooth linear pan.
  ///
  /// Idempotent: re-materializing an already expanded list adds nothing.
  static List<FaceTrackPoint> materializeKeyframesForFfmpeg(
    List<FaceTrackPoint> keyframes,
  ) {
    if (keyframes.length < 2) return List<FaceTrackPoint>.of(keyframes);

    final out = <FaceTrackPoint>[keyframes.first];
    for (var i = 1; i < keyframes.length; i++) {
      final previous = out.last;
      final point = keyframes[i];
      if (isEffectiveCut(previous, point)) {
        final stepTime = point.timeSec - 0.001;
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
      out.add(point);
    }
    return List<FaceTrackPoint>.unmodifiable(out);
  }

  /// Prepares raw AI keyframes for the interactive editor:
  ///  - folds synthetic `t-0.001` step helpers into single logical keyframes
  ///    carrying `isCut: true` (the user sees clean, editable keyframes);
  ///  - preserves smooth intra-shot camera-follow keyframes (`isCut: false`),
  ///    flagging only unflagged cross-screen jumps (`>= 0.35`) as cuts.
  static List<FaceTrackPoint> normalizeKeyframesForEditing(
    List<FaceTrackPoint> keyframes,
  ) {
    if (keyframes.isEmpty) return const [];

    final cleaned = <FaceTrackPoint>[];
    for (final point in keyframes) {
      if (cleaned.isNotEmpty &&
          point.timeSec - cleaned.last.timeSec <= 0.002) {
        // Synthetic 1ms step helper: keep ONE logical keyframe with the new
        // segment's position and a cut transition from the previous one.
        cleaned[cleaned.length - 1] = FaceTrackPoint(
          timeSec: point.timeSec,
          normX: point.normX,
          normY: point.normY,
          isCut: true,
          isManual: point.isManual,
        );
        continue;
      }
      cleaned.add(point);
    }

    final out = <FaceTrackPoint>[];
    for (var i = 0; i < cleaned.length; i++) {
      var point = cleaned[i];
      if (i > 0) {
        final previous = out.last;
        final jump = (point.normX - previous.normX).abs() >= 0.35 ||
            (point.normY - previous.normY).abs() >= 0.35;
        if (jump && !point.isCut && !point.isManual) {
          point = point.copyWith(isCut: true);
        }
      }
      out.add(point);
    }
    return List<FaceTrackPoint>.unmodifiable(out);
  }

  /// Adds a manual keyframe at [timeSec], or updates the nearest existing one
  /// within [tolerance] seconds in place (position + `isManual: true`, time
  /// unchanged).
  ///
  /// When [clearNearbyAiKeyframes] is `true` (interactive camera dragging in
  /// the editor), any non-manual AI keyframes within ±0.75s or trailing smooth
  /// AI points in the same shot are absorbed so old AI points never snap the
  /// camera back after the user's manual camera adjustment.
  static List<FaceTrackPoint> upsertManualKeyframe(
    List<FaceTrackPoint> keyframes, {
    required double timeSec,
    required double normX,
    required double normY,
    double tolerance = manualKeyframeToleranceSec,
    bool isCut = true,
    bool clearNearbyAiKeyframes = false,
  }) {
    var working = List<FaceTrackPoint>.of(keyframes);

    var bestIndex = -1;
    var bestDelta = double.infinity;
    final effectiveTolerance =
        clearNearbyAiKeyframes ? max(tolerance, 0.45) : tolerance;
    for (var i = 0; i < working.length; i++) {
      final delta = (working[i].timeSec - timeSec).abs();
      if (delta <= effectiveTolerance && delta < bestDelta) {
        bestDelta = delta;
        bestIndex = i;
      }
    }

    if (bestIndex >= 0) {
      final existing = working[bestIndex];
      // Keep shot-start cut if editing the very first keyframe of the clip;
      // otherwise use the caller's smooth/cut preference when clearing AI KFs.
      final resolvedCut = clearNearbyAiKeyframes
          ? (bestIndex == 0 ? true : isCut)
          : existing.isCut;
      working[bestIndex] = existing.copyWith(
        normX: normX,
        normY: normY,
        isCut: resolvedCut,
        isManual: true,
      );
      if (clearNearbyAiKeyframes) {
        working = _pruneConflictingAiKeyframes(working, bestIndex);
      }
      return working;
    }

    final point = FaceTrackPoint(
      timeSec: timeSec,
      normX: normX,
      normY: normY,
      isCut: isCut,
      isManual: true,
    );
    var insertAt = working.length;
    for (var i = 0; i < working.length; i++) {
      if (working[i].timeSec > timeSec) {
        insertAt = i;
        break;
      }
    }
    working.insert(insertAt, point);
    if (clearNearbyAiKeyframes) {
      working = _pruneConflictingAiKeyframes(working, insertAt);
    }
    return working;
  }

  /// Removes non-manual AI keyframes that sit right next to [manualIndex]
  /// (within 0.75s) or trailing intra-shot AI points (`!isCut && !isManual`)
  /// immediately following [manualIndex], so the camera smoothly follows the
  /// user's manual trajectory without snapping back to old AI drift points.
  static List<FaceTrackPoint> _pruneConflictingAiKeyframes(
    List<FaceTrackPoint> keyframes,
    int manualIndex,
  ) {
    if (keyframes.length <= 1 ||
        manualIndex < 0 ||
        manualIndex >= keyframes.length) {
      return keyframes;
    }
    final targetTime = keyframes[manualIndex].timeSec;
    final out = <FaceTrackPoint>[];
    var passedManual = false;
    var hitNextShotOrManual = false;

    for (var i = 0; i < keyframes.length; i++) {
      if (i == manualIndex) {
        out.add(keyframes[i]);
        passedManual = true;
        continue;
      }
      final kf = keyframes[i];
      if (!kf.isManual && i > 0 && (kf.timeSec - targetTime).abs() <= 0.75) {
        continue;
      }
      if (passedManual && !hitNextShotOrManual) {
        if (kf.isManual || kf.isCut) {
          hitNextShotOrManual = true;
        } else {
          // Trailing non-manual intra-shot AI point: drop it so it doesn't
          // pull the camera away from the user's manual position.
          continue;
        }
      }
      out.add(kf);
    }
    return out.isEmpty ? [keyframes[manualIndex]] : out;
  }

  /// Deletes the keyframe at [index]. Keeps at least one keyframe so the
  /// camera always has somewhere to be.
  static List<FaceTrackPoint> deleteKeyframe(
    List<FaceTrackPoint> keyframes,
    int index,
  ) {
    if (index < 0 ||
        index >= keyframes.length ||
        keyframes.length <= 1) {
      return List<FaceTrackPoint>.of(keyframes);
    }
    final out = List<FaceTrackPoint>.of(keyframes);
    out.removeAt(index);
    return out;
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
        segment[0] = segment.first.copyWith(isCut: true);
      }
      out.addAll(segment);
    }
    return out;
  }

  /// Splits the timeline wherever an explicit speaker/scene cut occurred
  /// (`rawPoints[i].isCut`), wherever the raw center jumps by >= [threshold]
  /// in X or Y, or wherever there is a time gap > 1.5s.
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
      if (rawPoints[i].isCut || dx >= threshold || dy >= threshold || gap > 1.5) {
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
      if (points[i].isCut ||
          points[i].timeSec - points[i - 1].timeSec <= 0.0011) {
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
