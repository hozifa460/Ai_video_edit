// Independent acceptance checks for OpenCode batch 01.
// These assert DESIRED behavior and intentionally fail on the reviewed revision.
// Run explicitly; they are outside the ordinary test/ suite.
// FFmpeg's native boundary is mocked; actual application datasources are used.
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart';
import 'package:ai_video_editing/features/silence_detector/data/datasources/media_probe_datasource.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/features/silence_detector/domain/services/interval_algebra.dart';
import 'package:ai_video_editing/features/audio_processing/domain/entities/waveform_data.dart';
import 'package:ai_video_editing/features/silence_detector/presentation/widgets/waveform_viewer.dart';

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

  test('B01-R3: union accepts a nonempty list with no valid intervals', () {
    expect(
      IntervalAlgebra.union(const [
        SilenceSegment(startSeconds: 1, endSeconds: 1),
        SilenceSegment(startSeconds: 5, endSeconds: 2),
        SilenceSegment(startSeconds: double.nan, endSeconds: 3),
      ]),
      isEmpty,
    );
  });

  test(
    'B01-R2: actual two-pass datasource preserves a positive 10ms gap',
    () async {
      logs =
          'silence_start: 1\nsilence_end: 2 | silence_duration: 1\n'
          'silence_start: 2.01\nsilence_end: 3 | silence_duration: 0.99\n';
      final result = await FfmpegSilenceDatasource().detectSilence(
        audioPath: 'mock.wav',
        params: const DetectionParams.defaults(),
        totalDuration: 10,
      );
      expect(result, const [
        SilenceSegment(startSeconds: 1, endSeconds: 2),
        SilenceSegment(startSeconds: 2.01, endSeconds: 3),
      ]);
    },
  );

  test(
    'B01-R3: datasource ignores zero-length log pairs without throwing',
    () async {
      logs = 'silence_start: 1\nsilence_end: 1 | silence_duration: 0\n';
      expect(
        await FfmpegSilenceDatasource().detectSilence(
          audioPath: 'mock.wav',
          params: const DetectionParams.defaults(),
          totalDuration: 10,
        ),
        isEmpty,
      );
    },
  );

  test(
    'B01-R1: shared nonzero audio/video start implies zero relative offset',
    () async {
      metadata = {
        'format': {'duration': '10', 'start_time': '5'},
        'streams': [
          {'codec_type': 'video', 'duration': '10', 'start_time': '5'},
          {'codec_type': 'audio', 'duration': '10', 'start_time': '5'},
        ],
      };
      final result = await MediaProbeDatasource().probe('mock.mp4');
      expect(result, isA<Success<MediaTimeline>>());
      final timeline = (result as Success<MediaTimeline>).value;
      expect(
        timeline.audioToVideoTimeline(const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
        ]),
        const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      );
    },
  );

  test('B01-R1: audio preceding video must retain its signed offset', () async {
    metadata = {
      'format': {'duration': '10.5', 'start_time': '-0.5'},
      'streams': [
        {'codec_type': 'video', 'duration': '10', 'start_time': '0'},
        {'codec_type': 'audio', 'duration': '10.5', 'start_time': '-0.5'},
      ],
    };
    final result = await MediaProbeDatasource().probe('mock.mp4');
    expect(result, isA<Success<MediaTimeline>>());
    final timeline = (result as Success<MediaTimeline>).value;
    expect(
      timeline.audioToVideoTimeline(const [
        SilenceSegment(startSeconds: 1, endSeconds: 2),
      ]),
      const [SilenceSegment(startSeconds: 0.5, endSeconds: 1.5)],
    );
  });

  test(
    'B01-C1: canonical removal plan cannot be mutated out of consistency',
    () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      );
      expect(() => plan.removals.clear(), throwsUnsupportedError);
      expect(() => plan.kept.clear(), throwsUnsupportedError);
      expect(plan.removedSeconds + plan.keptSeconds, closeTo(10, 1e-9));
    },
  );

  testWidgets('B01-R4: 8s waveform on 10s ruler keeps a peak at second 4', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 400,
          child: WaveformViewer(
            totalDuration: 10,
            waveform: WaveformData(
              samples: [0, 0, 1, 0],
              sampleRate: 16000,
              durationSeconds: 8,
            ),
          ),
        ),
      ),
    );
    final paintWidget = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(WaveformViewer),
        matching: find.byType(CustomPaint),
      ),
    );
    final recorder = ui.PictureRecorder();
    paintWidget.painter!.paint(Canvas(recorder), const Size(400, 100));
    final picture = recorder.endRecording();
    final pixels = await tester.runAsync(() async {
      final rendered = await picture.toImage(400, 100);
      final bytes = await rendered.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      rendered.dispose();
      return bytes!;
    });
    picture.dispose();
    // The nonzero sample at audio t=4s belongs at x=160 on a 10s/400px ruler.
    // The current painter instead stretches the audio to fill all 10 seconds.
    final expectedAlpha = pixels!.getUint8((20 * 400 + 160) * 4 + 3);
    final stretchedAlpha = pixels.getUint8((20 * 400 + 200) * 4 + 3);
    expect(
      expectedAlpha,
      greaterThan(0),
      reason:
          'Peak must stay at 4s, not stretch to 5s; alpha at x=200 is $stretchedAlpha',
    );
  });
}
