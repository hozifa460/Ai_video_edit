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

/// Normalized 2D camera target at a point in time (`0.0 .. 1.0` in both axes).
class FaceTrackPoint {
  final double timeSec;
  final double normX;
  final double normY;

  /// `true` when the transition **into** this keyframe is an instant jump cut
  /// (at a hard scene cut or when explicitly toggled by the user).
  /// `false` (the default) produces a smooth camera pan from the previous
  /// keyframe into this one.
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

/// One detected person across the clip.
///
/// Selecting a profile pins the camera on that human (either for the whole
/// video or for a specific shot/scene).
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

/// Contiguous shot / scene interval `[startSec .. endSec]` in the video.
///
/// Automatically populated from detected scene cuts and speaker turns, and
/// can also be split or merged interactively by the user at the playhead.
class SceneShot {
  final int id;
  final double startSec;
  final double endSec;

  const SceneShot({
    required this.id,
    required this.startSec,
    required this.endSec,
  });

  double get durationSec => max(0.0, endSec - startSec);

  bool contains(double timeSec) =>
      timeSec >= startSec - 1e-3 && timeSec <= endSec + 1e-3;

  SceneShot copyWith({
    int? id,
    double? startSec,
    double? endSec,
  }) {
    return SceneShot(
      id: id ?? this.id,
      startSec: startSec ?? this.startSec,
      endSec: endSec ?? this.endSec,
    );
  }
}

/// Camera behavior chosen by the user for a specific [SceneShot].
enum ShotLockMode {
  /// Automatically follow whoever is actively speaking in this shot.
  autoSpeaker,

  /// Lock onto one specific detected person (`speakerId`) throughout this shot.
  specificPerson,

  /// Hold a fixed camera position (`staticNormX`, `staticNormY`) for this shot.
  staticPosition,
}

/// Per-shot tracking configuration applied to one [SceneShot].
class ShotTrackingOverride {
  final ShotLockMode mode;
  final int? speakerId;
  final double? staticNormX;
  final double? staticNormY;

  const ShotTrackingOverride({
    this.mode = ShotLockMode.autoSpeaker,
    this.speakerId,
    this.staticNormX,
    this.staticNormY,
  });

  ShotTrackingOverride copyWith({
    ShotLockMode? mode,
    int? speakerId,
    double? staticNormX,
    double? staticNormY,
  }) {
    return ShotTrackingOverride(
      mode: mode ?? this.mode,
      speakerId: speakerId ?? this.speakerId,
      staticNormX: staticNormX ?? this.staticNormX,
      staticNormY: staticNormY ?? this.staticNormY,
    );
  }
}

/// Result of one face-analysis pass: the active-speaker trajectory, detected
/// shots/scenes, and every individual person profile.
class FaceTrackResult {
  /// Active-speaker position for every sampled analysis frame.
  final List<FaceTrackPoint> rawPoints;

  /// Camera trajectory (<= [FaceDetectionService.maxKeyframes] points).
  final List<FaceTrackPoint> keyframes;

  final double avgNormX;
  final double avgNormY;
  final int facesDetectedCount;

  /// Every distinct person found, sorted left-to-right.
  final List<DetectedSpeakerProfile> speakers;

