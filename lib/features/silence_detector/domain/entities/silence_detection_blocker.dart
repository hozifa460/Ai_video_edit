import 'media_timeline.dart';

/// Why silence detection cannot run on a probed timeline.
///
/// The presentation layer and the detection repository used to decide this
/// independently: the screen tested `isDetectable` and wrote its own message,
/// while the repository wrote a different one from a different set of
/// conditions. A file with a valid duration and an audio stream but no overlap
/// therefore reached the user as "no duration or no audio track" (B01-F2), and
/// the repository reported "no overlap" for a file that simply had no readable
/// duration.
///
/// One ordered contract fixes both: the first matching blocker wins, and both
/// layers render [messageFor] of the same value.
enum SilenceDetectionBlocker {
  /// FFprobe produced no usable video duration.
  unusableMediaDuration,

  /// The file carries no audio stream, so there is nothing to analyse.
  missingAudioTrack,

  /// Audio exists and its duration is fine, but the audio window never meets the
  /// video window. Refusing is correct here: there is no audio synchronised with
  /// picture for the detector to judge, and inventing a window would produce a
  /// plausible-looking edit over the wrong material.
  noAudioVideoOverlap,
}

/// Shared gate in front of silence detection.
class SilenceDetectionGate {
  SilenceDetectionGate._();

  /// The first reason [timeline] cannot be analysed, or `null` when it can.
  ///
  /// The order is fixed and part of the contract: duration, then audio track,
  /// then overlap. Checking overlap before duration would report "no overlap"
  /// for a file whose duration simply could not be read.
  static SilenceDetectionBlocker? blockerFor(MediaTimeline timeline) {
    if (timeline.videoDurationSeconds <= 0) {
      return SilenceDetectionBlocker.unusableMediaDuration;
    }
    if (!timeline.hasAudio) {
      return SilenceDetectionBlocker.missingAudioTrack;
    }
    if (!timeline.hasDetectionWindow) {
      return SilenceDetectionBlocker.noAudioVideoOverlap;
    }
    return null;
  }

  /// Convenience for callers that only need a yes/no.
  static bool canDetect(MediaTimeline timeline) => blockerFor(timeline) == null;

  /// User-facing text for [blocker].
  ///
  /// The screen shows this verbatim and the repository returns it inside a
  /// `SilenceDetectionFailure`, so the reason a user reads cannot drift from the
  /// reason the pipeline recorded.
  static String messageFor(SilenceDetectionBlocker blocker) {
    switch (blocker) {
      case SilenceDetectionBlocker.unusableMediaDuration:
        return 'This file has no readable duration, so nothing can be cut';
      case SilenceDetectionBlocker.missingAudioTrack:
        return 'This file has no audio track to analyse';
      case SilenceDetectionBlocker.noAudioVideoOverlap:
        return 'The audio does not overlap the video, so there is no speech '
            'synchronised with picture to analyse';
    }
  }
}
