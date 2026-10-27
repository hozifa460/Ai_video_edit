import 'package:equatable/equatable.dart';
import '../services/interval_algebra.dart';
import 'silence_segment.dart';

/// Probed timing for one source file, expressed on the **video timeline**.
///
/// ## Time origin
///
/// The video timeline is the only timeline a cut can be expressed on, and its
/// zero is the video stream's own `start_time` as reported by FFprobe — which
/// is frequently *not* zero (a trimmed or concatenated file commonly starts at
/// 5s, or at 12s). Detection runs on the extracted WAV, whose zero is the
/// *audio* stream's `start_time`. `audioStartSeconds` is therefore the **signed,
/// relative** offset `audio.start_time - video.start_time`, not the absolute
/// audio timestamp (B01-R1):
///
/// * audio and video sharing a non-zero origin ⇒ offset `0`
/// * audio starting 0.5s *before* video ⇒ offset `-0.5`
/// * audio starting 0.5s *after* video ⇒ offset `+0.5`
/// * a video starting at 12s with audio starting at 0 ⇒ offset `-12`, even
///   though the video itself is only 10s long
///
/// Negative values are meaningful and are never erased. A clip that starts on
/// audio has its first frames inside the audio's own pre-roll, and dropping that
/// negative offset moved cuts half a second to the right.
///
/// **The offset is a measurement, not a duration, so it is never rescaled to
/// fit the video.** Clamping it to `±videoDurationSeconds` silently re-dated
/// every interval in files whose audio sits entirely outside the video's own
/// span. What is clipped is the *result* of the conversion — see
/// `detectionWindow()` and `audioToVideoTimeline()`.
///
/// ## Conversion direction
///
/// `videoTime = audioTime + audioStartSeconds`. Detection works on the audio
/// timeline, so converting a detected interval **adds** the offset. Subtracting
/// it would move cuts the wrong way. `audioTimeToVideoTime` and
/// `videoToAudioTimeline` are the two directions of the same single rule.
///
/// ## Contract shared with extraction, detection and cutting
///
/// `AudioProcessorRepositoryImpl.extractAudio` is expected to decode the same
/// audio stream without resetting timestamps, so the WAV's t=0 would be the
/// audio origin, and the cut's `trim`/`atrim` read the original file, whose
/// origin is the video's. If that expectation holds, all three stages agree and
/// the offset above is exactly the difference between their t=0 values.
///
/// **This is an intended contract, not a verified one.** The extraction and cut
/// commands were not changed and have not been executed on media here, and this
/// timeline stores only the *difference* of the two origins, not the absolute
/// audio origin it would take to re-derive them. Timestamp policy (missing
/// metadata, decoder priming, `-copyts`) and implicit audio-stream selection
/// (SR-23) are unmeasured. Agreement must still be measured on real media before
/// it can be claimed.
///
/// Nothing here is derived from waveform analysis. A waveform is display-only:
/// when waveform extraction fails the probed values remain authoritative.
class MediaTimeline extends Equatable {
  /// Length of the video timeline in seconds (video stream duration when
  /// available, otherwise container duration). Never negative or non-finite.
  final double videoDurationSeconds;

  /// **Signed** offset from the video origin to the audio origin, in seconds.
  /// Negative when the audio starts before the video. Preserved exactly as
  /// measured; never clamped to the video duration.
  final double audioStartSeconds;

  /// Duration of the audio stream in seconds, or `0` when unknown.
  final double audioDurationSeconds;

  final bool hasAudio;

  const MediaTimeline({
    required this.videoDurationSeconds,
    this.audioStartSeconds = 0,
    this.audioDurationSeconds = 0,
    this.hasAudio = true,
  });

  /// Sanitizing factory.
  ///
  /// The *durations* are collapsed to `0` when unusable, because an unusable
  /// length cannot describe a window. The offset is different: only a
  /// non-finite value falls back to `0` (unknown or unparsable), and any finite
  /// value is kept with its sign and magnitude. Clamping a finite offset to the
  /// video length is not a fallback, it is a corruption (B01-R1 follow-up).
  factory MediaTimeline.probed({
    required double videoDurationSeconds,
    double audioStartSeconds = 0,
    double audioDurationSeconds = 0,
    bool hasAudio = true,
  }) {
    return MediaTimeline(
      videoDurationSeconds: IntervalAlgebra.nonNegativeOrZero(
        videoDurationSeconds,
      ),
      audioStartSeconds: IntervalAlgebra.finiteOr(audioStartSeconds),
      audioDurationSeconds: IntervalAlgebra.nonNegativeOrZero(
        audioDurationSeconds,
      ),
      hasAudio: hasAudio,
    );
  }

  /// A timeline with no usable length. Detection and cutting must not proceed
  /// on this; callers surface an explicit error instead of silently planning a
  /// zero-length edit.
  static const MediaTimeline unknown = MediaTimeline(
    videoDurationSeconds: 0,
    audioStartSeconds: 0,
    audioDurationSeconds: 0,
    hasAudio: false,
  );

