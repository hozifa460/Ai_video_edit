import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart';
import 'package:ai_video_editing/features/silence_detector/data/repositories/silence_detector_repository_impl.dart';
import 'package:ai_video_editing/features/silence_detector/data/services/vad_service.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_detection_blocker.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/features/silence_detector/presentation/editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressions for B01-F2: the reason a file cannot be analysed must be one
/// ordered contract, and it must be the same reason the user reads and the
/// repository records.
///
/// The screen previously tested `isDetectable` on its own and wrote "no duration
/// or no audio track" for every failure, so a file with a valid duration, an
/// audio stream and no overlap reached the user with the wrong reason. The
/// repository separately reported "no overlap" for a file with no readable
/// duration, because it consulted `hasDetectionWindow` before checking the
/// duration.
///
/// The full `EditorScreen` tree cannot be pumped here: it needs
/// `VideoPlayerPlatform`, which is unreachable from `flutter test` without adding
/// a dependency. The visible path is instead asserted through
/// `EditorScreen.detectionBlockedMessage` — the very entry point the screen's own
/// `_detectSilence` calls — rendered in a real `SnackBar`.
void main() {
  const noVad = DetectionParams(
    silenceThreshold: -40,
    minSilenceDuration: 0.25,
    paddingBefore: 0,
    paddingAfter: 0,
    useVad: false,
    useBreathingProtection: false,
  );

  final repository = SilenceDetectorRepositoryImpl(
    datasource: _FakeSilenceDatasource(const []),
    vadService: _NoopVadService(),
  );

  Future<String?> repositoryMessage(MediaTimeline timeline) async {
    final result = await repository.buildRemovalPlan(
      audioPath: 'audio.wav',
      params: noVad,
      timeline: timeline,
    );
    expect(result, isA<AppError<SilenceRemovalPlan>>());
    return (result as AppError<SilenceRemovalPlan>).error.message;
  }

  final durationMissing = MediaTimeline.probed(
    videoDurationSeconds: 0,
    audioStartSeconds: 0,
    audioDurationSeconds: 8,
    hasAudio: true,
  );
  final audioMissing = MediaTimeline.probed(
    videoDurationSeconds: 10,
    audioStartSeconds: 0,
    audioDurationSeconds: 10,
    hasAudio: false,
  );
  final overlapMissing = MediaTimeline.probed(
    videoDurationSeconds: 10,
    audioStartSeconds: -12,
    audioDurationSeconds: 11,
  );
  final detectable = MediaTimeline.probed(
    videoDurationSeconds: 10,
    audioStartSeconds: 0,
    audioDurationSeconds: 10,
  );

  group('the blocker order is fixed', () {
    test('an unreadable duration wins over every other reason', () {
      // Duration 0 AND audio present AND no window: reporting "no overlap" here
      // is the specific mistake Codex traced to the condition order.
      expect(
        SilenceDetectionGate.blockerFor(durationMissing),
        SilenceDetectionBlocker.unusableMediaDuration,
      );
    });

    test('a missing audio track wins over a missing overlap', () {
      final both = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: 12,
        audioDurationSeconds: 3,
        hasAudio: false,
      );
      expect(
        SilenceDetectionGate.blockerFor(both),
        SilenceDetectionBlocker.missingAudioTrack,
      );
    });

    test(
      'a missing overlap is only reported when duration and audio are fine',
      () {
        expect(
          SilenceDetectionGate.blockerFor(overlapMissing),
          SilenceDetectionBlocker.noAudioVideoOverlap,
        );
      },
    );

    test('each blocker message names its own cause', () {
      final messages = SilenceDetectionBlocker.values
          .map(SilenceDetectionGate.messageFor)
          .toList();
      expect(messages.toSet().length, messages.length);
      expect(
        messages[SilenceDetectionBlocker.unusableMediaDuration.index],
        contains('duration'),
      );
      expect(
        messages[SilenceDetectionBlocker.missingAudioTrack.index],
        contains('audio track'),
      );
      expect(
        messages[SilenceDetectionBlocker.noAudioVideoOverlap.index],
        contains('overlap'),
      );
    });
  });

  group('the gate agrees with MediaTimeline.isDetectable', () {
    final matrix = <MediaTimeline>[
      durationMissing,
      audioMissing,
      overlapMissing,
      detectable,
      MediaTimeline.unknown,
      MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: 12,
        audioDurationSeconds: 3,
      ),
      MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: -12,
        audioDurationSeconds: 22,
      ),
    ];

    for (var i = 0; i < matrix.length; i++) {
      test('timeline #$i: canDetect matches isDetectable', () {
        expect(
          SilenceDetectionGate.canDetect(matrix[i]),
          matrix[i].isDetectable,
        );
        expect(
          SilenceDetectionGate.blockerFor(matrix[i]) == null,
          matrix[i].isDetectable,
        );
      });
    }
  });

  group('the screen and the repository report the same reason', () {
    for (final entry in {
      'no readable duration': durationMissing,
      'no audio track': audioMissing,
      'no audio/video overlap': overlapMissing,
    }.entries) {
      test('${entry.key}: screen text equals the repository failure', () async {
        final onScreen = EditorScreen.detectionBlockedMessage(entry.value);
        expect(onScreen, isNotNull);
        expect(await repositoryMessage(entry.value), onScreen);
      });
    }

    test('a detectable timeline produces no message at all', () {
      expect(EditorScreen.detectionBlockedMessage(detectable), isNull);
    });

    test('the screen message is not the old combined wording', () {
      final message =
          EditorScreen.detectionBlockedMessage(overlapMissing) ?? '';
      expect(message, isNot(contains('no readable duration')));
      expect(message, isNot(contains('no audio track')));
      expect(message, contains('overlap'));
    });
  });

  group('the reason is user-visible', () {
    testWidgets('the screen message renders as a SnackBar body', (
      tester,
    ) async {
      final message = EditorScreen.detectionBlockedMessage(overlapMissing);
      expect(message, isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(message!))),
                  child: const Text('detect'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('detect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(message!), findsOneWidget);
      expect(find.textContaining('overlap'), findsOneWidget);
    });

    testWidgets('a detectable file shows no blocked SnackBar', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );

      final message = EditorScreen.detectionBlockedMessage(detectable);
      expect(message, isNull);
      expect(find.textContaining('overlap'), findsNothing);
    });
  });
}

class _FakeSilenceDatasource implements FfmpegSilenceDatasource {
  final List<SilenceSegment> detected;

  const _FakeSilenceDatasource(this.detected);

  @override
  Future<List<SilenceSegment>> detectSilence({
    required String audioPath,
    required DetectionParams params,
    double? totalDuration,
  }) async {
    return detected;
  }
}

class _NoopVadService implements VadService {
  @override
  Future<List<SilenceSegment>> refineSilence(
    String audioPath,
    List<SilenceSegment> silenceSegments,
    DetectionParams params,
  ) async {
    return silenceSegments;
  }
}
