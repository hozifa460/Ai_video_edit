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

  /// Normalized face bounding-box dimensions (`0.0 .. 1.0`), used by the
  /// interactive Tap-to-Track preview overlay.
  final double normW;
  final double normH;

  /// `true` when this person is actively speaking at [timeSec].
  final bool isSpeaking;

  /// Optional ID of the active speaker profile at [timeSec].
  final int? speakerId;

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
    this.normW = 0.14,
    this.normH = 0.22,
    this.isSpeaking = false,
    this.speakerId,
    this.isCut = false,
    this.isManual = false,
  });

  FaceTrackPoint copyWith({
    double? timeSec,
    double? normX,
    double? normY,
    double? normW,
    double? normH,
    bool? isSpeaking,
    int? speakerId,
    bool? isCut,
    bool? isManual,
  }) {
    return FaceTrackPoint(
      timeSec: timeSec ?? this.timeSec,
      normX: normX ?? this.normX,
      normY: normY ?? this.normY,
      normW: normW ?? this.normW,
      normH: normH ?? this.normH,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      speakerId: speakerId ?? this.speakerId,
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
  final double avgNormW;
  final double avgNormH;

  /// Bound acoustic voice cluster ID (`0, 1, ...`) when speaker diarization
  /// locked a distinct voice fingerprint to this person.
  final int? boundVoiceClusterId;

  /// Fraction (`0.0 .. 1.0`) of visible frames in which this person was the
  /// confirmed active speaker.
  final double speakingRatio;

  /// Trajectory when locked exclusively onto this person.
  final List<FaceTrackPoint> rawPoints;

  const DetectedSpeakerProfile({
    required this.id,
    required this.label,
    required this.avgNormX,
    required this.avgNormY,
    required this.rawPoints,
    this.avgNormW = 0.14,
    this.avgNormH = 0.22,
    this.boundVoiceClusterId,
    this.speakingRatio = 0.0,
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

/// Acoustic features extracted on-device for one video analysis frame.
class AudioFrameFeatures {
  /// Normalized vocal-band energy (`0.0 .. 1.0`) above the street-noise floor.
  final double speechEnergy;

  /// Normalized syllable-rate amplitude modulation (`0.0 .. 1.0`) across 62ms
  /// sub-windows. High for human speech, low for steady street/wind noise.
  final double syllableModulation;

  /// Estimated fundamental pitch (`75 .. 320 Hz`), or `0.0` when unvoiced.
  final double pitchHz;

  /// Pitch periodicity confidence (`0.0 .. 1.0`).
  final double pitchConfidence;

  /// 3-band spectral timbre ratios (`<600Hz`, `600..2800Hz`, `>2800Hz`).
  final double lowBandRatio;
  final double midBandRatio;
  final double highBandRatio;

  /// `true` when human speech is present in this frame.
  final bool isVoicedSpeech;

  /// Diarized voice cluster ID (`0, 1, 2...`), or `-1` when silent/unvoiced.
  final int voiceClusterId;

  const AudioFrameFeatures({
    this.speechEnergy = 0.5,
    this.syllableModulation = 0.5,
    this.pitchHz = 0.0,
    this.pitchConfidence = 0.0,
    this.lowBandRatio = 0.33,
    this.midBandRatio = 0.34,
    this.highBandRatio = 0.33,
    this.isVoicedSpeech = true,
    this.voiceClusterId = -1,
  });
}

/// Centroid of an online on-device speaker voice cluster (Speaker Diarization).
class _VoiceCluster {
  _VoiceCluster({
    required this.id,
    required this.pitchHz,
    required this.lowBand,
    required this.midBand,
    required this.highBand,
  });

  final int id;
  double pitchHz;
  double lowBand;
  double midBand;
  double highBand;
  int frames = 1;
  double lastSeenSec = 0.0;

  double distanceTo(AudioFrameFeatures f) {
    var pitchDist = 0.0;
    if (f.pitchHz > 65 && pitchHz > 65) {
      pitchDist = (log(f.pitchHz / pitchHz) / ln2).abs() * 1.45;
    } else {
      pitchDist = 0.25;
    }
    final bandDist = ((f.lowBandRatio - lowBand).abs() * 1.4 +
            (f.midBandRatio - midBand).abs() * 1.2 +
            (f.highBandRatio - highBand).abs() * 1.1) *
        0.95;
    return pitchDist + bandDist;
  }

  void update(AudioFrameFeatures f, double nowSec) {
    final alpha = (1.0 / min(frames + 1, 18)).clamp(0.05, 0.35);
    if (f.pitchHz > 65) {
      pitchHz = pitchHz > 65
          ? (1 - alpha) * pitchHz + alpha * f.pitchHz
          : f.pitchHz;
    }
    lowBand = (1 - alpha) * lowBand + alpha * f.lowBandRatio;
    midBand = (1 - alpha) * midBand + alpha * f.midBandRatio;
    highBand = (1 - alpha) * highBand + alpha * f.highBandRatio;
    frames++;
    lastSeenSec = nowSec;
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

/// Per-person state used while selecting the active speaker across all 3 layers:
/// 1) Voice Fingerprint / Diarization Affinity
/// 2) Multi-Face Inner-Lip Contour & Audio-Visual Synchronization
/// 3) Upper-Body / Torso Appearance Tracking
class _SpeakerTrack {
  _SpeakerTrack(this.id);

  final int id;
  int hits = 0;
  int speakingHitCount = 0;
  double lastSeenSec = -1;
  double lastDirectFaceSec = -1;

  /// Last normalized bounding box of this person's face.
  double normX = 0.5;
  double normY = 0.42;
  double normW = 0.14;
  double normH = 0.22;

  /// Landmark-stabilized face box.
  double stabNx0 = 0.4;
  double stabNy0 = 0.25;
  double stabNx1 = 0.6;
  double stabNy1 = 0.55;

  /// Upper-body (shoulders + chest) normalized box below the face.
  double torsoNx0 = 0.35;
  double torsoNy0 = 0.55;
  double torsoNx1 = 0.65;
  double torsoNy1 = 0.90;

  /// 12-feature normalized appearance descriptor of the upper torso/clothing
  /// + 12-feature head/skin descriptor for persistent person re-identification.
  Float64List? torsoSignature;
  Float64List? headSignature;

  /// Previous relative lip geometry & inner-mouth aperture.
  double? lastOpen;
  double? lastContourInnerOpen;
  double? lastOralCavityOpen;
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

  /// Rolling window of recent audio-gated lip deltas.
  final List<double> lipDeltas = <double>[];

  /// Rolling window of raw visual mouth articulation deltas (for AV correlation).
  final List<double> rawVisualDeltas = <double>[];

  /// Rolling window of instantaneous lip opening aperture (`MAR`).
  final List<double> lipOpenHistory = <double>[];

  /// Rolling window of synchronized audio speech modulation values.
  final List<double> audioModHistory = <double>[];

  /// Sliding-window Audio-Visual synchronization score (`0.0 .. 1.0`).
  double avSyncScore = 0.5;

  /// Active voice cluster ID in the current frame (`-1` if none).
  int currentFrameVoiceCluster = -1;
  bool currentFrameVoiced = true;

  /// Affinity map from diarized `voiceClusterId` -> cumulative confidence that
  /// this person is the owner of that voice.
  final Map<int, double> voiceClusterAffinity = <int, double>{};

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
      if (d >= 0.0125) count++;
    }
    return count;
  }

  /// Dominant bound voice cluster ID if this person has a confirmed voice
  /// fingerprint.
  int? get dominantVoiceClusterId {
    int? bestId;
    var bestVal = 1.6;
    voiceClusterAffinity.forEach((k, v) {
      if (v > bestVal) {
        bestVal = v;
        bestId = k;
      }
    });
    return bestId;
  }

  /// Confidence (`0.0 .. 1.0`) that the currently active voice cluster belongs
  /// to this person.
  double get currentVoiceMatchBonus {
    if (!currentFrameVoiced || currentFrameVoiceCluster < 0) return 0.0;
    final myAffinity = voiceClusterAffinity[currentFrameVoiceCluster] ?? 0.0;
    if (myAffinity < 1.35) return 0.0;
    var totalAffinity = 0.0;
    voiceClusterAffinity.forEach((_, v) => totalAffinity += v);
    final specificity = totalAffinity > 0 ? (myAffinity / totalAffinity) : 1.0;
    return (min(myAffinity, 6.0) / 6.0) * (0.35 + 0.65 * specificity);
  }

  void recordSpeechSample(
    double rawVisualDelta, {
    required double lipOpen,
    required AudioFrameFeatures audio,
    required double nowSec,
    required int window,
  }) {
    currentFrameVoiced = audio.isVoicedSpeech;
    currentFrameVoiceCluster = audio.voiceClusterId;

    rawVisualDeltas.add(rawVisualDelta);
    if (rawVisualDeltas.length > window) rawVisualDeltas.removeAt(0);

    lipOpenHistory.add(lipOpen);
    if (lipOpenHistory.length > window) lipOpenHistory.removeAt(0);

    final audioDrive =
        (0.55 * audio.speechEnergy + 0.45 * audio.syllableModulation)
            .clamp(0.0, 1.0);
    audioModHistory.add(audioDrive);
    if (audioModHistory.length > window) audioModHistory.removeAt(0);

    avSyncScore = FaceDetectionService.computeAudioVisualSyncScore(
      rawVisualDeltas,
      lipOpenHistory,
      audioModHistory,
    );

    final double effectiveDelta;
    if (!audio.isVoicedSpeech) {
      effectiveDelta = rawVisualDelta * 0.18;
    } else {
      final syncBoost = 0.72 + 0.68 * avSyncScore;
      final energyBoost = 0.80 + 0.40 * audioDrive;
      effectiveDelta = rawVisualDelta * syncBoost * energyBoost;
    }

    lipDeltas.add(effectiveDelta);
    if (lipDeltas.length > window) {
      lipDeltas.removeAt(0);
    }

    if (effectiveDelta >= 0.0125 && audio.isVoicedSpeech) {
      silentFrames = 0;
      lastSpokeSec = nowSec;
      speakingHitCount++;
    } else {
      silentFrames++;
    }
  }

  /// Active-speaker score combining:
  /// 1) Audio-Visual synchronized inner-lip articulation (`recentActivity * speechMult`)
  /// 2) On-device Voice Diarization identity lock (`voiceBonus`)
  /// 3) Foreground subject prominence (`prominenceBonus`)
  double get score {
    if (isSilhouette) {
      return silhouetteActivity * 10.0 + areaNorm * 0.04;
    }
    final activeCount = speakingFrames;
    final speechMult = activeCount >= 2 ? 19.0 : (activeCount == 1 ? 9.5 : 2.8);
    final avMultiplier = 0.75 + 0.55 * avSyncScore;
    final prominenceBonus =
        areaNorm * 0.42 + foregroundRatio.clamp(0.0, 1.0) * 0.045;
    final voiceBonus = currentVoiceMatchBonus * 0.26;

    var s = recentActivity * speechMult * avMultiplier +
        (activeCount >= 2 ? 0.065 * activeCount : 0.0) +
        voiceBonus +
        prominenceBonus +
        0.015 * (min(hits, 8) / 8);

    if (lastMoveDelta > 0.12 && activeCount < 2 && voiceBonus < 0.08) {
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

/// Real 3-Layer On-Device Active Speaker, Voice Diarization, Multi-Face Contour
/// Lip Sync & Upper-Body Virtual Camera Tracking Service.
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
  static const double associationDistance = 0.17;
  static const double minFaceOverlap = 0.10;

  /// Minimum time the camera stays on one speaker before a turn-taking switch.
  static const double speakerLockSeconds = 1.20;

  /// Frames kept in the rolling lip-delta & AV-sync window (~1.6s at 5fps).
  static const int lipWindow = 8;

  /// High-resolution grid used for mouth/upper-face/torso analysis (4x4 source
  /// pixels per cell on 960x540 frames).
  static const int mouthGridWidth = 240;
  static const int mouthGridHeight = 135;

  /// Minimum ratio of a face's area to the largest face in the frame (`0.26`)
  /// required to be considered a foreground speaker candidate.
  static const double minForegroundAreaRatio = 0.26;

  // ---------------------------------------------------------------------------
  // Layer 1: On-Device Audio Voice Fingerprinting & Speech Modulation Analysis
  // ---------------------------------------------------------------------------

  static Future<List<AudioFrameFeatures>> _extractAndAnalyzeAudio({
    required String videoPath,
    required String tempDirPath,
    required double startSec,
    required double durationSec,
    required double sampleFps,
    required int expectedFrames,
  }) async {
    final wavPath = '$tempDirPath/voice_track.wav';
    try {
      final cmd =
          '-ss ${startSec.toStringAsFixed(3)} '
          '-t ${durationSec.toStringAsFixed(3)} -i "$videoPath" '
          '-vn -ac 1 -ar 16000 -acodec pcm_s16le -y "$wavPath"';
      final session = await FFmpegKit.execute(cmd);
      if (!ReturnCode.isSuccess(await session.getReturnCode())) {
        return List<AudioFrameFeatures>.filled(
          expectedFrames,
          const AudioFrameFeatures(),
        );
      }
      final wavFile = File(wavPath);
      if (!await wavFile.exists()) {
        return List<AudioFrameFeatures>.filled(
          expectedFrames,
          const AudioFrameFeatures(),
        );
      }
      final bytes = await wavFile.readAsBytes();
      return analyzeWavBytes(
        bytes,
        sampleFps: sampleFps,
        frameCount: expectedFrames,
      );
    } catch (e) {
      AppLogger().e('FaceTrack: audio voice analysis fallback', e);
      return List<AudioFrameFeatures>.filled(
        expectedFrames,
        const AudioFrameFeatures(),
      );
    }
  }

  /// Pure, unit-testable 16kHz 16-bit PCM WAV analyzer that extracts:
  /// - Vocal-band pre-emphasized RMS energy (`speechEnergy`)
  /// - Syllable-rate modulation (`syllableModulation`)
  /// - Autocorrelation pitch (`pitchHz`) and 3-band spectral ratios
  /// - Online Speaker Diarization cluster IDs (`voiceClusterId`)
  static List<AudioFrameFeatures> analyzeWavBytes(
    Uint8List wavBytes, {
    required double sampleFps,
    required int frameCount,
    int sampleRate = 16000,
  }) {
    if (frameCount <= 0) return const [];
    var dataOffset = 44;
    for (var i = 12; i < min(wavBytes.length - 8, 256); i++) {
      if (wavBytes[i] == 0x64 &&
          wavBytes[i + 1] == 0x61 &&
          wavBytes[i + 2] == 0x74 &&
          wavBytes[i + 3] == 0x61) {
        dataOffset = i + 8;
        break;
      }
    }
    if (wavBytes.length <= dataOffset + 32) {
      return List<AudioFrameFeatures>.filled(
        frameCount,
        const AudioFrameFeatures(),
      );
    }

    final totalSamples = (wavBytes.length - dataOffset) ~/ 2;
    final samples = Float32List(totalSamples);
    final bd = ByteData.sublistView(wavBytes, dataOffset);
    for (var i = 0; i < totalSamples; i++) {
      samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final step = max(64, (sampleRate / sampleFps).round());
    final rawEnergies = List<double>.filled(frameCount, 0.0);
    final rawMods = List<double>.filled(frameCount, 0.0);
    final pitches = List<double>.filled(frameCount, 0.0);
    final pitchConfs = List<double>.filled(frameCount, 0.0);
    final lowBands = List<double>.filled(frameCount, 0.33);
    final midBands = List<double>.filled(frameCount, 0.34);
    final highBands = List<double>.filled(frameCount, 0.33);

    for (var f = 0; f < frameCount; f++) {
      final start = f * step;
      final end = min(totalSamples, start + step);
      final len = end - start;
      if (len < 64) continue;

      final subLen = max(16, len ~/ 4);
      final subRms = List<double>.filled(4, 0.0);
      var prev = samples[start];
      for (var k = 0; k < 4; k++) {
        final s0 = start + k * subLen;
        final s1 = k == 3 ? end : min(end, s0 + subLen);
        if (s1 <= s0) continue;
        var sumSq = 0.0;
        for (var idx = s0; idx < s1; idx++) {
          final cur = samples[idx];
          final pre = cur - 0.95 * prev;
          prev = cur;
          sumSq += pre * pre;
        }
        subRms[k] = sqrt(sumSq / (s1 - s0));
      }
      final meanRms = (subRms[0] + subRms[1] + subRms[2] + subRms[3]) * 0.25;
      var maxSub = subRms[0];
      var minSub = subRms[0];
      for (var k = 1; k < 4; k++) {
        if (subRms[k] > maxSub) maxSub = subRms[k];
        if (subRms[k] < minSub) minSub = subRms[k];
      }
      rawEnergies[f] = meanRms;
      rawMods[f] = maxSub - minSub;

      if (len >= 32) {
        var acc16 = 0.0;
        var acc4 = 0.0;
        for (var j = 0; j < 16; j++) {
          acc16 += samples[start + j];
        }
        for (var j = 0; j < 4; j++) {
          acc4 += samples[start + j];
        }
        var lowE = 0.0;
        var midE = 0.0;
        var highE = 0.0;
        for (var j = start + 16; j < end; j++) {
          acc16 += samples[j] - samples[j - 16];
          acc4 += samples[j] - samples[j - 4];
          final lp16 = acc16 * 0.0625;
          final lp4 = acc4 * 0.25;
          final bpMid = lp4 - lp16;
          final hp = samples[j] - lp4;
          lowE += lp16 * lp16;
          midE += bpMid * bpMid;
          highE += hp * hp;
        }
        final totE = lowE + midE + highE + 1e-9;
        lowBands[f] = lowE / totE;
        midBands[f] = midE / totE;
        highBands[f] = highE / totE;
      }

      final dsLen = min(900, len ~/ 2);
      if (dsLen >= 160) {
        final offset = start + max(0, (len - dsLen * 2) ~/ 2);
        var mean = 0.0;
        for (var k = 0; k < dsLen; k++) {
          mean += samples[offset + k * 2];
        }
        mean /= dsLen;
        final ds = Float32List(dsLen);
        var e0 = 1e-9;
        for (var k = 0; k < dsLen; k++) {
          final v = samples[offset + k * 2] - mean;
          ds[k] = v;
          e0 += v * v;
        }
        final dsRate = sampleRate / 2.0;
        final minLag = max(24, (dsRate / 300.0).floor());
        final maxLag = min(dsLen ~/ 2, (dsRate / 72.0).ceil());
        var bestR = 0.0;
        var bestLag = minLag;
        for (var lag = minLag; lag <= maxLag; lag++) {
          var corr = 0.0;
          final limit = dsLen - lag;
          for (var k = 0; k < limit; k += 2) {
            corr += ds[k] * ds[k + lag];
          }
          final r = (corr * 2.0) / e0;
          if (r > bestR) {
            bestR = r;
            bestLag = lag;
          }
        }
        pitchConfs[f] = bestR.clamp(0.0, 1.0);
        if (bestR >= 0.23 && bestLag > 0) {
          pitches[f] = dsRate / bestLag;
        }
      }
    }

    final sortedE = List<double>.of(rawEnergies)..sort();
    final sortedM = List<double>.of(rawMods)..sort();
    final eP15 = sortedE[(sortedE.length * 0.15).floor()];
    final eP90 = max(eP15 + 1e-4, sortedE[(sortedE.length * 0.90).floor()]);
    final mP15 = sortedM[(sortedM.length * 0.15).floor()];
    final mP90 = max(mP15 + 1e-4, sortedM[(sortedM.length * 0.90).floor()]);

    final clusters = <_VoiceCluster>[];
    const maxClusters = 4;
    const clusterMergeThreshold = 0.42;
    var activeClusterId = -1;
    var activeClusterRun = 0;

    final out = <AudioFrameFeatures>[];
    for (var f = 0; f < frameCount; f++) {
      final nowSec = f / sampleFps;
      final normE = ((rawEnergies[f] - eP15 * 0.85) / (eP90 - eP15 * 0.85))
          .clamp(0.0, 1.0);
      final normM = ((rawMods[f] - mP15 * 0.80) / (mP90 - mP15 * 0.80))
          .clamp(0.0, 1.0);
      final voiced = (normE >= 0.16 && normM >= 0.10) ||
          normE >= 0.28 ||
          (normE >= 0.12 && pitchConfs[f] >= 0.30);

      final tempFeature = AudioFrameFeatures(
        speechEnergy: normE,
        syllableModulation: normM,
        pitchHz: pitches[f],
        pitchConfidence: pitchConfs[f],
        lowBandRatio: lowBands[f],
        midBandRatio: midBands[f],
        highBandRatio: highBands[f],
        isVoicedSpeech: voiced,
      );

      var assignedCluster = -1;
      if (voiced && (pitches[f] > 65 || normE >= 0.25)) {
        if (clusters.isEmpty) {
          final first = _VoiceCluster(
            id: 0,
            pitchHz: pitches[f] > 65 ? pitches[f] : 145.0,
            lowBand: lowBands[f],
            midBand: midBands[f],
            highBand: highBands[f],
          )..lastSeenSec = nowSec;
          clusters.add(first);
          assignedCluster = 0;
          activeClusterId = 0;
          activeClusterRun = 1;
        } else {
          _VoiceCluster? bestCluster;
          var bestDist = double.infinity;
          for (final c in clusters) {
            var d = c.distanceTo(tempFeature);
            if (c.id == activeClusterId) d *= 0.82;
            if (d < bestDist) {
              bestDist = d;
              bestCluster = c;
            }
          }
          if (bestCluster != null &&
              (bestDist <= clusterMergeThreshold ||
                  clusters.length >= maxClusters)) {
            if (activeClusterId >= 0 &&
                bestCluster.id != activeClusterId &&
                activeClusterRun < 2 &&
                bestDist > clusterMergeThreshold * 0.65) {
              assignedCluster = activeClusterId;
              clusters[activeClusterId].update(tempFeature, nowSec);
              activeClusterRun++;
            } else {
              assignedCluster = bestCluster.id;
              bestCluster.update(tempFeature, nowSec);
              if (assignedCluster == activeClusterId) {
                activeClusterRun++;
              } else {
                activeClusterId = assignedCluster;
                activeClusterRun = 1;
              }
            }
          } else {
            final created = _VoiceCluster(
              id: clusters.length,
              pitchHz: pitches[f] > 65 ? pitches[f] : 150.0,
              lowBand: lowBands[f],
              midBand: midBands[f],
              highBand: highBands[f],
            )..lastSeenSec = nowSec;
            clusters.add(created);
            assignedCluster = created.id;
            activeClusterId = created.id;
            activeClusterRun = 1;
          }
        }
      } else if (voiced && activeClusterId >= 0) {
        assignedCluster = activeClusterId;
      }

      out.add(
        AudioFrameFeatures(
          speechEnergy: normE,
          syllableModulation: normM,
          pitchHz: pitches[f],
          pitchConfidence: pitchConfs[f],
          lowBandRatio: lowBands[f],
          midBandRatio: midBands[f],
          highBandRatio: highBands[f],
          isVoicedSpeech: voiced,
          voiceClusterId: assignedCluster,
        ),
      );
    }
    return out;
  }

  /// Sliding-window Audio-Visual synchronization score (`0.0 .. 1.0`).
  static double computeAudioVisualSyncScore(
    List<double> visualDeltas,
    List<double> lipOpenHistory,
    List<double> audioModHistory,
  ) {
    final n = min(visualDeltas.length, audioModHistory.length);
    if (n < 2) return 0.5;

    var sumV = 0.0;
    var sumA = 0.0;
    for (var i = 0; i < n; i++) {
      sumV += visualDeltas[visualDeltas.length - n + i];
      sumA += audioModHistory[audioModHistory.length - n + i];
    }
    final meanV = sumV / n;
    final meanA = sumA / n;

    var coActive = 0.0;
    var silentLeak = 0.0;
    var cov = 0.0;
    var varV = 1e-7;
    var varA = 1e-7;

    for (var i = 0; i < n; i++) {
      final v = visualDeltas[visualDeltas.length - n + i];
      final a = audioModHistory[audioModHistory.length - n + i];
      final dv = v - meanV;
      final da = a - meanA;
      cov += dv * da;
      varV += dv * dv;
      varA += da * da;

      if (a >= 0.18 && v >= 0.011) {
        coActive += min(1.0, (v / 0.025) * (a / 0.40));
      } else if (a < 0.12 && v >= 0.015) {
        silentLeak += 0.35;
      }
    }

    final pearson = (cov / sqrt(varV * varA)).clamp(-1.0, 1.0);
    final corrScore = ((pearson + 1.0) * 0.5).clamp(0.0, 1.0);
    final coActScore = (coActive / max(1, n * 0.55)).clamp(0.0, 1.0);

    var openStd = 0.0;
    if (lipOpenHistory.length >= 3) {
      var meanO = 0.0;
      for (final o in lipOpenHistory) {
        meanO += o;
      }
      meanO /= lipOpenHistory.length;
      var sq = 0.0;
      for (final o in lipOpenHistory) {
        sq += (o - meanO) * (o - meanO);
      }
      openStd = sqrt(sq / lipOpenHistory.length);
    }
    final cadenceBonus = (openStd / 0.022).clamp(0.0, 0.25);

    final combined =
        0.48 * coActScore + 0.37 * corrScore + cadenceBonus - silentLeak / n;
    return combined.clamp(0.05, 1.0);
  }

  // ---------------------------------------------------------------------------
  // Analysis Pipeline (3-Layer Engine)
  // ---------------------------------------------------------------------------

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
    if (clipDuration <= 150) {
      sampleFps = 5.0;
    } else if (clipDuration <= 300) {
      sampleFps = 4.0;
    } else {
      sampleFps = max(2.5, 600.0 / clipDuration);
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

    final cropContourDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: false,
        enableLandmarks: true,
        enableContours: true,
        enableTracking: false,
        performanceMode: FaceDetectorMode.fast,
      ),
    );

    try {
      await framesDir.create(recursive: true);
      onProgress?.call(
        0.04,
        '🔊 المرحلة 1/3: استخراج البصمة الصوتية وعزل ضوضاء الشارع...',
      );

      final expectedFrameCount = max(1, (clipDuration * sampleFps).ceil());
      final audioFuture = _extractAndAnalyzeAudio(
        videoPath: videoPath,
        tempDirPath: framesDir.path,
        startSec: startSec,
        durationSec: clipDuration,
        sampleFps: sampleFps,
        expectedFrames: expectedFrameCount + 4,
      );

      onProgress?.call(
        0.10,
        '🖼️ المرحلة 2/3: استخراج إطارات الفيديو عالية الدقة...',
      );

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

      final audioFeaturesList = await audioFuture;

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
      var lastW = 0.16;
      var lastH = 0.24;
      double? lastFaceSeenSec;
      var sceneStartPointIdx = 0;
      var sceneSpeakerConfirmed = false;
      final cropBmpPath = '${framesDir.path}/face_crop.bmp';

      final minFaceHeight = imgHeight * 0.062;
      final minFaceWidth = imgWidth * 0.038;

      for (var i = 0; i < frames.length; i++) {
        final timeSec = startSec + i / sampleFps;
        final audioFrame = i < audioFeaturesList.length
            ? audioFeaturesList[i]
            : const AudioFrameFeatures();

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
        final fullRgba = decodedGrids?.fullRgba;
        final fullW = decodedGrids?.fullW ?? 0;
        final fullH = decodedGrids?.fullH ?? 0;

        final sortedFaces = List<Face>.of(faces)
          ..sort(
            (a, b) => (b.boundingBox.width * b.boundingBox.height)
                .compareTo(a.boundingBox.width * a.boundingBox.height),
          );

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
            var foregroundFaceContinuous = false;
            if (currentSpeaker != null &&
                !currentSpeaker.isSilhouette &&
                (timeSec - currentSpeaker.lastSeenSec) <= 0.7 &&
                sortedFaces.isNotEmpty) {
              final topBox = sortedFaces.first.boundingBox;
              final nx0 = (topBox.left / imgWidth).clamp(0.0, 1.0);
              final ny0 = (topBox.top / imgHeight).clamp(0.0, 1.0);
              final nx1 = (topBox.right / imgWidth).clamp(0.0, 1.0);
              final ny1 = (topBox.bottom / imgHeight).clamp(0.0, 1.0);
              final iou = _boxOverlap(currentSpeaker, nx0, ny0, nx1, ny1);
              if (iou >= 0.28) {
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

        final foregroundCandidates = <Face>[];
        for (final face in sortedFaces) {
          final box = face.boundingBox;
          if (box.height < minFaceHeight || box.width < minFaceWidth) continue;
          final fw = (box.width / imgWidth).clamp(0.0, 1.0);
          final fh = (box.height / imgHeight).clamp(0.0, 1.0);
          final area = fw * fh;
          if (maxFaceArea > 0 && area < maxFaceArea * minForegroundAreaRatio) {
            continue;
          }
          foregroundCandidates.add(face);
          if (foregroundCandidates.length >= 3) break;
        }

        for (final face in foregroundCandidates) {
          final box = face.boundingBox;
          final nx0 = (box.left / imgWidth).clamp(0.0, 1.0);
          final ny0 = (box.top / imgHeight).clamp(0.0, 1.0);
          final nx1 = (box.right / imgWidth).clamp(0.0, 1.0);
          final ny1 = (box.bottom / imgHeight).clamp(0.0, 1.0);
          final fw = nx1 - nx0;
          final fh = ny1 - ny0;
          final area = fw * fh;

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

          final torsoNx0 = (cx - fw * 1.05).clamp(0.0, 1.0);
          final torsoNx1 = (cx + fw * 1.05).clamp(0.0, 1.0);
          final torsoNy0 = (ny1 + fh * 0.05).clamp(0.0, 0.96);
          final torsoNy1 = (ny1 + fh * 1.40).clamp(torsoNy0 + 0.03, 1.0);

          final torsoSig = mouthGrid != null
              ? _extractRegionSignature(
                  mouthGrid,
                  mouthGridWidth,
                  mouthGridHeight,
                  torsoNx0,
                  torsoNy0,
                  torsoNx1,
                  torsoNy1,
                )
              : null;
          final headSig = mouthGrid != null
              ? _extractRegionSignature(
                  mouthGrid,
                  mouthGridWidth,
                  mouthGridHeight,
                  nx0,
                  ny0,
                  nx1,
                  ny1,
                )
              : null;

          Face? contourFace;
          if (fullRgba != null &&
              fullW > 0 &&
              fullH > 0 &&
              (foregroundCandidates.length >= 2 || audioFrame.isVoicedSpeech)) {
            contourFace = await _detectContoursOnFaceCrop(
              cropContourDetector: cropContourDetector,
              fullRgba: fullRgba,
              fullW: fullW,
              fullH: fullH,
              faceBox: box,
              cropBmpPath: cropBmpPath,
            );
          }

          final track = _associateFace(
            tracks,
            nowSec: timeSec,
            nx0: nx0,
            ny0: ny0,
            nx1: nx1,
            ny1: ny1,
            cx: cx,
            cy: cy,
            torsoSig: torsoSig,
            headSig: headSig,
            allowExisting: !cut,
          );
          if (track == null) {
            final created = _SpeakerTrack(tracks.length)
              ..stabNx0 = nx0
              ..stabNy0 = ny0
              ..stabNx1 = nx1
              ..stabNy1 = ny1
              ..torsoNx0 = torsoNx0
              ..torsoNy0 = torsoNy0
              ..torsoNx1 = torsoNx1
              ..torsoNy1 = torsoNy1
              ..torsoSignature = torsoSig
              ..headSignature = headSig
              ..lastDirectFaceSec = timeSec
              ..foregroundRatio = fgRatio;
            tracks[created.id] = created;
            present.add(created);
            created.lastMoveDelta = 0;
            _updateLipActivity(
              created,
              face,
              box,
              contourFace: contourFace,
              audio: audioFrame,
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
              FaceTrackPoint(
                timeSec: timeSec,
                normX: cx,
                normY: cy,
                normW: fw,
                normH: fh,
                speakerId: created.id,
              ),
            );
            continue;
          }

          final moveDelta = sqrt(
            (cx - track.normX) * (cx - track.normX) +
                (cy - track.normY) * (cy - track.normY),
          );
          track.lastMoveDelta = moveDelta;
          track.isSilhouette = false;
          track.lastDirectFaceSec = timeSec;
          track.foregroundRatio = 0.6 * track.foregroundRatio + 0.4 * fgRatio;
          track.torsoNx0 = torsoNx0;
          track.torsoNy0 = torsoNy0;
          track.torsoNx1 = torsoNx1;
          track.torsoNy1 = torsoNy1;
          if (torsoSig != null) {
            track.torsoSignature = _blendSignatures(
              track.torsoSignature,
              torsoSig,
              0.25,
            );
          }
          if (headSig != null) {
            track.headSignature = _blendSignatures(
              track.headSignature,
              headSig,
              0.25,
            );
          }

          _updateLipActivity(
            track,
            face,
            box,
            contourFace: contourFace,
            audio: audioFrame,
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
            FaceTrackPoint(
              timeSec: timeSec,
              normX: cx,
              normY: cy,
              normW: fw,
              normH: fh,
              isSpeaking: track.speakingFrames >= 1,
              speakerId: track.id,
            ),
          );
          present.add(track);
        }

        if (!cut && mouthGrid != null) {
          for (final track in tracks.values) {
            if (track.isSilhouette || present.contains(track)) continue;
            final unseenFor = timeSec - track.lastDirectFaceSec;
            if (unseenFor <= 0 || unseenFor > 1.6 || track.hits < 2) continue;
            final coasted = _coastUnseenTrackViaTorso(
              track: track,
              mouthGrid: mouthGrid,
              gridW: mouthGridWidth,
              gridH: mouthGridHeight,
              presentTracks: present,
            );
            if (coasted != null) {
              track.currentFrameVoiced = audioFrame.isVoicedSpeech;
              track.currentFrameVoiceCluster = audioFrame.voiceClusterId;
              if (audioFrame.isVoicedSpeech &&
                  track.currentVoiceMatchBonus >= 0.30) {
                track.lastSpokeSec = timeSec;
                track.silentFrames = 0;
              } else {
                track.silentFrames++;
              }
              _updateTrack(
                track,
                timeSec,
                coasted.cx,
                coasted.cy,
                track.normW,
                track.normH,
              );
              track.points.add(
                FaceTrackPoint(
                  timeSec: timeSec,
                  normX: coasted.cx,
                  normY: coasted.cy,
                  normW: track.normW,
                  normH: track.normH,
                  isSpeaking: track.speakingFrames >= 1 ||
                      track.currentVoiceMatchBonus >= 0.30,
                  speakerId: track.id,
                ),
              );
              present.add(track);
            }
          }
        }

        _updateVoiceClusterBindings(present, audioFrame);

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
              normW: subject.normW,
              normH: subject.normH,
              isSpeaking: true,
              speakerId: subjectTrack.id,
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
          audio: audioFrame,
        );

        if (currentSpeaker != null && present.contains(currentSpeaker)) {
          lastX = currentSpeaker.normX;
          lastY = currentSpeaker.normY;
          lastW = currentSpeaker.normW;
          lastH = currentSpeaker.normH;

          final confirmedNow = (!currentSpeaker.isSilhouette &&
                  (currentSpeaker.speakingFrames >= 1 &&
                          currentSpeaker.recentActivity >= 0.013 ||
                      currentSpeaker.currentVoiceMatchBonus >= 0.35)) ||
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
                var bw = currentSpeaker.normW;
                var bh = currentSpeaker.normH;
                var bestDt = double.infinity;
                for (final pt in currentSpeaker.points) {
                  final dt = (pt.timeSec - tK).abs();
                  if (dt < bestDt && dt <= 2.6) {
                    bestDt = dt;
                    bx = pt.normX;
                    by = pt.normY;
                    bw = pt.normW;
                    bh = pt.normH;
                  }
                }
                activePoints[k] = FaceTrackPoint(
                  timeSec: tK,
                  normX: bx,
                  normY: by,
                  normW: bw,
                  normH: bh,
                  isSpeaking: true,
                  speakerId: currentSpeaker.id,
                  isCut: activePoints[k].isCut,
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
            normW: lastW,
            normH: lastH,
            isSpeaking: currentSpeaker != null &&
                (currentSpeaker.speakingFrames >= 1 ||
                    currentSpeaker.currentVoiceMatchBonus >= 0.30),
            speakerId: currentSpeaker?.id,
            isCut: cut && activePoints.isNotEmpty,
          ),
        );

        if (i % 6 == 0 || i == frames.length - 1) {
          onProgress?.call(
            0.16 + 0.78 * ((i + 1) / frames.length),
            '👄 المرحلة 3/3: تحليل الشفاه وربط الصوت بالمتكلم (${i + 1}/${frames.length})...',
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

      onProgress?.call(1.0, '✅ اكتمل تتبع المتكلم والبصمة الصوتية');
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
      await cropContourDetector.close();
      try {
        if (await framesDir.exists()) {
          await framesDir.delete(recursive: true);
        }
      } catch (e) {
        AppLogger().e('FaceTrack: could not clean analysis frames', e);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Layer 2 Helpers: Multi-Face Crop Contour & High-Res Inner-Lip Aperture
  // ---------------------------------------------------------------------------

  static Future<Face?> _detectContoursOnFaceCrop({
    required FaceDetector cropContourDetector,
    required Uint8List fullRgba,
    required int fullW,
    required int fullH,
    required ui.Rect faceBox,
    required String cropBmpPath,
  }) async {
    try {
      final padX = faceBox.width * 0.22;
      final padY = faceBox.height * 0.22;
      final x0 = (faceBox.left - padX).floor().clamp(0, fullW - 2);
      final y0 = (faceBox.top - padY).floor().clamp(0, fullH - 2);
      final x1 = (faceBox.right + padX).ceil().clamp(x0 + 2, fullW);
      final y1 = (faceBox.bottom + padY).ceil().clamp(y0 + 2, fullH);
      final cw = x1 - x0;
      final ch = y1 - y0;
      if (cw < 36 || ch < 36) return null;

      final bmpBytes = _encodeRgbaCropToBmp(
        fullRgba,
        fullW,
        fullH,
        x0: x0,
        y0: y0,
        cropW: cw,
        cropH: ch,
      );
      final file = File(cropBmpPath);
      await file.writeAsBytes(bmpBytes, flush: false);
      final input = InputImage.fromFilePath(cropBmpPath);
      final croppedFaces = await cropContourDetector.processImage(input);
      if (croppedFaces.isEmpty) return null;
      croppedFaces.sort(
        (a, b) => (b.boundingBox.width * b.boundingBox.height)
            .compareTo(a.boundingBox.width * a.boundingBox.height),
      );
      return croppedFaces.first;
    } catch (_) {
      return null;
    }
  }

  static Uint8List _encodeRgbaCropToBmp(
    Uint8List rgba,
    int srcW,
    int srcH, {
    required int x0,
    required int y0,
    required int cropW,
    required int cropH,
  }) {
    final rowStride = (cropW * 3 + 3) & ~3;
    final pixelDataSize = rowStride * cropH;
    final fileSize = 54 + pixelDataSize;
    final out = Uint8List(fileSize);
    final bd = ByteData.view(out.buffer);

    out[0] = 0x42;
    out[1] = 0x4D;
    bd.setUint32(2, fileSize, Endian.little);
    bd.setUint32(10, 54, Endian.little);

    bd.setUint32(14, 40, Endian.little);
    bd.setInt32(18, cropW, Endian.little);
    bd.setInt32(22, -cropH, Endian.little);
    bd.setUint16(26, 1, Endian.little);
    bd.setUint16(28, 24, Endian.little);
    bd.setUint32(34, pixelDataSize, Endian.little);

    for (var r = 0; r < cropH; r++) {
      final sy = (y0 + r).clamp(0, srcH - 1);
      final srcRow = sy * srcW * 4;
      final dstRow = 54 + r * rowStride;
      for (var c = 0; c < cropW; c++) {
        final sx = (x0 + c).clamp(0, srcW - 1);
        final si = srcRow + sx * 4;
        final di = dstRow + c * 3;
        out[di] = rgba[si + 2];
        out[di + 1] = rgba[si + 1];
        out[di + 2] = rgba[si];
      }
    }
    return out;
  }

  static void _updateVoiceClusterBindings(
    List<_SpeakerTrack> present,
    AudioFrameFeatures audio,
  ) {
    if (!audio.isVoicedSpeech || audio.voiceClusterId < 0 || present.isEmpty) {
      return;
    }
    final clusterId = audio.voiceClusterId;

    _SpeakerTrack? topVisualSpeaker;
    var bestVisual = 0.0;
    var secondVisual = 0.0;

    for (final track in present) {
      if (track.isSilhouette || track.rawVisualDeltas.isEmpty) continue;
      final latestDelta = track.rawVisualDeltas.last;
      final weighted = latestDelta * (0.65 + 0.35 * track.avSyncScore);
      if (weighted > bestVisual) {
        secondVisual = bestVisual;
        bestVisual = weighted;
        topVisualSpeaker = track;
      } else if (weighted > secondVisual) {
        secondVisual = weighted;
      }
    }

    if (topVisualSpeaker != null &&
        bestVisual >= 0.0135 &&
        topVisualSpeaker.avSyncScore >= 0.42 &&
        (present.length == 1 || bestVisual >= secondVisual * 1.45 + 0.004)) {
      final prev = topVisualSpeaker.voiceClusterAffinity[clusterId] ?? 0.0;
      topVisualSpeaker.voiceClusterAffinity[clusterId] = min(10.0, prev + 0.85);
      for (final other in present) {
        if (!identical(other, topVisualSpeaker)) {
          final oPrev = other.voiceClusterAffinity[clusterId] ?? 0.0;
          if (oPrev > 0) {
            other.voiceClusterAffinity[clusterId] = max(0.0, oPrev - 0.25);
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Layer 3 Helpers: Upper-Body Appearance Signature & Torso Coasting
  // ---------------------------------------------------------------------------

  static Float64List? _extractRegionSignature(
    Uint8List grid,
    int gridW,
    int gridH,
    double nx0,
    double ny0,
    double nx1,
    double ny1,
  ) {
    if (nx1 <= nx0 + 0.015 || ny1 <= ny0 + 0.015) return null;
    final sig = Float64List(12);
    for (var qy = 0; qy < 2; qy++) {
      for (var qx = 0; qx < 2; qx++) {
        var rSum = 0.0;
        var gSum = 0.0;
        var bSum = 0.0;
        const subN = 3;
        for (var sy = 0; sy < subN; sy++) {
          for (var sx = 0; sx < subN; sx++) {
            final u = (qx + (sx + 0.5) / subN) * 0.5;
            final v = (qy + (sy + 0.5) / subN) * 0.5;
            final gx = ((nx0 + (nx1 - nx0) * u) * (gridW - 1))
                .round()
                .clamp(0, gridW - 1);
            final gy = ((ny0 + (ny1 - ny0) * v) * (gridH - 1))
                .round()
                .clamp(0, gridH - 1);
            final o = (gy * gridW + gx) * 4;
            rSum += grid[o] / 255.0;
            gSum += grid[o + 1] / 255.0;
            bSum += grid[o + 2] / 255.0;
          }
        }
        final baseIdx = (qy * 2 + qx) * 3;
        const count = subN * subN;
        sig[baseIdx] = rSum / count;
        sig[baseIdx + 1] = gSum / count;
        sig[baseIdx + 2] = bSum / count;
      }
    }
    var norm = 0.0;
    for (var i = 0; i < sig.length; i++) {
      norm += sig[i] * sig[i];
    }
    norm = sqrt(norm);
    if (norm < 1e-6) return null;
    for (var i = 0; i < sig.length; i++) {
      sig[i] /= norm;
    }
    return sig;
  }

  static Float64List _blendSignatures(
    Float64List? oldSig,
    Float64List newSig,
    double alpha,
  ) {
    if (oldSig == null || oldSig.length != newSig.length) return newSig;
    final out = Float64List(newSig.length);
    var norm = 0.0;
    for (var i = 0; i < out.length; i++) {
      out[i] = (1 - alpha) * oldSig[i] + alpha * newSig[i];
      norm += out[i] * out[i];
    }
    norm = sqrt(norm);
    if (norm > 1e-6) {
      for (var i = 0; i < out.length; i++) {
        out[i] /= norm;
      }
    }
    return out;
  }

  static double _signatureSimilarity(Float64List? a, Float64List? b) {
    if (a == null || b == null || a.length != b.length) return 0.0;
    var dot = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot.clamp(0.0, 1.0);
  }

  static ({double cx, double cy})? _coastUnseenTrackViaTorso({
    required _SpeakerTrack track,
    required Uint8List mouthGrid,
    required int gridW,
    required int gridH,
    required List<_SpeakerTrack> presentTracks,
  }) {
    final targetTorsoSig = track.torsoSignature;
    if (targetTorsoSig == null) return null;

    for (final other in presentTracks) {
      if ((other.normX - track.normX).abs() < 0.10 &&
          (other.normY - track.normY).abs() < 0.10) {
        return null;
      }
    }

    final tw = track.torsoNx1 - track.torsoNx0;
    final th = track.torsoNy1 - track.torsoNy0;
    if (tw <= 0.03 || th <= 0.03) return null;

    const offsets = <double>[-0.04, -0.02, 0.0, 0.02, 0.04];
    var bestSim = 0.0;
    var bestDx = 0.0;
    var bestDy = 0.0;

    for (final dy in offsets) {
      for (final dx in offsets) {
        final tx0 = (track.torsoNx0 + dx).clamp(0.0, 1.0 - tw);
        final ty0 = (track.torsoNy0 + dy).clamp(0.0, 1.0 - th);
        final candSig = _extractRegionSignature(
          mouthGrid,
          gridW,
          gridH,
          tx0,
          ty0,
          tx0 + tw,
          ty0 + th,
        );
        final sim = _signatureSimilarity(targetTorsoSig, candSig);
        if (sim > bestSim) {
          bestSim = sim;
          bestDx = dx;
          bestDy = dy;
        }
      }
    }

    if (bestSim < 0.90) return null;
    final newCx = (track.normX + bestDx * 0.75).clamp(0.05, 0.95);
    final newCy = (track.normY + bestDy * 0.75).clamp(0.08, 0.92);
    track.torsoNx0 = (track.torsoNx0 + bestDx * 0.75).clamp(0.0, 1.0 - tw);
    track.torsoNx1 = track.torsoNx0 + tw;
    track.torsoNy0 = (track.torsoNy0 + bestDy * 0.75).clamp(0.0, 1.0 - th);
    track.torsoNy1 = track.torsoNy0 + th;
    return (cx: newCx, cy: newCy);
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
      shots.add(
        SceneShot(id: 0, startSec: startSec, endSec: max(startSec + 0.1, endSec)),
      );
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
  static const double shotSteadyTolerance = 0.008;

  static Future<
      ({
        Uint8List silhouetteGrid,
        Uint8List mouthGrid,
        Uint8List fullRgba,
        int fullW,
        int fullH,
      })?> _decodeAnalysisGrids(String path) async {
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
        return (
          silhouetteGrid: silGrid,
          mouthGrid: mouthGrid,
          fullRgba: src,
          fullW: srcW,
          fullH: srcH,
        );
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
  // Lip activity + Multi-Face Inner-Lip Contours + Audio-Visual Fusion
  // ---------------------------------------------------------------------------

  static void _updateLipActivity(
    _SpeakerTrack track,
    Face face,
    ui.Rect box, {
    required Face? contourFace,
    required AudioFrameFeatures audio,
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
    final stabW =
        hasPrev && track.normW > 0 ? 0.68 * track.normW + 0.32 * fw : fw;
    final stabH =
        hasPrev && track.normH > 0 ? 0.68 * track.normH + 0.32 * fh : fh;

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

    final resScale = (fh / 0.14).clamp(0.35, 1.0);

    final contourOpen = _extractInnerLipContourMar(contourFace ?? face);
    var contourDelta = 0.0;
    if (contourOpen != null) {
      final prevContourOpen = track.lastContourInnerOpen;
      if (hasPrev && prevContourOpen != null) {
        final dContour = max(0.0, (contourOpen - prevContourOpen).abs() - 0.006);
        contourDelta = dContour * 3.4 * resScale;
      }
      track.lastContourInnerOpen = contourOpen;
    }

    final metrics = _lipMetrics(contourFace ?? face, box);
    final open = contourOpen ?? metrics.$1;
    final width = metrics.$2;
    var geomDelta = 0.0;
    if (open != null) {
      final previous = track.lastOpen;
      if (hasPrev && previous != null) {
        final dOpen = max(0.0, (open - previous).abs() - 0.0085);
        geomDelta += dOpen * 2.3 * resScale;
      }
      track.lastOpen = open;
    }
    if (width != null) {
      final previous = track.lastWidth;
      if (hasPrev && previous != null) {
        final dWidth = max(0.0, (width - previous).abs() - 0.009);
        geomDelta += dWidth * 1.3 * resScale;
      }
      track.lastWidth = width;
    }

    final headYawDeg = face.headEulerAngleY ?? 0.0;
    var pixelDelta = 0.0;
    var oralOpen = open ?? 0.0;

    if (currGrid != null && currGrid.length >= gridW * gridH * 4) {
      final currContrast = _mouthToCheekContrast(
        currGrid,
        gridW,
        gridH,
        nx0: stabNx0,
        ny0: stabNy0,
        nx1: stabNx1,
        ny1: stabNy1,
        headYawDeg: headYawDeg,
      );
      final prevContrast = track.lastMouthContrast;
      track.lastMouthContrast = currContrast;

      final currOralCavity = computeInnerLipAperture(
        currGrid,
        gridW,
        gridH,
        nx0: stabNx0,
        ny0: stabNy0,
        nx1: stabNx1,
        ny1: stabNy1,
        headYawDeg: headYawDeg,
      );
      final prevOralCavity = track.lastOralCavityOpen;
      track.lastOralCavityOpen = currOralCavity;
      if (contourOpen == null) {
        oralOpen = currOralCavity;
      }

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
            ? max(0.0, (currContrast - prevContrast).abs() - 0.0085)
            : 0.0;
        final oralDelta = prevOralCavity != null
            ? max(0.0, (currOralCavity - prevOralCavity).abs() - 0.007)
            : 0.0;
        pixelDelta =
            (regionDelta * 3.8 + contrastDelta * 1.8 + oralDelta * 2.6) *
                resScale;
      }
    }

    track
      ..stabNx0 = stabNx0
      ..stabNy0 = stabNy0
      ..stabNx1 = stabNx1
      ..stabNy1 = stabNy1;

    final rawVisualDelta = contourOpen != null
        ? (contourDelta * 0.60 + geomDelta * 0.15 + pixelDelta * 0.55)
        : (geomDelta + pixelDelta);

    track.recordSpeechSample(
      rawVisualDelta,
      lipOpen: oralOpen,
      audio: audio,
      nowSec: nowSec,
      window: lipWindow,
    );
  }

  static double? _extractInnerLipContourMar(Face face) {
    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;
    if (upper == null ||
        upper.length < 3 ||
        lower == null ||
        lower.length < 3) {
      return null;
    }

    final mouthW = (upper.last.x - upper.first.x).abs().toDouble();
    final normWidth = max(mouthW, face.boundingBox.width * 0.25);
    if (normWidth <= 1.0) return null;

    final uStart = upper.length ~/ 4;
    final uEnd = max(uStart + 1, upper.length - uStart);
    var uSumY = 0.0;
    for (var i = uStart; i < uEnd; i++) {
      uSumY += upper[i].y;
    }
    final uMidY = uSumY / (uEnd - uStart);

    final lStart = lower.length ~/ 4;
    final lEnd = max(lStart + 1, lower.length - lStart);
    var lSumY = 0.0;
    for (var i = lStart; i < lEnd; i++) {
      lSumY += lower[i].y;
    }
    final lMidY = lSumY / (lEnd - lStart);

    return ((lMidY - uMidY).abs() / normWidth).clamp(0.0, 0.85);
  }

  static double computeInnerLipAperture(
    Uint8List grid,
    int gridW,
    int gridH, {
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    double headYawDeg = 0.0,
  }) {
    final fw = nx1 - nx0;
    final fh = ny1 - ny0;
    if (fw <= 0 || fh <= 0) return 0.0;

    final yawShift = (-headYawDeg / 60.0).clamp(-0.18, 0.18);
    final mx0 = (nx0 + fw * (0.32 + yawShift)).clamp(0.0, 1.0);
    final mx1 = (nx0 + fw * (0.68 + yawShift)).clamp(mx0 + 0.01, 1.0);
    final my0 = (ny0 + fh * 0.62).clamp(0.0, 1.0);
    final my1 = (ny0 + fh * 0.84).clamp(my0 + 0.01, 1.0);

    const rows = 7;
    const cols = 5;
    final rowLumas = List<double>.filled(rows, 0.0);
    for (var r = 0; r < rows; r++) {
      final ty = my0 + (my1 - my0) * (r + 0.5) / rows;
      var sum = 0.0;
      for (var c = 0; c < cols; c++) {
        final tx = mx0 + (mx1 - mx0) * (c + 0.5) / cols;
        sum += _sampleLumaBilinear(grid, gridW, gridH, tx, ty);
      }
      rowLumas[r] = sum / cols;
    }

    final outerRef = (rowLumas.first + rowLumas.last) * 0.5;
    var minInner = rowLumas[2];
    for (var r = 2; r <= 4; r++) {
      if (rowLumas[r] < minInner) minInner = rowLumas[r];
    }
    return (max(0.0, outerRef - minInner) / 255.0).clamp(0.0, 0.5);
  }

  static double _mouthToCheekContrast(
    Uint8List grid,
    int gridW,
    int gridH, {
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    double headYawDeg = 0.0,
  }) {
    final fw = nx1 - nx0;
    final fh = ny1 - ny0;
    if (fw <= 0 || fh <= 0) return 0;
    final yawShift = (-headYawDeg / 60.0).clamp(-0.15, 0.15);
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
          (nx0 + fw * (0.28 + 0.44 * u + yawShift * 0.5)).clamp(0.0, 1.0),
          ny0 + fh * (0.24 + 0.20 * v),
        );
        mouthSum += _sampleLumaBilinear(
          grid,
          gridW,
          gridH,
          (nx0 + fw * (0.34 + 0.32 * u + yawShift)).clamp(0.0, 1.0),
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
            final currLuma =
                _sampleLumaBilinear(currGrid, gridW, gridH, tx, ty);
            final prevLuma =
                _sampleLumaBilinear(prevGrid, gridW, gridH, px, py);
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
    Float64List? torsoSig,
    Float64List? headSig,
    required bool allowExisting,
  }) {
    if (!allowExisting) return null;

    _SpeakerTrack? best;
    var bestScore = minFaceOverlap;
    for (final track in tracks.values) {
      if (track.isSilhouette) continue;
      if (track.lastSeenSec == nowSec) continue;
      if (nowSec - track.lastSeenSec > 2.8) continue;
      final iou = _boxOverlap(track, nx0, ny0, nx1, ny1);
      if (iou <= 0) continue;
      final torsoSim = _signatureSimilarity(track.torsoSignature, torsoSig);
      final combined = iou + (torsoSim > 0.75 ? 0.12 * torsoSim : 0.0);
      if (combined > bestScore) {
        bestScore = combined;
        best = track;
      }
    }
    if (best != null) return best;

    _SpeakerTrack? nearest;
    var bestDistance = associationDistance;
    for (final track in tracks.values) {
      if (track.isSilhouette) continue;
      if (track.lastSeenSec == nowSec) continue;
      final unseen = nowSec - track.lastSeenSec;
      if (unseen > 6.5) continue;
      final dx = track.normX - cx;
      final dy = track.normY - cy;
      final distance = sqrt(dx * dx + dy * dy);
      final torsoSim = _signatureSimilarity(track.torsoSignature, torsoSig);
      final headSim = _signatureSimilarity(track.headSignature, headSig);
      final appSim = 0.65 * torsoSim + 0.35 * headSim;

      final effectiveDist =
          appSim >= 0.85 ? distance * 0.68 : (unseen <= 2.5 ? distance : 99.0);
      if (effectiveDist < bestDistance) {
        bestDistance = effectiveDist;
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
    required AudioFrameFeatures audio,
  }) {
    if (present.isEmpty) return null;
    if (present.length == 1) {
      final only = present.first;
      only.lockStartSec ??= nowSec;
      return only;
    }

    if (current != null && present.contains(current)) {
      current.lockStartSec ??= nowSec;
      if (!audio.isVoicedSpeech) {
        return current;
      }

      final lockedFor = nowSec - (current.lockStartSec ?? nowSec);
      final sinceCurrentSpoke = nowSec - current.lastSpokeSec;
      var best = current;
      for (final candidate in present) {
        if (candidate.score > best.score) best = candidate;
      }
      if (!identical(best, current)) {
        final bestHasVoiceLock = best.currentVoiceMatchBonus >= 0.45 &&
            best.currentVoiceMatchBonus > current.currentVoiceMatchBonus + 0.25;
        final bestConfirmed = (!best.isSilhouette &&
                ((best.speakingFrames >= 2 && best.recentActivity >= 0.014) ||
                    (bestHasVoiceLock && best.speakingFrames >= 1))) ||
            (best.isSilhouette && best.silhouetteActivity >= 0.045);

        final currentNeverSpoke = !current.isSilhouette &&
            current.lastSpokeSec < 0 &&
            current.speakingFrames == 0;
        final bestStartedSpeaking = (!best.isSilhouette &&
                (best.speakingFrames >= 1 && best.recentActivity >= 0.013 ||
                    bestHasVoiceLock)) ||
            (best.isSilhouette && best.silhouetteActivity >= 0.045);

        if (currentNeverSpoke && bestStartedSpeaking) {
          best.lockStartSec = nowSec;
          return best;
        }
        final currentPaused =
            sinceCurrentSpoke >= 1.1 || current.silentFrames >= 5;
        if (bestConfirmed &&
            ((currentPaused && best.score > current.score * 1.18 + 0.010) ||
                (bestHasVoiceLock &&
                    lockedFor >= 0.85 &&
                    best.score > current.score * 1.22) ||
                (lockedFor >= speakerLockSeconds &&
                    best.score > current.score * 1.42 + 0.015))) {
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
  static const double profileMergeDistance = 0.17;

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
        final sameSilhouette = group.first.isSilhouette == track.isSilhouette;
        final closeX = (trackX - avgXOf(group)).abs() < profileMergeDistance;
        final torsoSim = _signatureSimilarity(
          group.first.torsoSignature,
          track.torsoSignature,
        );
        if (sameSilhouette && (closeX || torsoSim >= 0.88)) {
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
      var totalHits = 0;
      var totalSpeakingHits = 0;
      int? dominantVoice;
      for (final track in kept[i]) {
        totalHits += track.hits;
        totalSpeakingHits += track.speakingHitCount;
        dominantVoice ??= track.dominantVoiceClusterId;
        for (final p in track.points) {
          points.add(p.copyWith(speakerId: i));
        }
      }
      points.sort((a, b) => a.timeSec.compareTo(b.timeSec));
      var xTotal = 0.0;
      var yTotal = 0.0;
      var wTotal = 0.0;
      var hTotal = 0.0;
      for (final point in points) {
        xTotal += point.normX;
        yTotal += point.normY;
        wTotal += point.normW;
        hTotal += point.normH;
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
      final nPts = max(1, points.length);
      profiles.add(
        DetectedSpeakerProfile(
          id: i,
          label: label,
          avgNormX: xTotal / nPts,
          avgNormY: yTotal / nPts,
          avgNormW: wTotal / nPts,
          avgNormH: hTotal / nPts,
          boundVoiceClusterId: dominantVoice,
          speakingRatio: totalHits > 0
              ? (totalSpeakingHits / totalHits).clamp(0.0, 1.0)
              : 0.0,
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
            .where((p) =>
                p.timeSec >= shot.startSec - 1e-3 &&
                p.timeSec <= shot.endSec + 1e-3)
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
          .where((p) =>
              p.timeSec >= startSec - 1e-3 && p.timeSec <= endSec + 1e-3)
          .toList();
    }
    final inShot = profile.rawPoints
        .where(
            (p) => p.timeSec >= startSec - 1e-3 && p.timeSec <= endSec + 1e-3)
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
            normW: inShot.first.normW,
            normH: inShot.first.normH,
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
            normW: inShot.last.normW,
            normH: inShot.last.normH,
          ),
        );
      }
      return result;
    }

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
      FaceTrackPoint(
        timeSec: startSec,
        normX: nearest.normX,
        normY: nearest.normY,
        normW: nearest.normW,
        normH: nearest.normH,
      ),
      if (endSec > startSec + 0.1)
        FaceTrackPoint(
          timeSec: max(startSec + 0.05, endSec - 0.08),
          normX: nearest.normX,
          normY: nearest.normY,
          normW: nearest.normW,
          normH: nearest.normH,
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

  static const double manualKeyframeToleranceSec = 0.12;

  static bool isEffectiveCut(FaceTrackPoint a, FaceTrackPoint b) {
    if (b.isCut) return true;
    if (b.isManual) return false;
    if (b.timeSec - a.timeSec <= 0.005) return true;
    return false;
  }

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
          normW: point.normW,
          normH: point.normH,
          isSpeaking: point.isSpeaking,
          speakerId: point.speakerId,
          isCut: point.isCut,
          isManual: point.isManual,
        );
        continue;
      }
      cleaned.add(point);
    }
    return List<FaceTrackPoint>.unmodifiable(cleaned);
  }

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

      if (!kf.isManual &&
          prevManualIdx >= 0 &&
          i > prevManualIdx &&
          i < manualIndex) {
        continue;
      }
      if (!kf.isManual &&
          nextManualIdx >= 0 &&
          i > manualIndex &&
          i < nextManualIdx) {
        continue;
      }
      if (!kf.isManual && i > 0 && (kf.timeSec - targetTime).abs() <= 0.45) {
        continue;
      }

      if (passedManual && !hitBoundaryAfterManual) {
        if (kf.isManual) {
          hitBoundaryAfterManual = true;
        } else if (kf.isCut && (kf.timeSec - targetTime) > 1.5) {
          hitBoundaryAfterManual = true;
        } else if (!kf.isManual && (kf.timeSec - targetTime) <= 4.0) {
          continue;
        }
      }

      if (out.isNotEmpty && out.last.isManual && !kf.isManual && kf.isCut) {
        out.add(kf.copyWith(isCut: false));
      } else {
        out.add(kf);
      }
    }
    return out.isEmpty ? [keyframes[manualIndex]] : out;
  }

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
      if (rawPoints[i].isCut ||
          dx >= threshold ||
          dy >= threshold ||
          gap > 1.5) {
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
        FaceTrackPoint(
          timeSec: point.timeSec,
          normX: anchorX,
          normY: anchorY,
          normW: point.normW,
          normH: point.normH,
          isSpeaking: point.isSpeaking,
          speakerId: point.speakerId,
        ),
      );
    }

    final alpha = smoothness.clamp(0.01, 1.0);
    final forward = List<FaceTrackPoint>.from(anchored);
    for (var i = 1; i < forward.length; i++) {
      forward[i] = anchored[i].copyWith(
        normX: alpha * anchored[i].normX + (1 - alpha) * forward[i - 1].normX,
        normY: alpha * anchored[i].normY + (1 - alpha) * forward[i - 1].normY,
      );
    }
    final smoothed = List<FaceTrackPoint>.from(forward);
    for (var i = forward.length - 2; i >= 0; i--) {
      smoothed[i] = forward[i].copyWith(
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