  /// Detected shots/scenes in chronological order.
  final List<SceneShot> shots;

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
    this.shots = const [],
    this.sourceWidth = 0,
    this.sourceHeight = 0,
  });

  /// Interpolated camera position at [timeSec], for the live preview overlay.
  ///
  /// Smooth keyframes (`isCut: false`) interpolate like a fluid camera;
  /// `isCut: true` keyframes hold the previous position until `b.timeSec`
  /// and snap at the cut boundary.
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

  /// Landmark-stabilized face box.
  double stabNx0 = 0.4;
  double stabNy0 = 0.25;
  double stabNx1 = 0.6;
  double stabNy1 = 0.55;

  /// Previous relative lip geometry.
  double? lastOpen;
  double? lastWidth;

  /// Previous inner-mouth vs upper-cheek luma contrast.
  double? lastMouthContrast;

  /// Per-frame center displacement of this track.
  double lastMoveDelta = 0;

  /// Foreground area ratio relative to the largest face in the frame (`0..1`).
  double foregroundRatio = 1.0;

  /// Activity score for a silhouette (anonymized) track.
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
      if (d >= 0.013) count++;
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
    if (delta >= 0.013) {
      silentFrames = 0;
      lastSpokeSec = nowSec;
    } else {
      silentFrames++;
    }
  }

  /// Active-speaker score combining sustained non-rigid mouth articulation
  /// with foreground subject prominence so background crowd faces never steal
  /// the camera from the foreground speaker.
  double get score {
    if (isSilhouette) {
      return silhouetteActivity * 10.0 + areaNorm * 0.04;
    }
    final activeCount = speakingFrames;
    final speechMult = activeCount >= 2 ? 18.0 : (activeCount == 1 ? 9.0 : 3.0);
    final prominenceBonus =
        areaNorm * 0.45 + foregroundRatio.clamp(0.0, 1.0) * 0.04;
    var s = recentActivity * speechMult +
        (activeCount >= 2 ? 0.06 * activeCount : 0.0) +
        prominenceBonus +
        0.015 * (min(hits, 8) / 8);
    // Only penalize someone walking/running rapidly across the frame (>12% per
    // 0.25s sample) with no sustained speech. Expressive head movement while
    // speaking is NEVER penalized.
    if (lastMoveDelta > 0.12 && activeCount < 2) {
      s *= 0.25;
    }
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

/// Real ML Kit + FFmpeg active-speaker & virtual-camera tracking service.
class FaceDetectionService {
  FaceDetectionService._();

  static const double defaultDeadZone = 0.015;
  static const double defaultSmoothness = 0.32;

  /// FFmpeg-safe keyframe cap.
  static const int maxKeyframes = 96;

  /// Normalized horizontal/vertical shift that separates distinct speaker
  /// positions.
  static const double speakerJumpThreshold = 0.135;

  /// Association tolerances (normalized frame units).
  static const double associationDistance = 0.16;
  static const double minFaceOverlap = 0.10;

  /// Minimum time the camera stays on one speaker before a turn-taking switch.
  static const double speakerLockSeconds = 1.25;

  /// Frames kept in the rolling lip-delta window (~1.5s at 4fps).
  static const int lipWindow = 6;

  /// High-resolution grid used for mouth/upper-face luma analysis (4x4 source
  /// pixels per cell on 960x540 frames).
  static const int mouthGridWidth = 240;
  static const int mouthGridHeight = 135;

  /// Minimum ratio of a face's area to the largest face in the frame (`0.28`)
  /// required to be considered a foreground speaker candidate. Smaller faces
  /// in the background crowd are ignored so they never pull the camera away.
  static const double minForegroundAreaRatio = 0.28;

  // ---------------------------------------------------------------------------
  // Analysis
  // ---------------------------------------------------------------------------

  /// Analyzes [videoPath] and returns the stabilized 2D speaker trajectory,
  /// detected shots/scenes, and every detected person profile, or `null` when
  /// no face was found at all.
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
        enableContours: false,
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

      final firstImage = await _decodeImage(File(frames.first.path));
      final imgWidth = firstImage.width.toDouble();
      final imgHeight = firstImage.height.toDouble();
      firstImage.dispose();
      if (imgWidth <= 0 || imgHeight <= 0) return null;

      final tracks = <int, _SpeakerTrack>{};
      final activePoints = <FaceTrackPoint>[];
      final shotStarts = <double>[startSec];
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

      // Minimum face size in pixels (filters tiny distant crowd faces).
      final minFaceHeight = imgHeight * 0.065;
      final minFaceWidth = imgWidth * 0.04;

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

        // Sort larger foreground faces first.
        final sortedFaces = List<Face>.of(faces)
          ..sort(
            (a, b) => (b.boundingBox.width * b.boundingBox.height)
                .compareTo(a.boundingBox.width * a.boundingBox.height),
          );

        // Compute the largest foreground face area in this frame.
        var maxFaceArea = 0.0;
        for (final face in sortedFaces) {
          final box = face.boundingBox;
          if (box.height < minFaceHeight || box.width < minFaceWidth) continue;
          final area = (box.width / imgWidth) * (box.height / imgHeight);
          if (area > maxFaceArea) maxFaceArea = area;
        }

        var cut = false;
        if (grid != null) {
          final rawCut = isSceneChange(
            prevGridBytes,
            grid,
            silhouetteGridWidth,
            silhouetteGridHeight,
          );
          if (rawCut) {
            // Guard against handheld camera shake: if the main foreground
            // speaker's face box still strongly overlaps (>0.30 IoU) their
            // position from the previous frame, the camera merely panned or
            // shook in a crowd — do not wipe out the speaker track!
            var foregroundFaceContinuous = false;
            if (currentSpeaker != null &&
                !currentSpeaker.isSilhouette &&
                (timeSec - currentSpeaker.lastSeenSec) <= 0.6 &&
                sortedFaces.isNotEmpty) {
              final topBox = sortedFaces.first.boundingBox;
              final nx0 = (topBox.left / imgWidth).clamp(0.0, 1.0);
              final ny0 = (topBox.top / imgHeight).clamp(0.0, 1.0);
              final nx1 = (topBox.right / imgWidth).clamp(0.0, 1.0);
              final ny1 = (topBox.bottom / imgHeight).clamp(0.0, 1.0);
              final iou = _boxOverlap(currentSpeaker, nx0, ny0, nx1, ny1);
              if (iou >= 0.32) {
                foregroundFaceContinuous = true;
              }
            }
            cut = !foregroundFaceContinuous;
          }
          if (cut) {
            currentSpeaker = null;
            sceneStartPointIdx = activePoints.length;
            sceneSpeakerConfirmed = false;
            if (timeSec - shotStarts.last >= 0.75) {
              shotStarts.add(timeSec);
            }
          }
        }

        final present = <_SpeakerTrack>[];
        final faceBoxes = <({double x0, double y0, double x1, double y1})>[];

        for (final face in sortedFaces) {
          final box = face.boundingBox;
          if (box.height < minFaceHeight || box.width < minFaceWidth) {
            continue;
          }

          final nx0 = (box.left / imgWidth).clamp(0.0, 1.0);
          final ny0 = (box.top / imgHeight).clamp(0.0, 1.0);
          final nx1 = (box.right / imgWidth).clamp(0.0, 1.0);
          final ny1 = (box.bottom / imgHeight).clamp(0.0, 1.0);
          final fw = nx1 - nx0;
          final fh = ny1 - ny0;
          final area = fw * fh;

          // Filter out smaller background crowd faces (< 28% of the primary
          // foreground face area) so people standing behind the speaker in a
          // street interview never steal the camera.
          if (maxFaceArea > 0 && area < maxFaceArea * minForegroundAreaRatio) {
            continue;
          }

          facesDetectedCount++;
          lastFaceSeenSec = timeSec;

          final cx = ((nx0 + nx1) / 2).clamp(0.0, 1.0);
          final cy = ((ny0 + ny1) / 2).clamp(0.0, 1.0);
          final fcx = (nx0 + nx1) / 2;
          final fgRatio = maxFaceArea > 0
              ? (area / maxFaceArea).clamp(0.0, 1.0)
              : 1.0;

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
              ..stabNy1 = ny1
              ..foregroundRatio = fgRatio;
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
            _updateTrack(created, timeSec, cx, cy, fw, fh);
            created.points.add(
              FaceTrackPoint(timeSec: timeSec, normX: cx, normY: cy),
            );
            continue;
          }

          final moveDelta = sqrt(
            (cx - track.normX) * (cx - track.normX) +
                (cy - track.normY) * (cy - track.normY),
          );
          track.lastMoveDelta = moveDelta;
          track.isSilhouette = false;
          track.foregroundRatio = 0.6 * track.foregroundRatio + 0.4 * fgRatio;

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
          _updateTrack(track, timeSec, cx, cy, fw, fh);
          track.points.add(
            FaceTrackPoint(timeSec: timeSec, normX: cx, normY: cy),
          );
          present.add(track);
        }

        // Only run the pitch-black silhouette fallback when NO real face is
        // visible in the frame (e.g. a solo shot of an anonymized studio
        // guest). When real human faces are visible, black hijabs/abayas/suits
        // in the crowd must never be mistaken for a silhouette speaker.
        SilhouetteSubject? subject;
        if (grid != null && present.isEmpty) {
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
          lastFaceSeenSec = timeSec;
          var subjectTrack = _associateSilhouette(
            tracks,
            nowSec: timeSec,
            cx: subject.normX,
            cy: subject.normY,
            allowExisting: !cut,
          );
          if (subjectTrack == null) {
            subjectTrack = _SpeakerTrack(tracks.length)..isSilhouette = true;
            tracks[subjectTrack.id] = subjectTrack;
          }
          var activity = prevGridBytes != null && !cut
              ? _silhouetteMotionActivity(
                  prevGridBytes,
                  grid!,
                  silhouetteGridWidth,
                  silhouetteGridHeight,
                  subject.normX,
                  subject.normY,
                  subject.normW,
                  subject.normH,
                )
              : 0.0;
          activity = max(activity, 0.05);
          subjectTrack.silhouetteActivity = prevGridBytes != null && !cut
              ? subjectTrack.silhouetteActivity * 0.35 + activity * 0.65
              : activity;
          subjectTrack.lastSpokeSec = timeSec;
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

        currentSpeaker = _selectSpeaker(
          present,
          currentSpeaker,
          nowSec: timeSec,
        );

        if (currentSpeaker != null && present.contains(currentSpeaker)) {
          lastX = currentSpeaker.normX;
          lastY = currentSpeaker.normY;

          // Scene-Start Backfill: once the speaker in a shot is confirmed
          // within 2.5s of the shot start, backfill the initial frames of that
          // shot so the camera starts directly on the active speaker.
          final confirmedNow = (!currentSpeaker.isSilhouette &&
                  currentSpeaker.speakingFrames >= 1 &&
                  currentSpeaker.recentActivity >= 0.014) ||
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
                  isCut: activePoints[k].isCut,
                );
              }
            }
          }
        }

        // Only mark `isCut: true` on an actual scene cut (`cut`), so intra-shot
        // speaker switches and movements pan smoothly like a real camera.
        activePoints.add(
          FaceTrackPoint(
            timeSec: timeSec,
            normX: lastX,
            normY: lastY,
            isCut: cut && activePoints.isNotEmpty,
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
      final clipEndSec = startSec + clipDuration;
      final shots = _buildShotsFromBoundaries(
        shotStarts,
        startSec: startSec,
        endSec: max(clipEndSec, activePoints.last.timeSec),
      );
      final avgX =
          activePoints.map((p) => p.normX).reduce((a, b) => a + b) /
          activePoints.length;
      final avgY =
          activePoints.map((p) => p.normY).reduce((a, b) => a + b) /
          activePoints.length;

      onProgress?.call(1.0, 'Speaker track ready');
      AppLogger().i(
        'FaceTrack: ${frames.length} frames, ${profiles.length} people, '
        '${shots.length} shots, $facesDetectedCount faces, '
        '${keyframes.length} keyframes',
      );
      return FaceTrackResult(
        rawPoints: activePoints,
        keyframes: keyframes,
        avgNormX: avgX,
        avgNormY: avgY,
        facesDetectedCount: facesDetectedCount,
        speakers: profiles,
        shots: shots,
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

  static List<SceneShot> _buildShotsFromBoundaries(
    List<double> shotStarts, {
    required double startSec,
    required double endSec,
  }) {
    final sorted = shotStarts.toSet().toList()..sort();
    if (sorted.isEmpty || sorted.first > startSec + 0.05) {
      sorted.insert(0, startSec);
    }
    final shots = <SceneShot>[];
    for (var i = 0; i < sorted.length; i++) {
      final s = sorted[i];
      final e = (i + 1 < sorted.length) ? sorted[i + 1] : max(s + 0.1, endSec);
      if (e - s >= 0.05) {
        shots.add(SceneShot(id: shots.length, startSec: s, endSec: e));
      }
    }
    if (shots.isEmpty) {
      shots.add(SceneShot(id: 0, startSec: startSec, endSec: max(startSec + 0.1, endSec)));
    }
    return List<SceneShot>.unmodifiable(shots);
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

  static const int silhouetteGridWidth = 80;
  static const int silhouetteGridHeight = 45;

  /// Mean absolute luma difference (0..255) above which two grids count as a
  /// scene cut.
  static const double silhouetteSceneChangeThreshold = 16.0;

  static const double silhouetteRegionX0 = 0.0;
  static const double silhouetteRegionX1 = 1.0;
  static const double silhouetteRegionY0 = 0.12;
  static const double silhouetteRegionY1 = 0.92;

  static const int silhouetteMaxLuma = 24;
  static const int silhouetteNeighborhoodLuma = 28;
  static const int silhouetteMaxChannelSpread = 14;
  static const double silhouetteMinBackgroundLuma = 38;

  static const double silhouetteMinClusterFraction = 0.014;
  static const double silhouetteMaxClusterFraction = 0.48;
  static const double silhouetteMinBottomFraction = 0.52;
  static const double silhouetteMaxTopFraction = 0.65;
  static const double silhouetteMinHeightFraction = 0.15;
  static const double silhouetteMinWidthFraction = 0.055;

  static const double emptyFrameCenterResetSec = 1.5;

  /// Tight steady-shot threshold: only truly frozen tripod segments (<= 0.8%
  /// movement) collapse to a static hold, while any genuine speaker movement
  /// (> 0.8% of frame) is followed smoothly by the virtual camera.
  static const double shotSteadyTolerance = 0.008;

  static Future<({Uint8List silhouetteGrid, Uint8List mouthGrid})?>
      _decodeAnalysisGrids(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      ui.Image? image;
      try {
        final frame = await codec.getNextFrame();
        image = frame.image;
        final srcW = image.width;
        final srcH = image.height;
        if (srcW <= 0 || srcH <= 0) return null;
        final data = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (data == null) return null;
        final src = data.buffer.asUint8List();
        final silGrid = _boxDownsampleRgba(
          src,
          srcW,
          srcH,
          silhouetteGridWidth,
          silhouetteGridHeight,
        );
        final mouthGrid = _boxDownsampleRgba(
          src,
          srcW,
          srcH,
          mouthGridWidth,
          mouthGridHeight,
        );
        return (silhouetteGrid: silGrid, mouthGrid: mouthGrid);
      } finally {
        image?.dispose();
        codec.dispose();
      }
    } catch (e) {
      AppLogger().e('FaceTrack: grid decode failed for $path', e);
      return null;
    }
  }

  static Uint8List _boxDownsampleRgba(
    Uint8List src,
    int srcW,
    int srcH,
    int dstW,
    int dstH,
  ) {
    final out = Uint8List(dstW * dstH * 4);
    for (var gy = 0; gy < dstH; gy++) {
      final y0 = (gy * srcH) ~/ dstH;
      final y1 = max(y0 + 1, ((gy + 1) * srcH) ~/ dstH);
      final yStep = max(1, (y1 - y0) ~/ 4);
      for (var gx = 0; gx < dstW; gx++) {
        final x0 = (gx * srcW) ~/ dstW;
        final x1 = max(x0 + 1, ((gx + 1) * srcW) ~/ dstW);
        final xStep = max(1, (x1 - x0) ~/ 4);
        var rSum = 0;
        var gSum = 0;
        var bSum = 0;
        var count = 0;
        for (var y = y0; y < y1; y += yStep) {
          final rowOffset = y * srcW * 4;
          for (var x = x0; x < x1; x += xStep) {
            final idx = rowOffset + x * 4;
            rSum += src[idx];
            gSum += src[idx + 1];
            bSum += src[idx + 2];
            count++;
          }
        }
        final dstIdx = (gy * dstW + gx) * 4;
        if (count > 0) {
          out[dstIdx] = rSum ~/ count;
          out[dstIdx + 1] = gSum ~/ count;
          out[dstIdx + 2] = bSum ~/ count;
        }
        out[dstIdx + 3] = 255;
      }
    }
    return out;
  }

  /// True when the mean luma difference between two frames is large enough to
  /// be a hard scene cut, even after compensating for small 1-2 cell handheld
  /// camera shifts.
  static bool isSceneChange(
    Uint8List? prevBytes,
    Uint8List currentBytes,
    int width,
    int height,
  ) {
    if (prevBytes == null || prevBytes.length != currentBytes.length) {
      return false;
    }
    final count = width * height;
    if (count == 0) return false;

    // 1. Direct unshifted mean luma diff.
    var totalDiff = 0;
    for (var i = 0; i < count; i++) {
      final o = i * 4;
      final l1 =
          (77 * prevBytes[o] + 150 * prevBytes[o + 1] + 29 * prevBytes[o + 2]) >>
          8;
      final l2 = (77 * currentBytes[o] +
              150 * currentBytes[o + 1] +
              29 * currentBytes[o + 2]) >>
          8;
      totalDiff += (l2 - l1).abs();
    }
    final unshiftedDiff = totalDiff / count;
    if (unshiftedDiff < silhouetteSceneChangeThreshold) {
      return false;
    }

    // 2. Shift-compensated check: if a small 1-2 cell camera pan aligns the
    // frames to below 13.5 luma diff, it was handheld camera motion rather
    // than a scene cut.
    var minAlignedDiff = unshiftedDiff;
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        if (dx == 0 && dy == 0) continue;
        var sum = 0;
        var n = 0;
        final yStart = max(0, -dy);
        final yEnd = min(height, height - dy);
        final xStart = max(0, -dx);
        final xEnd = min(width, width - dx);
        for (var y = yStart; y < yEnd; y += 2) {
          for (var x = xStart; x < xEnd; x += 2) {
            final o1 = (y * width + x) * 4;
            final o2 = ((y + dy) * width + (x + dx)) * 4;
            final l1 = (77 * prevBytes[o1] +
                    150 * prevBytes[o1 + 1] +
                    29 * prevBytes[o1 + 2]) >>
                8;
            final l2 = (77 * currentBytes[o2] +
                    150 * currentBytes[o2 + 1] +
                    29 * currentBytes[o2 + 2]) >>
                8;
            sum += (l2 - l1).abs();
            n++;
          }
        }
        if (n > 0) {
          final aligned = sum / n;
          if (aligned < minAlignedDiff) {
            minAlignedDiff = aligned;
          }
        }
      }
    }
    return minAlignedDiff >= silhouetteSceneChangeThreshold;
  }

  /// Pure, unit-testable detector for an **anonymized pitch-black silhouette**
  /// speaker on a `width * height` RGBA buffer.
  static SilhouetteSubject? detectSilhouetteOrMotionSubject(
    Uint8List rgbaBytes,
    int width,
    int height,
    Uint8List? prevRgbaBytes, {
    List<({double x0, double y0, double x1, double y1})> excludeRects = const [],
  }) {
    if (width <= 0 || height <= 0) return null;
    if (rgbaBytes.length < width * height * 4) return null;

    final sceneChanged =
        isSceneChange(prevRgbaBytes, rgbaBytes, width, height);

    final x0 = (width * silhouetteRegionX0).floor();
    final x1 = (width * silhouetteRegionX1).ceil();
    final y0 = (height * silhouetteRegionY0).floor();
    final y1 = (height * silhouetteRegionY1).ceil();
    final regionW = x1 - x0;
    final regionH = y1 - y0;
    if (regionW <= 2 || regionH <= 2) return null;

    final luma = Int32List(width * height);
    final spread = Int32List(width * height);
    for (var i = 0; i < width * height; i++) {
      final o = i * 4;
      final r = rgbaBytes[o];
      final g = rgbaBytes[o + 1];
      final b = rgbaBytes[o + 2];
      luma[i] = (77 * r + 150 * g + 29 * b) >> 8;
      final hi = max(r, max(g, b));
      final lo = min(r, min(g, b));
      spread[i] = hi - lo;
    }

    final excluded = Uint8List(width * height);
    for (final rect in excludeRects) {
      final rx0 = (rect.x0 * width).floor().clamp(0, width);
      final rx1 = (rect.x1 * width).ceil().clamp(0, width);
      final ry0 = (rect.y0 * height).floor().clamp(0, height);
      final ry1 = (rect.y1 * height).ceil().clamp(0, height);
      for (var gy = ry0; gy < ry1; gy++) {
        for (var gx = rx0; gx < rx1; gx++) {
          excluded[gy * width + gx] = 1;
        }
      }
    }

    final mask = Uint8List(width * height);
    var backgroundSum = 0;
    var backgroundCount = 0;
    for (var gy = y0; gy < y1; gy++) {
      for (var gx = x0; gx < x1; gx++) {
        final idx = gy * width + gx;
        if (excluded[idx] != 0) continue;
        final cellLuma = luma[idx];
        final cellSpread = spread[idx];
        var darkNeighbors = 0;
        var windowCells = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = gy + dy;
          if (ny < y0 || ny >= y1) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = gx + dx;
            if (nx < x0 || nx >= x1) continue;
            windowCells++;
            final nIdx = ny * width + nx;
            if (luma[nIdx] <= silhouetteNeighborhoodLuma &&
                spread[nIdx] <= silhouetteMaxChannelSpread) {
              darkNeighbors++;
            }
          }
        }
        final isDarkPatch = cellLuma <= silhouetteMaxLuma &&
            cellSpread <= silhouetteMaxChannelSpread &&
            darkNeighbors >= max(4, (windowCells * 2) ~/ 3);
        if (isDarkPatch) {
          mask[idx] = 1;
        } else {
          backgroundSum += cellLuma;
          backgroundCount++;
        }
      }
    }

    if (backgroundCount == 0 ||
        backgroundSum / backgroundCount < silhouetteMinBackgroundLuma) {
      return null;
    }

    for (var gy = y0; gy < y1; gy++) {
      var runStart = -1;
      for (var gx = x0; gx <= x1; gx++) {
        final on = gx < x1 && mask[gy * width + gx] == 1;
        if (on && runStart < 0) {
          runStart = gx;
        } else if (!on && runStart >= 0) {
          if (gx - runStart < 3) {
            for (var x = runStart; x < gx; x++) {
              mask[gy * width + x] = 0;
            }
          }
          runStart = -1;
        }
      }
    }

    final visited = Uint8List(width * height);
    final queue = Int32List(width * height);
    final minClusterCells =
        max(18, (width * height * silhouetteMinClusterFraction).round());
    final maxClusterCells =
        (width * height * silhouetteMaxClusterFraction).round();

    List<int>? bestCluster;
    var bestArea = 0;
    var bestMinX = 0;
    var bestMaxX = 0;
    var bestMinY = 0;
    var bestMaxY = 0;

    for (var gy = y0; gy < y1; gy++) {
      for (var gx = x0; gx < x1; gx++) {
        final start = gy * width + gx;
        if (mask[start] == 0 || visited[start] != 0) continue;

        var head = 0;
        var tail = 0;
        queue[tail++] = start;
        visited[start] = 1;
        var cMinX = gx;
        var cMaxX = gx;
        var cMinY = gy;
        var cMaxY = gy;
        final cells = <int>[];

        while (head < tail) {
          final current = queue[head++];
          cells.add(current);
          final cy = current ~/ width;
          final cx = current - cy * width;
          if (cx < cMinX) cMinX = cx;
          if (cx > cMaxX) cMaxX = cx;
          if (cy < cMinY) cMinY = cy;
          if (cy > cMaxY) cMaxY = cy;

          for (var dy = -1; dy <= 1; dy++) {
            final ny = cy + dy;
            if (ny < y0 || ny >= y1) continue;
            for (var dx = -1; dx <= 1; dx++) {
              if (dx == 0 && dy == 0) continue;
              final nx = cx + dx;
              if (nx < x0 || nx >= x1) continue;
              final next = ny * width + nx;
              if (mask[next] == 1 && visited[next] == 0) {
                visited[next] = 1;
                queue[tail++] = next;
              }
            }
          }
        }

        final area = cells.length;
        if (area < minClusterCells || area > maxClusterCells) continue;

        final boxW = cMaxX - cMinX + 1;
        final boxH = cMaxY - cMinY + 1;
        final bottomFraction = (cMaxY + 1) / height;
        final topFraction = cMinY / height;
        if (bottomFraction < silhouetteMinBottomFraction) continue;
        if (topFraction > silhouetteMaxTopFraction) continue;
        if (boxH / height < silhouetteMinHeightFraction) continue;
        if (boxW / width < silhouetteMinWidthFraction) continue;
        if (boxW > boxH * 1.9) continue;

        final fillRatio = area / (boxW * boxH);
        if (fillRatio < 0.35) continue;

        if (area > bestArea) {
          bestArea = area;
          bestCluster = cells;
          bestMinX = cMinX;
          bestMaxX = cMaxX;
          bestMinY = cMinY;
          bestMaxY = cMaxY;
        }
      }
    }

    if (bestCluster == null) return null;

    final clusterH = bestMaxY - bestMinY + 1;
    final headBandMaxY = bestMinY + max(2, (clusterH * 0.40).round());
    var headWeight = 0.0;
    var headWeightedX = 0.0;
    var allWeight = 0.0;
    var allWeightedX = 0.0;

    for (final idx in bestCluster) {
      final cy = idx ~/ width;
      final cx = idx - cy * width;
      final darkness = (silhouetteNeighborhoodLuma + 4 - luma[idx])
          .clamp(1, silhouetteNeighborhoodLuma + 4)
          .toDouble();
      allWeight += darkness;
      allWeightedX += (cx + 0.5) * darkness;
      if (cy <= headBandMaxY) {
        headWeight += darkness;
        headWeightedX += (cx + 0.5) * darkness;
      }
    }

    final centerX = headWeight > 0
        ? (headWeightedX / headWeight) / width
        : (allWeightedX / allWeight) / width;
    final headY = (bestMinY + clusterH * 0.30 + 0.5) / height;
    final normW = ((bestMaxX - bestMinX + 1) / width).clamp(0.05, 1.0);
    final normH = (clusterH / height).clamp(0.08, 1.0);

    return (
      normX: centerX.clamp(0.05, 0.95),
      normY: headY.clamp(0.15, 0.85),
      normW: normW,
      normH: normH,
      mass: bestArea.toDouble(),
      sceneChanged: sceneChanged,
    );
  }

  static _SpeakerTrack? _associateSilhouette(
    Map<int, _SpeakerTrack> tracks, {
    required double nowSec,
    required double cx,
    required double cy,
    required bool allowExisting,
  }) {
    if (!allowExisting) return null;
    _SpeakerTrack? nearest;
    var bestDistance = 0.22;
    for (final track in tracks.values) {
      if (!track.isSilhouette) continue;
      if (track.lastSeenSec == nowSec) continue;
      if (nowSec - track.lastSeenSec > 2.5) continue;
      final dx = track.normX - cx;
      final dy = track.normY - cy;
      final d = sqrt(dx * dx + dy * dy);
      if (d < bestDistance) {
        bestDistance = d;
        nearest = track;
      }
    }
    return nearest;
  }

  static double _silhouetteMotionActivity(
    Uint8List prevGrid,
    Uint8List currGrid,
    int gridW,
    int gridH,
    double normX,
    double normY,
    double normW,
    double normH,
  ) {
    if (prevGrid.length < gridW * gridH * 4 ||
        currGrid.length < gridW * gridH * 4) {
      return 0.0;
    }
    final x0 = ((normX - normW * 0.65) * gridW).floor().clamp(0, gridW - 1);
    final x1 = ((normX + normW * 0.65) * gridW).ceil().clamp(x0 + 1, gridW);
    final y0 = ((normY - normH * 0.45) * gridH).floor().clamp(0, gridH - 1);
    final y1 = ((normY + normH * 0.55) * gridH).ceil().clamp(y0 + 1, gridH);
    var diffSum = 0;
    var count = 0;
    for (var gy = y0; gy < y1; gy++) {
      for (var gx = x0; gx < x1; gx++) {
        final o = (gy * gridW + gx) * 4;
        final l1 =
            (77 * prevGrid[o] + 150 * prevGrid[o + 1] + 29 * prevGrid[o + 2]) >>
                8;
        final l2 =
            (77 * currGrid[o] + 150 * currGrid[o + 1] + 29 * currGrid[o + 2]) >>
                8;
        diffSum += (l2 - l1).abs();
        count++;
      }
    }
    if (count == 0) return 0.0;
    return (diffSum / count) / 255.0;
  }

  // ---------------------------------------------------------------------------
  // Lip activity + multi-person association
  // ---------------------------------------------------------------------------

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
    required Uint8List? currGrid,
    required Uint8List? prevGrid,
    required int gridW,
    required int gridH,
    required double nowSec,
  }) {
    final fw = (nx1 - nx0).clamp(0.02, 1.0);
    final fh = (ny1 - ny0).clamp(0.02, 1.0);
    final stabW = hasPrev && track.normW > 0 ? 0.68 * track.normW + 0.32 * fw : fw;
    final stabH = hasPrev && track.normH > 0 ? 0.68 * track.normH + 0.32 * fh : fh;

    var centerX = (nx0 + nx1) * 0.5;
    var centerY = (ny0 + ny1) * 0.5;
    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    final nose = face.landmarks[FaceLandmarkType.noseBase]?.position;
    if (leftEye != null &&
        rightEye != null &&
        nose != null &&
        imgWidth > 0 &&
        imgHeight > 0) {
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

    // Resolution confidence scale: prevents tiny background faces from having
    // amplified relative landmark noise.
    final resScale = (fh / 0.14).clamp(0.35, 1.0);

    final metrics = _lipMetrics(face, box);
    final open = metrics.$1;
    final width = metrics.$2;
    var geomDelta = 0.0;
    if (open != null) {
      final previous = track.lastOpen;
      if (hasPrev && previous != null) {
        final dOpen = max(0.0, (open - previous).abs() - 0.009);
        geomDelta += dOpen * 2.4 * resScale;
      }
      track.lastOpen = open;
    }
    if (width != null) {
      final previous = track.lastWidth;
      if (hasPrev && previous != null) {
        final dWidth = max(0.0, (width - previous).abs() - 0.009);
        geomDelta += dWidth * 1.4 * resScale;
      }
      track.lastWidth = width;
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
            ? max(0.0, (currContrast - prevContrast).abs() - 0.009)
            : 0.0;
        pixelDelta = (regionDelta * 4.0 + contrastDelta * 2.0) * resScale;
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

  /// Shift-aligned non-rigid mouth deformation detector:
  /// Computes the minimum mean absolute luma difference inside the face's
  /// mouth box (`x: [0.25..0.75]`, `y: [0.58..0.88]`) across small sub-box
  /// rigid translations (`{-0.02, 0.0, +0.02}` of face width/height), MINUS
  /// the rigid upper-face motion (`y: [0.16..0.44]`).
  ///
  /// Because rigid shifts align static mustaches, beards, and camera shake to
  /// ~0 while non-rigid lip opening/closing cannot be canceled by any rigid
  /// shift, silent bystanders in handheld shots never trigger false speech.
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
    const n = cols * rows;

    const shifts = <double>[-0.020, 0.0, 0.020];
    var minMouthDiff = double.infinity;
    for (final sdy in shifts) {
      for (final sdx in shifts) {
        var mouthSum = 0.0;
        final offX = sdx * fw;
        final offY = sdy * fh;
        for (var r = 0; r < rows; r++) {
          for (var c = 0; c < cols; c++) {
            final tx = (cx0 + (cx1 - cx0) * (c + 0.5) / cols + offX)
                .clamp(0.0, 1.0);
            final ty = (cy0 + (cy1 - cy0) * (r + 0.5) / rows + offY)
                .clamp(0.0, 1.0);
            final px = px0 + (px1 - px0) * (c + 0.5) / cols;
            final py = py0 + (py1 - py0) * (r + 0.5) / rows;
            final currLuma = _sampleLumaBilinear(currGrid, gridW, gridH, tx, ty);
            final prevLuma = _sampleLumaBilinear(prevGrid, gridW, gridH, px, py);
            mouthSum += (currLuma - prevLuma).abs();
          }
        }
        final diff = (mouthSum / n) / 255.0;
        if (diff < minMouthDiff) {
          minMouthDiff = diff;
        }
      }
    }

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
    final netDiff = max(0.0, minMouthDiff - 0.85 * upperDiff);
    return max(0.0, netDiff - 0.0065);
  }

  static (double?, double?) _lipMetrics(Face face, ui.Rect box) {
    final height = box.height > 0 ? box.height : 1.0;
    final width = box.width > 0 ? box.width : 1.0;
    double? open;

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
      if (track.lastSeenSec == nowSec) continue;
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
      if (track.lastSeenSec == nowSec) continue;
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

  static _SpeakerTrack? _selectSpeaker(
    List<_SpeakerTrack> present,
    _SpeakerTrack? current, {
    required double nowSec,
  }) {
    if (present.isEmpty) return null;
    if (present.length == 1) {
      final only = present.first;
      only.lockStartSec ??= nowSec;
      return only;
    }

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
                best.recentActivity >= 0.015) ||
            (best.isSilhouette && best.silhouetteActivity >= 0.045);
        final currentNeverSpoke = !current.isSilhouette &&
            current.lastSpokeSec < 0 &&
            current.speakingFrames == 0;
        final bestStartedSpeaking = (!best.isSilhouette &&
                best.speakingFrames >= 1 &&
                best.recentActivity >= 0.014) ||
            (best.isSilhouette && best.silhouetteActivity >= 0.045);
        if (currentNeverSpoke && bestStartedSpeaking) {
          best.lockStartSec = nowSec;
          return best;
        }
        final currentPaused =
            sinceCurrentSpoke >= 1.2 || current.silentFrames >= 5;
        if (bestConfirmed &&
            ((currentPaused && best.score > current.score * 1.20 + 0.010) ||
                (lockedFor >= speakerLockSeconds &&
                    best.score > current.score * 1.45 + 0.016))) {
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

  static const int maxProfiles = 4;
  static const double profileMergeDistance = 0.18;

  static List<DetectedSpeakerProfile> _buildProfiles(
    Map<int, _SpeakerTrack> tracks, {
    required int frameCount,
  }) {
    final minHits = max(2, frameCount ~/ 35);
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
    if (total <= 1) return 'Person 1 (الشخص 1)';
    if (index == 0) return 'Person 1 - Left (يسار)';
    if (index == total - 1) return 'Person ${index + 1} - Right (يمين)';
    return 'Person ${index + 1} - Center (وسط)';
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
  // Camera stabilization & Per-Shot Lock (pure, unit-testable)
  // ---------------------------------------------------------------------------

  /// Builds the camera keyframe trajectory from [rawPoints].
  ///
  /// - Within any continuous turn, the camera follows the speaker's movement
  ///   smoothly (`isCut: false`) so the viewport glides with the speaker.
  /// - When switching between two speakers inside the same scene, the previous
  ///   speaker's turn holds up to the switch and pans smoothly (`isCut: false`
  ///   when `allowHardCuts == false`, or `isCut: true` at explicit scene cuts).
  static List<FaceTrackPoint> buildKeyframes(
    List<FaceTrackPoint> rawPoints, {
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    int maxKeyframes = FaceDetectionService.maxKeyframes,
    bool smoothTransitions = true,
  }) {
    if (rawPoints.isEmpty) return const [];
    final ranges = _splitSegments(rawPoints, speakerJumpThreshold);
    final boundaries = ranges.length - 1;
    final available = max(maxKeyframes - boundaries * 2, ranges.length);
    final total = rawPoints.length;
    final out = <FaceTrackPoint>[];

    // Effective dead-zone for continuous speaker follow: small enough that real
    // speaker movement (>1.2%) is followed smoothly instead of freezing.
    final followDeadZone = min(deadZone * 0.35, 0.014);

    for (var rIdx = 0; rIdx < ranges.length; rIdx++) {
      final (start, end) = ranges[rIdx];
      final rawSlice = rawPoints.sublist(start, end);
      final isExplicitSceneCut = rawSlice.first.isCut;
      final segment = _stabilizeSegment(
        rawSlice,
        followDeadZone,
        smoothness,
      );
      if (segment.isEmpty) continue;

      final median = _medianOf(segment);
      var maxDevX = 0.0;
      var maxDevY = 0.0;
      for (final point in segment) {
        final dx = (point.normX - median.$1).abs();
        final dy = (point.normY - median.$2).abs();
        if (dx > maxDevX) maxDevX = dx;
        if (dy > maxDevY) maxDevY = dy;
      }

      final useCutOnEntry = rIdx > 0 && isExplicitSceneCut && !smoothTransitions;

      if (maxDevX <= shotSteadyTolerance && maxDevY <= shotSteadyTolerance) {
        final firstT = rawSlice.first.timeSec;
        final lastT = rawSlice.last.timeSec;
        out.add(
          FaceTrackPoint(
            timeSec: firstT,
            normX: median.$1,
            normY: median.$2,
            isCut: useCutOnEntry,
          ),
        );
        if (lastT - firstT >= 0.20) {
          out.add(
            FaceTrackPoint(
              timeSec: lastT,
              normX: median.$1,
              normY: median.$2,
              isCut: false,
            ),
          );
        }
        continue;
      }

      final budget = max(3, (available * (end - start)) ~/ total);
      final simplified = _simplifySegment(segment, budget);
      if (simplified.isNotEmpty) {
        simplified[0] = simplified.first.copyWith(isCut: useCutOnEntry);
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

  /// Builds a complete keyframe trajectory honoring per-shot user overrides
  /// ([ShotTrackingOverride]):
  ///  - [ShotLockMode.autoSpeaker]: follows the active speaker in that shot;
  ///  - [ShotLockMode.specificPerson]: locks onto the chosen person throughout
  ///    that shot (following that person smoothly and ignoring everyone else);
  ///  - [ShotLockMode.staticPosition]: holds a fixed `(staticNormX, staticNormY)`
  ///    position for the entire duration of that shot.
  static List<FaceTrackPoint> buildKeyframesWithShotOverrides({
    required FaceTrackResult track,
    required List<SceneShot> shots,
    required Map<int, ShotTrackingOverride> shotOverrides,
    int? globalSpeakerId,
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
  }) {
    if (shots.isEmpty) {
      if (globalSpeakerId != null) {
        final profile = _findProfile(track.speakers, globalSpeakerId);
        if (profile != null && profile.rawPoints.isNotEmpty) {
          return buildKeyframes(
            profile.rawPoints,
            deadZone: deadZone,
            smoothness: smoothness,
          );
        }
      }
      return buildKeyframes(
        track.rawPoints,
        deadZone: deadZone,
        smoothness: smoothness,
      );
    }

    final combinedKeyframes = <FaceTrackPoint>[];
    for (var sIdx = 0; sIdx < shots.length; sIdx++) {
      final shot = shots[sIdx];
      final override = shotOverrides[shot.id];
      final effectiveMode = override?.mode ??
          (globalSpeakerId != null
              ? ShotLockMode.specificPerson
              : ShotLockMode.autoSpeaker);
      final targetSpeakerId = override?.mode == ShotLockMode.specificPerson
          ? override?.speakerId
          : (override == null ? globalSpeakerId : null);

      if (effectiveMode == ShotLockMode.staticPosition) {
        final sx = (override?.staticNormX ?? track.avgNormX).clamp(0.0, 1.0);
        final sy = (override?.staticNormY ?? track.avgNormY).clamp(0.0, 1.0);
        combinedKeyframes.add(
          FaceTrackPoint(
            timeSec: shot.startSec,
            normX: sx,
            normY: sy,
            isCut: false,
            isManual: true,
          ),
        );
        if (shot.endSec - shot.startSec >= 0.15) {
          combinedKeyframes.add(
            FaceTrackPoint(
              timeSec: max(shot.startSec + 0.05, shot.endSec - 0.08),
              normX: sx,
              normY: sy,
              isCut: false,
              isManual: true,
            ),
          );
        }
        continue;
      }

      List<FaceTrackPoint> shotRaw;
      if (effectiveMode == ShotLockMode.specificPerson &&
          targetSpeakerId != null) {
        final profile = _findProfile(track.speakers, targetSpeakerId);
        shotRaw = _extractShotPointsForPerson(
          profile: profile,
          fallbackRaw: track.rawPoints,
          startSec: shot.startSec,
          endSec: shot.endSec,
        );
      } else {
        shotRaw = track.rawPoints
            .where((p) => p.timeSec >= shot.startSec - 1e-3 && p.timeSec <= shot.endSec + 1e-3)
            .map((p) => p.copyWith(isCut: false))
            .toList();
      }

      if (shotRaw.isEmpty) {
        final (fx, fy) = track.sampleAt((shot.startSec + shot.endSec) * 0.5);
        shotRaw = [
          FaceTrackPoint(timeSec: shot.startSec, normX: fx, normY: fy),
          if (shot.endSec > shot.startSec + 0.1)
            FaceTrackPoint(timeSec: shot.endSec, normX: fx, normY: fy),
        ];
      }

      final shotKfs = buildKeyframes(
        shotRaw,
        deadZone: deadZone,
        smoothness: smoothness,
      );
      for (final kf in shotKfs) {
        if (combinedKeyframes.isNotEmpty &&
            (kf.timeSec - combinedKeyframes.last.timeSec).abs() < 0.05) {
          combinedKeyframes[combinedKeyframes.length - 1] =
              kf.copyWith(isCut: false);
        } else {
          combinedKeyframes.add(kf.copyWith(isCut: false));
        }
      }
    }

    return List<FaceTrackPoint>.unmodifiable(
      _enforceBudget(combinedKeyframes, maxKeyframes),
    );
  }

  static DetectedSpeakerProfile? _findProfile(
    List<DetectedSpeakerProfile> speakers,
    int id,
  ) {
    for (final s in speakers) {
      if (s.id == id) return s;
    }
    return null;
  }

  static List<FaceTrackPoint> _extractShotPointsForPerson({
    required DetectedSpeakerProfile? profile,
    required List<FaceTrackPoint> fallbackRaw,
    required double startSec,
    required double endSec,
  }) {
    if (profile == null || profile.rawPoints.isEmpty) {
      return fallbackRaw
          .where((p) => p.timeSec >= startSec - 1e-3 && p.timeSec <= endSec + 1e-3)
          .toList();
    }
    final inShot = profile.rawPoints
        .where((p) => p.timeSec >= startSec - 1e-3 && p.timeSec <= endSec + 1e-3)
        .map((p) => p.copyWith(isCut: false))
        .toList();

    if (inShot.isNotEmpty) {
      final result = <FaceTrackPoint>[];
      if (inShot.first.timeSec > startSec + 0.15) {
        result.add(
          FaceTrackPoint(
            timeSec: startSec,
            normX: inShot.first.normX,
            normY: inShot.first.normY,
          ),
        );
      }
      result.addAll(inShot);
      if (inShot.last.timeSec < endSec - 0.15) {
        result.add(
          FaceTrackPoint(
            timeSec: max(inShot.last.timeSec + 0.05, endSec - 0.08),
            normX: inShot.last.normX,
            normY: inShot.last.normY,
          ),
        );
      }
      return result;
    }

    // Person wasn't directly sampled in this window: lock onto their nearest
    // known position so the user's choice is still honored.
    var nearest = profile.rawPoints.first;
    final mid = (startSec + endSec) * 0.5;
    var bestDt = double.infinity;
    for (final p in profile.rawPoints) {
      final dt = (p.timeSec - mid).abs();
      if (dt < bestDt) {
        bestDt = dt;
        nearest = p;
      }
    }
    return [
      FaceTrackPoint(timeSec: startSec, normX: nearest.normX, normY: nearest.normY),
      if (endSec > startSec + 0.1)
        FaceTrackPoint(
          timeSec: max(startSec + 0.05, endSec - 0.08),
          normX: nearest.normX,
          normY: nearest.normY,
        ),
    ];
  }

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

  /// Tight keyframe tolerance (`0.12s`) so placing two manual keyframes even a
  /// fifth of a second apart creates a smooth camera pan between them instead
  /// of overwriting the previous keyframe.
  static const double manualKeyframeToleranceSec = 0.12;

  /// Whether the transition `a -> b` is an instant jump cut.
  ///
  /// Only an explicit `b.isCut == true` (or an already materialized 1ms FFmpeg
  /// step pair) is treated as a cut. Smooth keyframes (`isCut: false`) ALWAYS
  /// interpolate smoothly like a real camera regardless of distance.
  static bool isEffectiveCut(FaceTrackPoint a, FaceTrackPoint b) {
    if (b.isCut) return true;
    if (b.isManual) return false;
    if (b.timeSec - a.timeSec <= 0.005) return true;
    return false;
  }

  /// Expands every effective cut into an explicit **1ms step pair**:
  /// `(t: b.timeSec - 0.001, position of a)` followed by `b`, while
  /// `isCut == false` keyframes stay a smooth linear pan.
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

  /// Prepares keyframes for the interactive editor: folds synthetic `t-0.001`
  /// step helpers into single keyframes while keeping all smooth keyframes
  /// (`isCut: false`) smooth so the camera never jumps like a cut.
  static List<FaceTrackPoint> normalizeKeyframesForEditing(
    List<FaceTrackPoint> keyframes,
  ) {
    if (keyframes.isEmpty) return const [];
    final cleaned = <FaceTrackPoint>[];
    for (final point in keyframes) {
      if (cleaned.isNotEmpty &&
          point.timeSec - cleaned.last.timeSec <= 0.002) {
        cleaned[cleaned.length - 1] = FaceTrackPoint(
          timeSec: point.timeSec,
          normX: point.normX,
          normY: point.normY,
          isCut: point.isCut,
          isManual: point.isManual,
        );
        continue;
      }
      cleaned.add(point);
    }
    return List<FaceTrackPoint>.unmodifiable(cleaned);
  }

  /// Adds a manual keyframe at [timeSec], or updates the nearest existing one
  /// within [tolerance] seconds in place.
  ///
  /// Defaults to smooth camera motion (`isCut: false`) and clears `isCut` on
  /// adjacent keyframes when [clearNearbyAiKeyframes] is `true` so manual
  /// camera edits always glide smoothly like a real camera.
  static List<FaceTrackPoint> upsertManualKeyframe(
    List<FaceTrackPoint> keyframes, {
    required double timeSec,
    required double normX,
    required double normY,
    double tolerance = manualKeyframeToleranceSec,
    bool isCut = false,
    bool clearNearbyAiKeyframes = false,
  }) {
    var working = List<FaceTrackPoint>.of(keyframes);
    var bestIndex = -1;
    var bestDelta = double.infinity;
    for (var i = 0; i < working.length; i++) {
      final delta = (working[i].timeSec - timeSec).abs();
      if (delta <= tolerance && delta < bestDelta) {
        bestDelta = delta;
        bestIndex = i;
      }
    }
    if (bestIndex >= 0) {
      final existing = working[bestIndex];
      working[bestIndex] = existing.copyWith(
        normX: normX,
        normY: normY,
        isCut: isCut,
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

  /// Removes non-manual AI keyframes that sit between two manual keyframes or
  /// within the same active shot after [manualIndex], and ensures the next
  /// keyframe transitions smoothly (`isCut: false`) so manual keyframes never
  /// jump like a hard cut.
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

    // Find any previous or next manual keyframe within 12 seconds: if the user
    // placed two manual keyframes to animate a camera pan, drop all automatic
    // AI keyframes between them so the camera pans directly between the user's
    // two manual keyframes.
    var prevManualIdx = -1;
    for (var i = manualIndex - 1; i >= 0; i--) {
      if (keyframes[i].isManual &&
          (targetTime - keyframes[i].timeSec) <= 12.0) {
        prevManualIdx = i;
        break;
      }
    }
    var nextManualIdx = -1;
    for (var i = manualIndex + 1; i < keyframes.length; i++) {
      if (keyframes[i].isManual &&
          (keyframes[i].timeSec - targetTime) <= 12.0) {
        nextManualIdx = i;
        break;
      }
    }

    final out = <FaceTrackPoint>[];
    var passedManual = false;
    var hitBoundaryAfterManual = false;

    for (var i = 0; i < keyframes.length; i++) {
      if (i == manualIndex) {
        out.add(keyframes[i].copyWith(isCut: false));
        passedManual = true;
        continue;
      }
      final kf = keyframes[i];

      // Drop non-manual AI points strictly between prevManualIdx and manualIndex.
      if (!kf.isManual && prevManualIdx >= 0 && i > prevManualIdx && i < manualIndex) {
        continue;
      }
      // Drop non-manual AI points strictly between manualIndex and nextManualIdx.
      if (!kf.isManual && nextManualIdx >= 0 && i > manualIndex && i < nextManualIdx) {
        continue;
      }
      // Drop non-manual AI points very close to manualIndex (±0.45s).
      if (!kf.isManual && i > 0 && (kf.timeSec - targetTime).abs() <= 0.45) {
        continue;
      }

      if (passedManual && !hitBoundaryAfterManual) {
        if (kf.isManual) {
          hitBoundaryAfterManual = true;
        } else if (kf.isCut && (kf.timeSec - targetTime) > 1.5) {
          hitBoundaryAfterManual = true;
        } else if (!kf.isManual && (kf.timeSec - targetTime) <= 4.0) {
          // Drop trailing intra-shot AI drift points so the camera holds or
          // pans smoothly according to the user's manual keyframe.
          continue;
        }
      }

      // Ensure the keyframe immediately following a manual keyframe does not
      // snap with a hard cut unless explicitly set by the user.
      if (out.isNotEmpty && out.last.isManual && !kf.isManual && kf.isCut) {
        out.add(kf.copyWith(isCut: false));
      } else {
        out.add(kf);
      }
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

  /// Stabilizes a raw trajectory with dead-zone + bidirectional EMA per shot.
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
      if (out.isNotEmpty && segment.isNotEmpty && rawPoints[start].isCut) {
        _appendInstantCut(out, segment.first);
        segment[0] = segment.first.copyWith(isCut: true);
      }
      out.addAll(segment);
    }
    return out;
  }

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
    final step = (points.length - 1) / max(1, budget - 1);
    final sampled = <FaceTrackPoint>[];
    for (var i = 0; i < budget; i++) {
      sampled.add(points[(i * step).round().clamp(0, points.length - 1)]);
    }
    return sampled;
  }

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
