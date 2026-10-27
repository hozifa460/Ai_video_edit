// Independent correctness checks: translating an exact decimal interval in
// time must not change whether it satisfies the configured silence minimum.
// Native boundary mocked; actual datasource parses and filters every case.
import 'package:ai_video_editing/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
  const events = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var logs = '';
  var nextSession = 0;

  setUp(() {
    logs = '';
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
          return null;
        case 'ffmpegSession':
          return {'sessionId': ++nextSession, 'createTime': 0, 'startTime': 0};
        case 'abstractSessionGetReturnCode':
          return 0;
        case 'abstractSessionGetAllLogsAsString':
          return logs;
        default:
          throw StateError('Unexpected plugin method: ${call.method}');
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Future<List<SilenceSegment>> detect() =>
      FfmpegSilenceDatasource().detectSilence(
        audioPath: 'mock.wav',
        params: const DetectionParams(
          silenceThreshold: -40,
          minSilenceDuration: 0.01,
          paddingBefore: 0,
          paddingAfter: 0,
          useVad: false,
          useBreathingProtection: false,
        ),
        totalDuration: 3600.02,
      );

  for (final bounds in [
    ('0.01', '0.02'),
    ('9.98', '9.99'),
    ('3600.01', '3600.02'),
  ]) {
    test('SR06-R3: exact 10ms decimal interval ${bounds.$1}..${bounds.$2}', () async {
      logs = 'silence_start: ${bounds.$1}\n'
          'silence_end: ${bounds.$2} | silence_duration: 0.01\n';
      expect(await detect(), [
        SilenceSegment(
          startSeconds: double.parse(bounds.$1),
          endSeconds: double.parse(bounds.$2),
        ),
      ]);
    });
  }

  test('SR06-R3: exact 10ms trailing interval after one hour', () async {
    logs = 'silence_start: 3600.01\n';
    expect(await detect(), const [
      SilenceSegment(startSeconds: 3600.01, endSeconds: 3600.02),
    ]);
  });

  test('control: genuinely shorter 9.5ms after one hour remains rejected', () async {
    logs = 'silence_start: 3600.01\n'
        'silence_end: 3600.0195 | silence_duration: 0.0095\n';
    expect(await detect(), isEmpty);
  });
}
