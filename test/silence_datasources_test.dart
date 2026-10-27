import 'package:ai_video_editing/core/errors/failures.dart';
import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart';
import 'package:ai_video_editing/features/silence_detector/data/datasources/media_probe_datasource.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests that drive the **real** `FfmpegSilenceDatasource` and
/// `MediaProbeDatasource` with FFmpegKit's platform channel mocked on the host.
///
/// Review finding B01-R2 proved the 20ms pass-merge tolerance deleted a 10ms
/// gap, and B01-R1 proved the probe fed an absolute timestamp in as a relative
/// offset. Both were reproduced against these datasources, so both are pinned
/// here against the same datasources rather than against a copy of their logic.
///
/// The channel is mocked: this exercises the project's parsing, clamping and
/// offset arithmetic, not FFmpeg or FFprobe. Real probe output and real media
/// timing still require a device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
  const events = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  var nextSession = 0;
  var logs = '';
  Map<String, Object?> metadata = {};

  setUp(() {
    logs = '';
    metadata = {};
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getLogLevel':
          return 32;
        case 'getPlatform':
        case 'getArch':
        case 'getPackageName':
          return 'test';
        case 'isLTSBuild':
          return false;
        case 'setLogLevel':
        case 'enableRedirection':
        case 'ffmpegSessionExecute':
        case 'mediaInformationSessionExecute':
          return null;
        case 'ffmpegSession':
        case 'mediaInformationSession':
          return {'sessionId': ++nextSession, 'createTime': 0, 'startTime': 0};
        case 'abstractSessionGetReturnCode':
          return 0;
        case 'abstractSessionGetAllLogsAsString':
          return logs;
        case 'getMediaInformation':
          return metadata;
        default:
          throw StateError('Unexpected plugin method: ${call.method}');
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Future<List<SilenceSegment>> detect({
    DetectionParams params = const DetectionParams.defaults(),
    double totalDuration = 10,
  }) {
    return FfmpegSilenceDatasource().detectSilence(
      audioPath: 'mock.wav',
      params: params,
      totalDuration: totalDuration,
    );
  }

  Future<MediaTimeline> probe(Map<String, Object?> info) async {
    metadata = info;
    final result = await MediaProbeDatasource().probe('mock.mp4');
    expect(result, isA<Success<MediaTimeline>>());
    return (result as Success<MediaTimeline>).value;
  }

  group('B01-R2 the two-pass datasource fills no positive gap', () {
    for (final gapMs in [1, 10, 19, 20, 21, 200]) {
      test('a ${gapMs}ms gap between the passes survives detection', () async {
        final gap = gapMs / 1000;
        logs =
            'silence_start: 1\nsilence_end: 2 | silence_duration: 1\n'
            'silence_start: ${2 + gap}\n'
            'silence_end: 3 | silence_duration: ${1 - gap}\n';

        final result = await detect();

        expect(result, [
          const SilenceSegment(startSeconds: 1, endSeconds: 2),
          SilenceSegment(startSeconds: 2 + gap, endSeconds: 3),
        ]);
      });
    }

    test('true overlap between the passes is still unioned', () async {
      logs =
          'silence_start: 1\nsilence_end: 2.5\n'
          'silence_start: 2\nsilence_end: 3\n';
      expect(await detect(), [
        const SilenceSegment(startSeconds: 1, endSeconds: 3),
      ]);
    });

    test('exact touch between the passes is still unioned', () async {
      logs =
          'silence_start: 1\nsilence_end: 2\n'
          'silence_start: 2\nsilence_end: 3\n';
      expect(await detect(), [
        const SilenceSegment(startSeconds: 1, endSeconds: 3),
      ]);
    });

    test(
      'raising minSilenceDuration does not widen the merged result',
      () async {
        // Both silences are 2s long so they clear every minimum under test,
        // including the 2s one. The point of this case is the union behaviour
        // (the 0.5s gap stays a gap), not the minimum.
        logs =
            'silence_start: 1\nsilence_end: 3\n'
            'silence_start: 3.5\nsilence_end: 5.5\n';

        final atDefault = await detect();
        final atMax = await detect(
          params: const DetectionParams(
            silenceThreshold: -40,
            minSilenceDuration: 2,
            paddingBefore: 0,
            paddingAfter: 0,
          ),
        );

        expect(atMax, atDefault);
        expect(atDefault, [
          const SilenceSegment(startSeconds: 1, endSeconds: 3),
          const SilenceSegment(startSeconds: 3.5, endSeconds: 5.5),
        ]);
      },
    );
  });

  group('B01-R3 the datasource ignores degenerate log pairs', () {
    test('a zero-length pair yields no interval and no exception', () async {
      logs = 'silence_start: 1\nsilence_end: 1 | silence_duration: 0\n';
      expect(await detect(), isEmpty);
    });

    test('an inverted pair yields no interval and no exception', () async {
      logs = 'silence_start: 4\nsilence_end: 2 | silence_duration: 2\n';
      expect(await detect(), isEmpty);
    });

    test(
      'degenerate pairs mixed with valid ones keep only the valid ones',
      () async {
        logs =
            'silence_start: 1\nsilence_end: 1\n'
            'silence_start: 2\nsilence_end: 3\n'
            'silence_start: 6\nsilence_end: 5\n';
        expect(await detect(), [
          const SilenceSegment(startSeconds: 2, endSeconds: 3),
        ]);
      },
    );

    test('only a malformed silence_start yields nothing', () async {
      logs = 'silence_start: NaN\nsilence_end: 2\n';
      expect(await detect(), isEmpty);
    });
  });

  group('B01-R1 the probe measures a signed relative audio offset', () {
    test('a shared non-zero origin implies zero offset', () async {
      final timeline = await probe({
        'format': {'duration': '10', 'start_time': '5'},
        'streams': [
          {'codec_type': 'video', 'duration': '10', 'start_time': '5'},
          {'codec_type': 'audio', 'duration': '10', 'start_time': '5'},
        ],
      });

      expect(timeline.audioStartSeconds, 0);
      expect(
        timeline.audioToVideoTimeline(const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
        ]),
        const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      );
    });

    test('audio before video keeps its negative offset', () async {
      final timeline = await probe({
        'format': {'duration': '10.5', 'start_time': '-0.5'},
        'streams': [
          {'codec_type': 'video', 'duration': '10', 'start_time': '0'},
          {'codec_type': 'audio', 'duration': '10.5', 'start_time': '-0.5'},
        ],
      });

      expect(timeline.audioStartSeconds, -0.5);
      expect(
        timeline.audioToVideoTimeline(const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
        ]),
        const [SilenceSegment(startSeconds: 0.5, endSeconds: 1.5)],
      );
      expect(timeline.detectionWindowEndSeconds, closeTo(10.5, 1e-9));
    });

    test('audio after video reports a positive offset', () async {
      final timeline = await probe({
        'format': {'duration': '10'},
        'streams': [
          {'codec_type': 'video', 'duration': '10', 'start_time': '0'},
          {'codec_type': 'audio', 'duration': '9', 'start_time': '0.5'},
        ],
      });

      expect(timeline.audioStartSeconds, 0.5);
      expect(
        timeline.audioToVideoTimeline(const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
        ]),
        const [SilenceSegment(startSeconds: 1.5, endSeconds: 2.5)],
      );
      expect(timeline.detectionWindowEndSeconds, closeTo(9, 1e-9));
    });

    test('missing audio start_time falls back to the video origin', () async {
      final timeline = await probe({
        'format': {'duration': '10', 'start_time': '5'},
        'streams': [
          {'codec_type': 'video', 'duration': '10', 'start_time': '5'},
          {'codec_type': 'audio', 'duration': '10'},
        ],
      });

      expect(timeline.audioStartSeconds, 0);
    });

    test(
      'missing video start_time falls back to the container origin',
      () async {
        final timeline = await probe({
          'format': {'duration': '10', 'start_time': '5'},
          'streams': [
            {'codec_type': 'video', 'duration': '10'},
            {'codec_type': 'audio', 'duration': '10', 'start_time': '5.5'},
          ],
        });

        expect(timeline.audioStartSeconds, 0.5);
      },
    );

    test(
      'no start_time anywhere means zero offset, not zero video time',
      () async {
        final timeline = await probe({
          'format': {'duration': '10'},
          'streams': [
            {'codec_type': 'video', 'duration': '10'},
            {'codec_type': 'audio', 'duration': '10'},
          ],
        });

        expect(timeline.audioStartSeconds, 0);
        expect(timeline.videoDurationSeconds, 10);
      },
    );

    test(
      'a stream without a duration falls back to the container duration',
      () async {
        final timeline = await probe({
          'format': {'duration': '12'},
          'streams': [
            {'codec_type': 'video'},
            {'codec_type': 'audio', 'start_time': '0'},
          ],
        });

        expect(timeline.videoDurationSeconds, 12);
        expect(timeline.hasAudio, isTrue);
      },
    );

    test('a file with no audio reports hasAudio false', () async {
      final timeline = await probe({
        'format': {'duration': '10'},
        'streams': [
          {'codec_type': 'video', 'duration': '10', 'start_time': '0'},
        ],
      });

      expect(timeline.hasAudio, isFalse);
      expect(timeline.isDetectable, isFalse);
    });

    test(
      'an offset larger than the video duration survives the real probe',
      () async {
        // Video starts at 12s and runs 10s; audio starts at 0 and runs 22s. The
        // relative offset is -12, and the probe must report exactly that.
        final timeline = await probe({
          'format': {'duration': '22', 'start_time': '0'},
          'streams': [
            {'codec_type': 'video', 'duration': '10', 'start_time': '12'},
            {'codec_type': 'audio', 'duration': '22', 'start_time': '0'},
          ],
        });

        expect(timeline.audioStartSeconds, -12);
        expect(timeline.videoDurationSeconds, 10);
        expect(timeline.detectionWindow(), (
          startSeconds: 12.0,
          endSeconds: 22.0,
        ));
        expect(
          timeline.audioToVideoTimeline(const [
            SilenceSegment(startSeconds: 13, endSeconds: 14),
          ]),
          const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
        );
      },
    );

    test(
      'an audio stream that never meets the video yields no intersection',
      () async {
        final before = await probe({
          'format': {'duration': '11', 'start_time': '0'},
          'streams': [
            {'codec_type': 'video', 'duration': '10', 'start_time': '12'},
            {'codec_type': 'audio', 'duration': '11', 'start_time': '0'},
          ],
        });
        expect(before.audioStartSeconds, -12);
        expect(before.detectionWindow(), isNull);
        expect(before.isDetectable, isFalse);

        final after = await probe({
          'format': {'duration': '10', 'start_time': '0'},
          'streams': [
            {'codec_type': 'video', 'duration': '10', 'start_time': '0'},
            {'codec_type': 'audio', 'duration': '3', 'start_time': '12'},
          ],
        });
        expect(after.audioStartSeconds, 12);
        expect(after.detectionWindow(), isNull);
        expect(after.isDetectable, isFalse);
      },
    );

    test(
      'the video stream duration wins over a longer container duration',
      () async {
        // An audio-only tail would otherwise inflate the timeline the cut is
        // planned against.
        final timeline = await probe({
          'format': {'duration': '10'},
          'streams': [
            {'codec_type': 'video', 'duration': '8', 'start_time': '0'},
            {'codec_type': 'audio', 'duration': '10', 'start_time': '0'},
          ],
        });

        expect(timeline.videoDurationSeconds, 8);
        expect(timeline.audioDurationSeconds, 10);
      },
    );
  });

  group('media information failures stay typed', () {
    test(
      'a file with no readable duration returns CorruptedFileFailure',
      () async {
        metadata = {
          'format': <String, Object?>{},
          'streams': [
            {'codec_type': 'video', 'start_time': '0'},
          ],
        };
        final result = await MediaProbeDatasource().probe('mock.mp4');
        expect(result, isA<AppError<MediaTimeline>>());
        expect(
          (result as AppError<MediaTimeline>).error,
          isA<CorruptedFileFailure>(),
        );
      },
    );
  });

  group('timestamp and duration parsing are separate contracts', () {
    test('a negative timestamp is preserved', () {
      expect(MediaProbeDatasource.parseTimestampSeconds('-0.5'), -0.5);
    });

    test('a negative duration is discarded', () {
      expect(MediaProbeDatasource.parseDurationSeconds('-2'), 0);
    });

    test('absent and non-numeric fields become null for timestamps', () {
      expect(MediaProbeDatasource.parseTimestampSeconds(null), isNull);
      expect(MediaProbeDatasource.parseTimestampSeconds(''), isNull);
      expect(MediaProbeDatasource.parseTimestampSeconds('N/A'), isNull);
      expect(MediaProbeDatasource.parseTimestampSeconds('abc'), isNull);
      expect(MediaProbeDatasource.parseTimestampSeconds('NaN'), isNull);
      expect(MediaProbeDatasource.parseTimestampSeconds('Infinity'), isNull);
    });

    test('absent durations become zero', () {
      expect(MediaProbeDatasource.parseDurationSeconds(null), 0);
      expect(MediaProbeDatasource.parseDurationSeconds('N/A'), 0);
      expect(MediaProbeDatasource.parseDurationSeconds('10.5'), 10.5);
      expect(MediaProbeDatasource.parseDurationSeconds(' 10.5 '), 10.5);
    });
  });
}
