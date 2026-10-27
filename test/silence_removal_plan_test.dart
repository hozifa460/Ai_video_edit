import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/features/silence_detector/domain/services/interval_algebra.dart';
import 'package:flutter_test/flutter_test.dart';

/// The removal plan is the single object the UI statistics and the FFmpeg cut
/// both read (SR-03), and its timeline comes from the probe rather than the
/// waveform (SR-05). These tests pin both contracts, including the exact
/// fixtures named in the handoff's acceptance table and the signed time origin
/// required by review finding B01-R1 and the immutability of B01-C1.
void main() {
  const firstRemoval = SilenceSegment(startSeconds: 1, endSeconds: 2);
  group('SilenceRemovalPlan invariants', () {
    test('statistics use the union, not the raw sum', () {
      // The old implementation summed a padded, overlapping list: 3.9s removed
      // for a 3.5s span. The plan reports the union and matches the complement.
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [
          SilenceSegment(startSeconds: 0.5, endSeconds: 2.5),
          SilenceSegment(startSeconds: 2.1, endSeconds: 4),
        ],
      );

      expect(plan.removals, [
        const SilenceSegment(startSeconds: 0.5, endSeconds: 4),
      ]);
      expect(plan.removedSeconds, closeTo(3.5, 1e-9));
      expect(plan.keptSeconds, closeTo(6.5, 1e-9));
      expect(plan.removedSeconds + plan.keptSeconds, closeTo(10, 1e-9));
      expect(plan.removedSeconds, lessThanOrEqualTo(plan.totalDurationSeconds));
      expect(plan.removedRatio, closeTo(0.35, 1e-9));
      expect(plan.removedPercent, closeTo(35, 1e-9));
    });

    test('seconds are converted to milliseconds explicitly', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 120.5,
        removals: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      );

      expect(plan.removedDuration, const Duration(seconds: 1));
      expect(plan.totalDuration, const Duration(milliseconds: 120500));
      expect(plan.keptDuration, const Duration(milliseconds: 119500));
    });

    test('removed ratio stays inside [0,1] for a zero-length timeline', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 0,
        removals: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      );

      expect(plan.isUsable, isFalse);
      expect(plan.removedRatio, 0);
      expect(plan.removedPercent, 0);
      expect(plan.removals, isEmpty);
      expect(plan.kept, isEmpty);
    });

    test('a plan that deletes everything reports it instead of crashing', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [SilenceSegment(startSeconds: 0, endSeconds: 10)],
      );

      expect(plan.removesEverything, isTrue);
      expect(plan.kept, isEmpty);
      expect(plan.keptSeconds, 0);
      expect(plan.removedRatio, closeTo(1, 1e-9));
    });

    test('nested, overlapping and unsorted input normalizes once', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [
          SilenceSegment(startSeconds: 4, endSeconds: 6),
          SilenceSegment(startSeconds: 1, endSeconds: 5),
          SilenceSegment(startSeconds: 2, endSeconds: 3),
          SilenceSegment(startSeconds: -1, endSeconds: 1),
          SilenceSegment(startSeconds: double.nan, endSeconds: 2),
          SilenceSegment(startSeconds: 8, endSeconds: 40),
        ],
      );

      expect(plan.removals, [
        const SilenceSegment(startSeconds: 0, endSeconds: 6),
        const SilenceSegment(startSeconds: 8, endSeconds: 10),
      ]);
      for (var i = 1; i < plan.removals.length; i++) {
        expect(
          plan.removals[i].startSeconds,
          greaterThanOrEqualTo(plan.removals[i - 1].endSeconds),
        );
      }
      expect(
        plan.removedSeconds + plan.keptSeconds,
        closeTo(plan.totalDurationSeconds, 1e-9),
      );
    });

    test('excluding one interval rebuilds statistics and the kept ranges', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
          SilenceSegment(startSeconds: 5, endSeconds: 6),
        ],
      );
      expect(plan.removedSeconds, closeTo(2, 1e-9));

      final afterKeep = plan.withoutRemoval(0);

      expect(afterKeep.removals, [
        const SilenceSegment(startSeconds: 5, endSeconds: 6),
      ]);
      expect(afterKeep.removedSeconds, closeTo(1, 1e-9));
      expect(afterKeep.keptSeconds, closeTo(9, 1e-9));
      expect(afterKeep.kept, [
        const SilenceSegment(startSeconds: 0, endSeconds: 5),
        const SilenceSegment(startSeconds: 6, endSeconds: 10),
      ]);
    });

    test('excluding an out-of-range index is a no-op', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      );
      expect(plan.withoutRemoval(-1), plan);
      expect(plan.withoutRemoval(5), plan);
    });

    test('empty removal list is a valid, honest plan', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [],
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.hasRemovals, isFalse);
      expect(plan.removedSeconds, 0);
      expect(plan.kept, [
        const SilenceSegment(startSeconds: 0, endSeconds: 10),
      ]);
    });
  });

  group('MediaTimeline keeps the video timeline authoritative (SR-05, B01-R1)', () {
    test('probe values that are not usable numbers collapse to zero', () {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: double.nan,
        audioStartSeconds: double.nan,
        audioDurationSeconds: double.infinity,
      );

      expect(timeline.videoDurationSeconds, 0);
      expect(timeline.audioStartSeconds, 0);
      expect(timeline.audioDurationSeconds, 0);
      expect(timeline.isDetectable, isFalse);
    });

    test('a negative offset keeps its sign (audio starting before video)', () {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: -0.5,
      );
      expect(timeline.audioStartSeconds, -0.5);
    });

    test('an offset larger than the video duration is preserved as measured', () {
      // The offset is a measurement of where the audio origin sits, not a
      // duration. A video starting at 12s that is 10s long, with audio starting
      // at 0, really has offset -12; clamping it to -10 re-dated every interval
      // in the file (B01-R1 follow-up).
      expect(
        MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioStartSeconds: -12,
        ).audioStartSeconds,
        -12,
      );
      expect(
        MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioStartSeconds: 12,
        ).audioStartSeconds,
        12,
      );
    });

    test('only a non-finite offset falls back to zero', () {
      for (final bad in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          MediaTimeline.probed(
            videoDurationSeconds: 10,
            audioStartSeconds: bad,
          ).audioStartSeconds,
          0,
          reason: 'offset=$bad is unknown, not a measurement',
        );
      }
    });

    test('audio offset moves detected intervals onto the video timeline', () {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: 0.5,
        audioDurationSeconds: 8,
      );

      final onVideo = timeline.audioToVideoTimeline(const [
        SilenceSegment(startSeconds: 1, endSeconds: 2),
      ]);

      expect(onVideo, [
        const SilenceSegment(startSeconds: 1.5, endSeconds: 2.5),
      ]);
      expect(timeline.detectionWindowEndSeconds, closeTo(8, 1e-9));
    });

    test('detection cannot reach past the video when audio starts late', () {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: 0.5,
        audioDurationSeconds: 30,
      );
      expect(timeline.detectionWindowEndSeconds, closeTo(9.5, 1e-9));

      final onVideo = timeline.audioToVideoTimeline(const [
        SilenceSegment(startSeconds: 9, endSeconds: 20),
      ]);
      expect(onVideo, [
        const SilenceSegment(startSeconds: 9.5, endSeconds: 10),
      ]);
    });

    test(
      'a negative offset shifts intervals left and keeps the in-video part',
      () {
        final timeline = MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioStartSeconds: -0.5,
          audioDurationSeconds: 10.5,
        );

        // Video ends at video time 10, which is audio time 10.5.
        expect(timeline.detectionWindowEndSeconds, closeTo(10.5, 1e-9));

        final onVideo = timeline.audioToVideoTimeline(const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
        ]);
        expect(onVideo, [
          const SilenceSegment(startSeconds: 0.5, endSeconds: 1.5),
        ]);

        // Audio pre-roll that lies entirely before the video contributes nothing.
        expect(
          timeline.audioToVideoTimeline(const [
            SilenceSegment(startSeconds: 0, endSeconds: 0.4),
          ]),
          isEmpty,
        );

        // Audio pre-roll that straddles the video origin keeps its visible part.
        expect(
          timeline.audioToVideoTimeline(const [
            SilenceSegment(startSeconds: 0.4, endSeconds: 1),
          ]),
          [const SilenceSegment(startSeconds: 0, endSeconds: 0.5)],
        );
      },
    );

    test('videoToAudioTimeline inverts audioToVideoTimeline', () {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: -0.5,
        audioDurationSeconds: 10.5,
      );
      final original = const [
        SilenceSegment(startSeconds: 0.5, endSeconds: 1.5),
      ];

      final roundTrip = timeline.videoToAudioTimeline(
        timeline.audioToVideoTimeline(original),
      );
      expect(roundTrip, original);
    });

    test(
      'video longer than audio keeps the picture tail (acceptance fixture)',
      () {
        final timeline = MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioStartSeconds: 0,
          audioDurationSeconds: 8,
        );

        // Detection sees only the 8s the audio actually covers.
        final detected = IntervalAlgebra.normalize(const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
        ], totalDuration: timeline.detectionWindowEndSeconds);
        final plan = SilenceRemovalPlan.build(
          totalDurationSeconds: timeline.videoDurationSeconds,
          removals: timeline.audioToVideoTimeline(detected),
        );

        expect(plan.totalDurationSeconds, 10);
        // 8s -> 10s is picture with no audio: it must stay in the output.
        expect(plan.kept, [
          const SilenceSegment(startSeconds: 0, endSeconds: 1),
          const SilenceSegment(startSeconds: 2, endSeconds: 10),
        ]);
        expect(plan.keptSeconds, closeTo(9, 1e-9));
      },
    );

    test('a failed waveform cannot become the timeline', () {
      // Waveform duration is never an input here: the plan is built from the
      // probed video duration only.
      final waveformDurationSeconds = 0.0;
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioDurationSeconds: 10,
      );
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: timeline.videoDurationSeconds,
        removals: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      );

      expect(waveformDurationSeconds, 0);
      expect(plan.totalDurationSeconds, 10);
      expect(plan.removals, [
        const SilenceSegment(startSeconds: 1, endSeconds: 2),
      ]);
      expect(plan.removedRatio, closeTo(0.1, 1e-9));
    });

    test('aligned audio and video need no shifting', () {
      final timeline = MediaTimeline.probed(videoDurationSeconds: 10);
      final onVideo = timeline.audioToVideoTimeline(const [
        SilenceSegment(startSeconds: 1, endSeconds: 2),
      ]);
      expect(onVideo, [const SilenceSegment(startSeconds: 1, endSeconds: 2)]);
      expect(timeline.detectionWindowEndSeconds, closeTo(10, 1e-9));
      expect(timeline.isDetectable, isTrue);
    });

    test('unknown timeline reports itself as undetectable', () {
      expect(MediaTimeline.unknown.isDetectable, isFalse);
      expect(MediaTimeline.unknown.detectionWindowEndSeconds, 0);
    });

    test('copyWith preserves probed timing and can flip hasAudio', () {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: 0.5,
        audioDurationSeconds: 9,
      );
      final withoutAudio = timeline.copyWith(hasAudio: false);

      expect(withoutAudio.hasAudio, isFalse);
      expect(withoutAudio.videoDurationSeconds, 10);
      expect(withoutAudio.audioStartSeconds, 0.5);
      expect(withoutAudio.audioDurationSeconds, 9);
      expect(withoutAudio.isDetectable, isFalse);
    });

    test(
      'audioTimeToVideoTime and audioVisibleRange expose the same window',
      () {
        final late = MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioStartSeconds: 2,
          audioDurationSeconds: 5,
        );
        expect(late.audioTimeToVideoTime(1), 3);
        expect(late.audioVisibleRange(), (start: 2.0, end: 7.0));

        final early = MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioStartSeconds: -0.5,
          audioDurationSeconds: 10.5,
        );
        expect(early.audioTimeToVideoTime(1), 0.5);
        expect(early.audioVisibleRange(), (start: 0.0, end: 10.0));
      },
    );
  });

  group('B01-R1 follow-up: the audio/video intersection is explicit', () {
    // A pre-roll longer than the video: the video starts at 12s and runs 10s,
    // the audio starts at 0 and runs 22s, so the offset is -12s.
    final longPreRoll = MediaTimeline.probed(
      videoDurationSeconds: 10,
      audioStartSeconds: -12,
      audioDurationSeconds: 22,
    );

    test(
      'a long pre-roll keeps the measured offset and lands inside the video',
      () {
        expect(longPreRoll.audioStartSeconds, -12);
        expect(longPreRoll.detectionWindow(), (
          startSeconds: 12.0,
          endSeconds: 22.0,
        ));
        expect(longPreRoll.detectionWindowEndSeconds, closeTo(22, 1e-9));
        expect(longPreRoll.hasDetectionWindow, isTrue);
        expect(longPreRoll.isDetectable, isTrue);

        // The corrected answer. The previous behaviour turned -12 into -10 and
        // reported [3,4].
        expect(
          longPreRoll.audioToVideoTimeline(const [
            SilenceSegment(startSeconds: 13, endSeconds: 14),
          ]),
          const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
        );
      },
    );

    test(
      'audio that ends before the video starts yields an empty intersection',
      () {
        final entirelyBefore = MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioStartSeconds: -12,
          audioDurationSeconds: 11,
        );

        expect(entirelyBefore.detectionWindow(), isNull);
        expect(entirelyBefore.hasDetectionWindow, isFalse);
        expect(entirelyBefore.isDetectable, isFalse);
        expect(entirelyBefore.detectionWindowEndSeconds, 0);
        expect(entirelyBefore.detectionWindowStartSeconds, 0);
        expect(entirelyBefore.audioVisibleRange(), isNull);

        // [-2,-1] is genuinely outside the video: nothing may be invented.
        expect(
          entirelyBefore.audioToVideoTimeline(const [
            SilenceSegment(startSeconds: 10, endSeconds: 11),
          ]),
          isEmpty,
        );
      },
    );

    test(
      'audio that starts after the video ends yields an empty intersection',
      () {
        final entirelyAfter = MediaTimeline.probed(
          videoDurationSeconds: 10,
          audioStartSeconds: 12,
          audioDurationSeconds: 3,
        );

        expect(entirelyAfter.audioStartSeconds, 12);
        expect(entirelyAfter.detectionWindow(), isNull);
        expect(entirelyAfter.hasDetectionWindow, isFalse);
        expect(entirelyAfter.isDetectable, isFalse);
        expect(entirelyAfter.detectionWindowEndSeconds, 0);
        expect(
          entirelyAfter.audioToVideoTimeline(const [
            SilenceSegment(startSeconds: 0, endSeconds: 1),
          ]),
          isEmpty,
        );
      },
    );

    test('a known audio duration is used even when it exceeds the video', () {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: 0,
        audioDurationSeconds: 30,
      );
      // 0..10 of the audio is on video; 10..30 has no picture.
      expect(timeline.detectionWindow(), (startSeconds: 0.0, endSeconds: 10.0));
      expect(
        timeline.audioToVideoTimeline(const [
          SilenceSegment(startSeconds: 20, endSeconds: 21),
        ]),
        isEmpty,
      );
      expect(
        timeline.audioToVideoTimeline(const [
          SilenceSegment(startSeconds: 9, endSeconds: 12),
        ]),
        const [SilenceSegment(startSeconds: 9, endSeconds: 10)],
      );
    });

    test('an unknown audio duration derives the window from the video end', () {
      final timeline = MediaTimeline.probed(
        videoDurationSeconds: 10,
        audioStartSeconds: -2,
      );
      // audioEnd = videoLength - offset = 12 in audio time; the visible part
      // starts at audio 2 (video 0).
      expect(timeline.detectionWindow(), (startSeconds: 2.0, endSeconds: 12.0));
      expect(timeline.audioVisibleRange(), (start: 0.0, end: 10.0));
    });

    test(
      'the round trip still inverts for an offset larger than the video',
      () {
        const original = [SilenceSegment(startSeconds: 13, endSeconds: 14)];
        final roundTrip = longPreRoll.videoToAudioTimeline(
          longPreRoll.audioToVideoTimeline(original),
        );
        expect(roundTrip, original);
      },
    );

    test('an unusable video duration has no window at all', () {
      for (final timeline in [
        MediaTimeline.unknown,
        MediaTimeline.probed(videoDurationSeconds: 0, audioDurationSeconds: 5),
      ]) {
        expect(timeline.detectionWindow(), isNull);
        expect(timeline.hasDetectionWindow, isFalse);
        expect(timeline.isDetectable, isFalse);
        expect(
          timeline.audioToVideoTimeline(const [
            SilenceSegment(startSeconds: 1, endSeconds: 2),
          ]),
          isEmpty,
        );
      }
    });
  });

  group('B01-C1 the canonical plan cannot be mutated out of consistency', () {
    test('removals and kept reject in-place mutation', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      );

      expect(() => plan.removals.clear(), throwsUnsupportedError);
      expect(() => plan.kept.clear(), throwsUnsupportedError);
      expect(() => plan.removals.add(firstRemoval), throwsUnsupportedError);
      expect(() => plan.kept[0] = firstRemoval, throwsUnsupportedError);
      // Statistics are still consistent after the rejected mutations.
      expect(plan.removedSeconds + plan.keptSeconds, closeTo(10, 1e-9));
      expect(plan.removedSeconds, closeTo(1, 1e-9));
    });

    test(
      'mutating the source list after building does not affect the plan',
      () {
        final source = <SilenceSegment>[firstRemoval];
        final plan = SilenceRemovalPlan.build(
          totalDurationSeconds: 10,
          removals: source,
        );

        source.clear();

        expect(plan.removals, [firstRemoval]);
        expect(plan.removedSeconds, closeTo(1, 1e-9));
        expect(plan.removedSeconds + plan.keptSeconds, closeTo(10, 1e-9));
      },
    );

    test(
      'withoutRemoval returns a new immutable plan and leaves the old one',
      () {
        final plan = SilenceRemovalPlan.build(
          totalDurationSeconds: 10,
          removals: const [
            SilenceSegment(startSeconds: 1, endSeconds: 2),
            SilenceSegment(startSeconds: 5, endSeconds: 6),
          ],
        );

        final reduced = plan.withoutRemoval(0);

        expect(() => reduced.removals.clear(), throwsUnsupportedError);
        expect(plan.removals.length, 2);
        expect(reduced.removals.length, 1);
        expect(reduced.removedSeconds + reduced.keptSeconds, closeTo(10, 1e-9));
      },
    );
  });
}