  /// The part of the detected-audio window that actually lands on the video,
  /// expressed in **audio-timeline** seconds — the bound detection results must
  /// respect.
  ///
  /// The audio window starts at the audio origin (`0`, the extracted WAV's t=0)
  /// and ends at the measured audio duration, or at the video's end when that
  /// duration is unknown. Both ends are then intersected with the video window.
  ///
  /// Returns `null` when there is **no overlap at all** — audio that finishes
  /// before the video starts, or begins after the video ends. That is a real,
  /// empty intersection, not an error and not a reason to invent a substitute
  /// origin. Callers must surface it instead of shifting anything.
  ({double startSeconds, double endSeconds})? detectionWindow() {
    if (videoDurationSeconds <= 0) return null;

    final audioEnd = audioDurationSeconds > 0
        ? audioDurationSeconds
        : videoDurationSeconds - audioStartSeconds;
    if (!audioEnd.isFinite || audioEnd <= 0) return null;

    // Audio window on the video timeline, then intersect with [0, videoLength].
    final videoWindowStart = audioStartSeconds;
    final videoWindowEnd = audioEnd + audioStartSeconds;
    final low = videoWindowStart > 0 ? videoWindowStart : 0.0;
    final high = videoWindowEnd < videoDurationSeconds
        ? videoWindowEnd
        : videoDurationSeconds;
    if (high <= low) return null;

    // Back to audio-timeline seconds so callers keep working in detection units.
    return (
      startSeconds: low - audioStartSeconds,
      endSeconds: high - audioStartSeconds,
    );
  }

  /// End of [detectionWindow] in audio-timeline seconds, or `0` when there is no
  /// overlap. Never negative.
  double get detectionWindowEndSeconds => detectionWindow()?.endSeconds ?? 0;

  /// Start of [detectionWindow] in audio-timeline seconds, or `0` when there is
  /// no overlap. Never negative: audio before the video's own start cannot be
  /// detected against a picture that does not exist.
  double get detectionWindowStartSeconds =>
      detectionWindow()?.startSeconds ?? 0;

  /// True when detection has any audio window to work with on the video
  /// timeline. When false, [buildRemovalPlan] must refuse rather than plan an
  /// empty or invented edit.
  bool get hasDetectionWindow => detectionWindow() != null;

  /// True when detection and cutting may run: a positive video duration, an
  /// audio stream, and a non-empty audio/video intersection.
  bool get isDetectable =>
      videoDurationSeconds > 0 && hasAudio && hasDetectionWindow;

  MediaTimeline copyWith({
    double? videoDurationSeconds,
    double? audioStartSeconds,
    double? audioDurationSeconds,
    bool? hasAudio,
  }) {
    return MediaTimeline(
      videoDurationSeconds: videoDurationSeconds ?? this.videoDurationSeconds,
      audioStartSeconds: audioStartSeconds ?? this.audioStartSeconds,
      audioDurationSeconds: audioDurationSeconds ?? this.audioDurationSeconds,
      hasAudio: hasAudio ?? this.hasAudio,
    );
  }

  /// Moves intervals detected on the audio timeline onto the video timeline:
  /// `videoTime = audioTime + audioStartSeconds`.
  ///
  /// The shift happens **first** and clipping **after**, so audio beginning
  /// before the video contributes its in-video part instead of being discarded.
  /// An interval that lands entirely outside `[0, videoDurationSeconds]` — audio
  /// that finishes before the video starts, or starts after it ends — is
  /// dropped by normalization rather than clamped onto an edge, so no removal is
  /// invented for media that does not exist.
  List<SilenceSegment> audioToVideoTimeline(List<SilenceSegment> detected) {
    final offset = audioStartSeconds;
    final shifted = detected
        .where((s) => s.hasFiniteBounds)
        .map(
          (s) => SilenceSegment(
            startSeconds: s.startSeconds + offset,
            endSeconds: s.endSeconds + offset,
          ),
        )
        .toList();
    return IntervalAlgebra.normalize(
      shifted,
      totalDuration: videoDurationSeconds,
    );
  }

  /// Moves intervals from the video timeline back onto the audio timeline — the
  /// inverse of [audioToVideoTimeline], subtracting the offset.
  List<SilenceSegment> videoToAudioTimeline(List<SilenceSegment> onVideo) {
    if (audioStartSeconds == 0) return onVideo;
    final shifted = onVideo
        .where((s) => s.hasFiniteBounds)
        .map(
          (s) => SilenceSegment(
            startSeconds: s.startSeconds - audioStartSeconds,
            endSeconds: s.endSeconds - audioStartSeconds,
          ),
        )
        .toList();
    return IntervalAlgebra.normalize(
      shifted,
      totalDuration: detectionWindowEndSeconds,
    );
  }

  /// Maps a point on the audio timeline onto the video timeline
  /// (`video = audio + offset`). Used by the waveform painter so drawn audio
  /// lines up with the removal regions it is compared against (B01-R4).
  double audioTimeToVideoTime(double audioSeconds) =>
      audioSeconds + audioStartSeconds;

  /// The visible slice of the audio window as a range on the **video** timeline,
  /// or `null` when nothing overlaps. Audio outside it has no picture to align
  /// with and is not drawn.
  ({double start, double end})? audioVisibleRange() {
    final window = detectionWindow();
    if (window == null) return null;
    return (
      start: window.startSeconds + audioStartSeconds,
      end: window.endSeconds + audioStartSeconds,
    );
  }

  @override
  List<Object?> get props => [
    videoDurationSeconds,
    audioStartSeconds,
    audioDurationSeconds,
    hasAudio,
  ];
}
