// Independent desired-behavior checks for SR-06. Native FFmpeg is mocked.
// The datasource and repository under test are the actual project classes.
import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart';
import 'package:ai_video_editing/features/silence_detector/data/repositories/silence_detector_repository_impl.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
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
  var sessionId = 0;
  final commands = <String>[];

  setUp(() {
    logs = '';
    commands.clear();
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
          final arguments = (call.arguments as Map)['arguments'] as List;
          commands.add(arguments.join(' '));
          return {'sessionId': ++sessionId, 'createTime': 0, 'startTime': 0};
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

  DetectionParams params(double min, {double guard = 0}) => DetectionParams(
    silenceThreshold: -40,
    minSilenceDuration: min,
    paddingBefore: guard,
    paddingAfter: guard,
    useVad: false,
    useBreathingProtection: false,
  );

  test('SR06-R1: 9.5ms is genuinely below a 10ms minimum', () {
    expect(
      FfmpegSilenceDatasource.satisfiesMinimumSilence(0.0095, 0.01),
      isFalse,
    );
  });

  test('numeric control: binary subtraction at the boundary stays accepted', () {
    expect(
      FfmpegSilenceDatasource.satisfiesMinimumSilence(0.3 - 0.1, 0.2),
      isTrue,
    );
  });

  test('SR06-R1: actual datasource rejects a 9.5ms parsed interval', () async {
    logs = 'silence_start: 2\nsilence_end: 2.0095\n';
    final result = await FfmpegSilenceDatasource().detectSilence(
      audioPath: 'mock.wav',
      params: params(0.01),
      totalDuration: 3,
    );
    expect(result, isEmpty);
  });

  test('SR06-R2: 20ms trailing silence is accepted at a 10ms minimum', () async {
    logs = 'silence_start: 1\n';
    final result = await FfmpegSilenceDatasource().detectSilence(
      audioPath: 'mock.wav',
      params: params(0.01),
      totalDuration: 1.02,
    );
    expect(result, const [SilenceSegment(startSeconds: 1, endSeconds: 1.02)]);
  });

  test('pipeline control: real datasource accepts raw minimum before guards', () async {
    logs = 'silence_start: 11\nsilence_end: 13\n';
    final result = await SilenceDetectorRepositoryImpl().buildRemovalPlan(
      audioPath: 'mock.wav',
      params: params(2, guard: 0.5),
      timeline: MediaTimeline.probed(
        videoDurationSeconds: 20,
        audioDurationSeconds: 20,
      ),
    );
    expect(result, isA<Success<SilenceRemovalPlan>>());
    final plan = (result as Success<SilenceRemovalPlan>).value;
    expect(plan.removals, const [
      SilenceSegment(startSeconds: 11.5, endSeconds: 12.5),
    ]);
    expect(commands, hasLength(2));
    expect(commands.every((command) => command.contains(':d=2.0')), isTrue);
  });
}
