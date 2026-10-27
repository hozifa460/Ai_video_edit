import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart';
import 'package:ai_video_editing/features/silence_detector/data/repositories/silence_detector_repository_impl.dart';
import 'package:ai_video_editing/features/silence_detector/data/services/breathing_protection_service.dart';
import 'package:ai_video_editing/features/silence_detector/data/services/vad_service.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/features/silence_detector/domain/services/interval_algebra.dart';
import 'package:flutter_test/flutter_test.dart';

/// End-to-end checks of the detection pipeline with FFmpeg and the WAV reader
/// replaced by deterministic fakes.
///
/// These are the handoff acceptance fixtures for SR-01/02/03/05 plus review
/// findings B01-R1 (signed audio offset), B01-R2 (no gap filling) and B01-R3
/// (invalid-only input). They exercise the real repository, the real breathing
/// protection and the real plan — only the two plugin boundaries are faked.
void main() {
  const noVad = DetectionParams(
    silenceThreshold: -40,
    minSilenceDuration: 0.25,
    paddingBefore: 0,
    paddingAfter: 0,
    useVad: false,
    useBreathingProtection: false,
  );

  Future<SilenceRemovalPlan> build({
    required List<SilenceSegment> detected,
    required MediaTimeline timeline,
    DetectionParams params = noVad,
  }) async {
    final repository = SilenceDetectorRepositoryImpl(
      datasource: _FakeSilenceDatasource(detected),
      vadService: _NoopVadService(),
    );
    final result = await repository.buildRemovalPlan(
      audioPath: 'audio.wav',
      params: params,
      timeline: timeline,
    );
    expect(result, isA<Success<SilenceRemovalPlan>>());
    return (result as Success<SilenceRemovalPlan>).value;
  }

  group('SR-01 speech between two silences is kept', () {
    test(
      '200ms island survives, and raising min silence cannot remove it',
      () async {
        final timeline = MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioDurationSeconds: 10,
        );
        final detected = const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
          SilenceSegment(startSeconds: 2.2, endSeconds: 3),
        ];

        for (final minSilence in [0.01, 0.25, 2.0, 5.0]) {
          final plan = await build(
            detected: detected,
            timeline: timeline,
            params: noVad.copyWith(minSilenceDuration: minSilence),
          );

          expect(
            plan.removals,
            detected,
            reason:
                'minSilenceDuration=$minSilence must not widen the removals',
          );
          // The 200ms island shows up as a kept range between the two removals.
          expect(plan.kept, [
            const SilenceSegment(startSeconds: 0, endSeconds: 1),
            const SilenceSegment(startSeconds: 2, endSeconds: 2.2),
            const SilenceSegment(startSeconds: 3, endSeconds: 10),
          ]);
          expect(plan.removedSeconds, closeTo(1.8, 1e-9));
        }
      },
    );

    test('overlapping detections from two passes become one removal', () async {
      final plan = await build(
        detected: const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
          SilenceSegment(startSeconds: 1.9, endSeconds: 2.5),
        ],
        timeline: MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioDurationSeconds: 10,
        ),
      );

      expect(plan.removals, [
        const SilenceSegment(startSeconds: 1, endSeconds: 2.5),
      ]);
    });
  });

  group('SR-19 a contained detection never shortens the union', () {
    test('the outer interval wins regardless of input order', () async {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioDurationSeconds: 10,
      );

      final nestedFirst = await build(
        detected: const [
          SilenceSegment(startSeconds: 1, endSeconds: 5),
          SilenceSegment(startSeconds: 2, endSeconds: 3),
        ],
        timeline: timeline,
      );
      final nestedLast = await build(
        detected: const [
          SilenceSegment(startSeconds: 2, endSeconds: 3),
          SilenceSegment(startSeconds: 1, endSeconds: 5),
        ],
        timeline: timeline,
      );

      expect(nestedFirst.removals, [
        const SilenceSegment(startSeconds: 1, endSeconds: 5),
      ]);
      expect(nestedLast.removals, nestedFirst.removals);
      expect(nestedFirst.removedSeconds, closeTo(4, 1e-9));
    });
  });

  group('SR-02 padding is protected space, not extra deletion', () {
    test('0 / 50 / 150 / 500ms guards on the same detection', () async {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioDurationSeconds: 10,
      );
      const detected = [SilenceSegment(startSeconds: 1, endSeconds: 2)];

      final results = <double>[];
      for (final guard in [0.0, 0.05, 0.15, 0.5]) {
        final plan = await build(
          detected: detected,
          timeline: timeline,
          params: noVad.copyWith(paddingBefore: guard, paddingAfter: guard),
        );
        if (plan.removals.isEmpty) {
          results.add(0);
          continue;
        }
        final single = plan.removals.single;
        // The removal never leaves the confirmed silence.
        expect(single.startSeconds, greaterThanOrEqualTo(1));
        expect(single.endSeconds, lessThanOrEqualTo(2));
        results.add(plan.removedSeconds);
      }

      // Monotonically less audio is deleted as the guard grows.
      expect(results[0], closeTo(1.0, 1e-9));
      expect(results[1], closeTo(0.9, 1e-9));
      expect(results[2], closeTo(0.7, 1e-9));
      expect(results[3], 0);
      for (var i = 1; i < results.length; i++) {
        expect(results[i], lessThan(results[i - 1]));
      }
    });

    test('the deletion no longer crosses into neighbouring speech', () async {
      final plan = await build(
        detected: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
        timeline: MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioDurationSeconds: 10,
        ),
        params: noVad.copyWith(paddingBefore: 0.15, paddingAfter: 0.15),
      );

      expect(plan.removals.single.startSeconds, closeTo(1.15, 1e-9));
      expect(plan.removals.single.endSeconds, closeTo(1.85, 1e-9));
      // Everything the old padding deleted outside the silence is now kept.
      expect(plan.kept, [
        const SilenceSegment(startSeconds: 0, endSeconds: 1.15),
        const SilenceSegment(startSeconds: 1.85, endSeconds: 10),
      ]);
    });
  });

  group('SR-03 statistics and the cut read one normalized plan', () {
    test('the overlap fixture from the review reports the union', () async {
      // Old behaviour: padded intervals [0.5,2.5] and [2.1,4] summed to 3.9s
      // for a 3.5s span.
      final plan = await build(
        detected: const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
          SilenceSegment(startSeconds: 2.6, endSeconds: 3.5),
        ],
        timeline: MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioDurationSeconds: 10,
        ),
      );

      expect(plan.removals.length, 2);
      for (var i = 1; i < plan.removals.length; i++) {
        expect(
          plan.removals[i].startSeconds,
          greaterThanOrEqualTo(plan.removals[i - 1].endSeconds),
        );
      }
      expect(plan.removedSeconds, closeTo(1.9, 1e-9));
      expect(plan.removedSeconds + plan.keptSeconds, closeTo(10, 1e-9));
      expect(
        plan.kept.fold<double>(0, (sum, k) => sum + k.durationSeconds),
        closeTo(plan.keptSeconds, 1e-9),
      );
    });

    test('non-finite and inverted detections never reach the plan', () async {
      final plan = await build(
        detected: const [
          SilenceSegment(startSeconds: double.nan, endSeconds: 3),
          SilenceSegment(startSeconds: 2, endSeconds: 1),
          SilenceSegment(startSeconds: double.infinity, endSeconds: 4),
          SilenceSegment(startSeconds: 4, endSeconds: 5),
          SilenceSegment(startSeconds: -5, endSeconds: -1),
        ],
        timeline: MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioDurationSeconds: 10,
        ),
      );

      expect(plan.removals, [
        const SilenceSegment(startSeconds: 4, endSeconds: 5),
      ]);
      expect(plan.removedSeconds, closeTo(1, 1e-9));
      expect(plan.removedRatio, closeTo(0.1, 1e-9));
    });

    test(
      'detections beyond the audio window are clamped to the video',
      () async {
        // Video 10s, audio only 8s: a detection reported at 9s is outside the
        // audio window and must not delete the picture tail.
        final plan = await build(
          detected: const [
            SilenceSegment(startSeconds: 1, endSeconds: 2),
            SilenceSegment(startSeconds: 9, endSeconds: 20),
          ],
          timeline: MediaTimeline.probed(
            videoDurationSeconds: 10,
            audioDurationSeconds: 8,
          ),
        );

        expect(plan.removals, [
          const SilenceSegment(startSeconds: 1, endSeconds: 2),
        ]);
        expect(plan.kept.last.endSeconds, 10);
      },
    );
  });

  group('SR-05 the probe decides the timeline', () {
    test(
      'audio starting 500ms late is measured against the video timeline',
      () async {
        final plan = await build(
          detected: const [
            SilenceSegment(startSeconds: 1, endSeconds: 2),
            SilenceSegment(startSeconds: 3, endSeconds: 4),
          ],
          timeline: MediaTimeline.probed(
            videoDurationSeconds: 10,
            audioStartSeconds: 0.5,
            audioDurationSeconds: 9,
          ),
        );

        expect(plan.removals, [
          const SilenceSegment(startSeconds: 1.5, endSeconds: 2.5),
          const SilenceSegment(startSeconds: 3.5, endSeconds: 4.5),
        ]);
        expect(plan.totalDurationSeconds, 10);
        expect(
          plan.kept.first,
          const SilenceSegment(startSeconds: 0, endSeconds: 1.5),
        );
      },
    );

    test(
      'a shared non-zero origin means zero offset, not a 5s shift',
      () async {
        // B01-R1: the previous probe fed the absolute audio timestamp in as the
        // offset, so a file whose audio and video both start at 5s moved every
        // cut to [6,7].
        final plan = await build(
          detected: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
          timeline: MediaTimeline.probed(
            videoDurationSeconds: 10,
            audioStartSeconds: 0,
            audioDurationSeconds: 10,
          ),
        );

        expect(plan.removals, [
          const SilenceSegment(startSeconds: 1, endSeconds: 2),
        ]);
        expect(plan.removedSeconds, closeTo(1, 1e-9));
      },
    );

    test(
      'audio preceding the video shifts cuts left and keeps in-video audio',
      () async {
        final plan = await build(
          detected: const [
            SilenceSegment(startSeconds: 0, endSeconds: 0.2),
            SilenceSegment(startSeconds: 0.4, endSeconds: 0.9),
            SilenceSegment(startSeconds: 1.4, endSeconds: 2),
            SilenceSegment(startSeconds: 2.4, endSeconds: 3.2),
          ],
          timeline: MediaTimeline.probed(
            videoDurationSeconds: 10,
            audioStartSeconds: -0.5,
            audioDurationSeconds: 10.5,
          ),
        );

        // [-0.5,-0.3] is pre-roll entirely before the video and is discarded
        // instead of being clamped onto the origin; the other three shift left by
        // 0.5s. Binary floating point makes exact equality wrong here.
        expect(plan.removals.length, 3);
        expect(plan.removals[0].startSeconds, closeTo(0, 1e-9));
        expect(plan.removals[0].endSeconds, closeTo(0.4, 1e-9));
        expect(plan.removals[1].startSeconds, closeTo(0.9, 1e-9));
        expect(plan.removals[1].endSeconds, closeTo(1.5, 1e-9));
        expect(plan.removals[2].startSeconds, closeTo(1.9, 1e-9));
        expect(plan.removals[2].endSeconds, closeTo(2.7, 1e-9));

        expect(plan.removals.first.startSeconds, greaterThanOrEqualTo(0));
        expect(plan.removals.last.endSeconds, lessThanOrEqualTo(10));
        expect(plan.removedSeconds, closeTo(1.8, 1e-9));
        expect(plan.removedSeconds + plan.keptSeconds, closeTo(10, 1e-9));
      },
    );

    test('an unusable timeline is refused with a typed error', () async {
      final repository = SilenceDetectorRepositoryImpl(
        datasource: _FakeSilenceDatasource(const []),
        vadService: _NoopVadService(),
      );

      for (final timeline in [
        MediaTimeline.unknown,
        MediaTimeline.probed(videoDurationSeconds: 0),
        MediaTimeline.probed(videoDurationSeconds: 10, hasAudio: false),
      ]) {
        final result = await repository.buildRemovalPlan(
          audioPath: 'audio.wav',
          params: noVad,
          timeline: timeline,
        );
        expect(result, isA<AppError<SilenceRemovalPlan>>());
      }
    });

    test(
      'an empty audio/video intersection is refused, not planned as empty',
      () async {
        // Audio finishes before the video starts: there is genuinely nothing that
        // can be cut against picture, and no origin may be invented to make one.
        final repository = SilenceDetectorRepositoryImpl(
          datasource: _FakeSilenceDatasource(const [
            SilenceSegment(startSeconds: 1, endSeconds: 2),
          ]),
          vadService: _NoopVadService(),
        );

        final result = await repository.buildRemovalPlan(
          audioPath: 'audio.wav',
          params: noVad,
          timeline: MediaTimeline.probed(
            videoDurationSeconds: 10,
            audioStartSeconds: -12,
            audioDurationSeconds: 11,
          ),
        );

        expect(result, isA<AppError<SilenceRemovalPlan>>());
        final error = (result as AppError<SilenceRemovalPlan>).error;
        expect(error.message, contains('does not overlap'));
      },
    );

    test(
      'a pre-roll longer than the video is detected on the surviving window',
      () async {
        // Video starts at 12s and runs 10s; audio starts at 0 and runs 22s. Only
        // audio 12..22 has picture, so detection is bounded to that window and
        // `[13,14]` must cut video `[1,2]`.
        final plan = await build(
          detected: const [
            SilenceSegment(startSeconds: 1, endSeconds: 2),
            SilenceSegment(startSeconds: 13, endSeconds: 14),
          ],
          timeline: MediaTimeline.probed(
            videoDurationSeconds: 10,
            audioStartSeconds: -12,
            audioDurationSeconds: 22,
          ),
        );

        // [1,2] is pre-roll with no picture and must not be deleted.
        expect(plan.removals.length, 1);
        expect(plan.removals.single.startSeconds, closeTo(1, 1e-9));
        expect(plan.removals.single.endSeconds, closeTo(2, 1e-9));
        expect(plan.removedSeconds, closeTo(1, 1e-9));
        expect(plan.removedSeconds + plan.keptSeconds, closeTo(10, 1e-9));
        expect(
          plan.kept.first,
          const SilenceSegment(startSeconds: 0, endSeconds: 1),
        );
      },
    );
  });

  group('breathing protection only ever reduces removals', () {
    test('it never merges two silences or grows one', () async {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioDurationSeconds: 10,
      );
      final params = noVad.copyWith(useBreathingProtection: true);

      final plan = await build(
        detected: const [
          SilenceSegment(startSeconds: 1, endSeconds: 1.15),
          SilenceSegment(startSeconds: 2, endSeconds: 2.25),
          SilenceSegment(startSeconds: 5, endSeconds: 6),
        ],
        timeline: timeline,
        params: params,
      );

      // 0.15s pause is ignored, the 0.25s pause is kept whole, and the 1s
      // pause keeps 80ms before resumed speech.
      expect(plan.removals.length, 2);
      expect(plan.removals[0].startSeconds, closeTo(2, 1e-9));
      expect(plan.removals[0].endSeconds, closeTo(2.25, 1e-9));
      expect(plan.removals[1].startSeconds, closeTo(5, 1e-9));
      expect(plan.removals[1].endSeconds, closeTo(5.92, 1e-9));
      expect(plan.removedSeconds, closeTo(1.17, 1e-9));
      expect(
        plan.removedSeconds + plan.keptSeconds,
        closeTo(plan.totalDurationSeconds, 1e-9),
      );
    });

    test(
      'BreathingProtectionService keeps micro-pauses and trims the breath tail',
      () {
        final protected = BreathingProtectionService().protect(const [
          SilenceSegment(startSeconds: 0.5, endSeconds: 0.6),
          SilenceSegment(startSeconds: 1, endSeconds: 1.15),
          SilenceSegment(startSeconds: 2, endSeconds: 2.25),
          SilenceSegment(startSeconds: 5, endSeconds: 6),
        ]);

        // < 150ms is skipped, 150–250ms stays whole, and the 1s pause keeps
        // 100ms before resumed speech.
        expect(protected.length, 2);
        expect(
          protected[0],
          const SilenceSegment(startSeconds: 2, endSeconds: 2.25),
        );
        expect(protected[1].startSeconds, closeTo(5, 1e-9));
        expect(protected[1].endSeconds, closeTo(5.92, 1e-9));
        for (var i = 1; i < protected.length; i++) {
          expect(
            protected[i].startSeconds,
            greaterThanOrEqualTo(protected[i - 1].endSeconds),
          );
        }
        expect(IntervalAlgebra.totalSeconds(protected), closeTo(1.17, 1e-9));
      },
    );
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
    // Mirror the datasource contract: clamp against the caller's window.
    return detected;
  }
}

/// Stands in for the WAV reader so no plugin call is made. The production VAD
/// is exercised by its own tests; here it must be a no-op.
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
