import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/stream_information.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/media_timeline.dart';

/// Probes one source file for the timing the removal plan needs (SR-05).
///
/// The important output is not a duration but a **signed relative offset**: the
/// video stream's `start_time` is the timeline origin, and
/// `audio.start_time - video.start_time` is how far the audio origin sits from
/// it. Treating the absolute audio timestamp as the offset moved every cut by
/// the file's shared origin — `[1,2]` became `[6,7]` on a file whose audio and
/// video both start at 5s (B01-R1).
///
/// Parse failures are contained per field: a missing `start_time` falls back to
/// the container origin and then to `0`, a missing duration degrades to `0`
/// with an explicit error, and a negative `start_time` is preserved because a
/// stream starting before its container is ordinary, not an error.
class MediaProbeDatasource {
  Future<Result<MediaTimeline>> probe(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final mediaInfo = session.getMediaInformation();

      if (mediaInfo == null) {
        AppLogger().e('Media probe returned no information for $path');
        return AppError(
          const CorruptedFileFailure(
            message: 'Could not read media information',
          ),
        );
      }

      final streams = mediaInfo.getStreams();
      StreamInformation? videoStream;
      StreamInformation? audioStream;
      for (final stream in streams) {
        final type = stream.getType();
        if (type == 'video' && videoStream == null) {
          videoStream = stream;
        } else if (type == 'audio' && audioStream == null) {
          audioStream = stream;
        }
      }

      final containerStart =
          parseTimestampSeconds(mediaInfo.getStartTime()) ?? 0;
      final containerDuration = parseDurationSeconds(mediaInfo.getDuration());

      // Origin of the timeline a cut can be expressed on. Falls back to the
      // container origin when the video stream does not report its own.
      final videoOrigin =
          parseTimestampSeconds(videoStream?.getStringProperty('start_time')) ??
          containerStart;

      final videoDuration = parseDurationSeconds(
        videoStream?.getStringProperty('duration'),
      );
      // Prefer the video stream duration: the container value can include a
      // longer audio tail that has no picture, which would inflate the
      // timeline the cut is planned against.
      final resolvedDuration = videoDuration > 0
          ? videoDuration
          : containerDuration;

      if (resolvedDuration <= 0) {
        return AppError(
          const CorruptedFileFailure(message: 'Media has no readable duration'),
        );
      }

      final audioOrigin = parseTimestampSeconds(
        audioStream?.getStringProperty('start_time'),
      );
      final audioDuration = parseDurationSeconds(
        audioStream?.getStringProperty('duration'),
      );

      // Signed difference. `?? videoOrigin` means an audio stream with no
      // reported origin is treated as aligned with the video rather than as
      // absolute zero.
      final relativeAudioOffset = (audioOrigin ?? videoOrigin) - videoOrigin;

      final timeline = MediaTimeline.probed(
        videoDurationSeconds: resolvedDuration,
        audioStartSeconds: relativeAudioOffset,
        audioDurationSeconds: audioDuration,
        hasAudio: audioStream != null,
      );

      AppLogger().i(
        'Media probe: videoDuration=${timeline.videoDurationSeconds}s '
        'videoOrigin=${videoOrigin}s audioOrigin=$audioOrigin '
        'relativeAudioOffset=${timeline.audioStartSeconds}s '
        'audioDuration=${timeline.audioDurationSeconds}s '
        'hasAudio=${timeline.hasAudio}',
      );
      return Success(timeline);
    } catch (e, stack) {
      AppLogger().e('Media probe failed for $path', e, stack);
      return AppError(CorruptedFileFailure(message: e.toString()));
    }
  }

  /// Signed timestamp in seconds, or `null` when the field is absent or not a
  /// real number. Negative values are valid: a stream can begin before its
  /// container, and erasing the sign is what caused B01-R1.
  static double? parseTimestampSeconds(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == 'N/A') return null;
    final parsed = double.tryParse(trimmed);
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }

  /// Non-negative duration in seconds, or `0`. A duration is a length, so a
  /// negative value is meaningless and is discarded — unlike a timestamp.
  static double parseDurationSeconds(String? value) {
    final parsed = parseTimestampSeconds(value);
    if (parsed == null || parsed < 0) return 0;
    return parsed;
  }
}
