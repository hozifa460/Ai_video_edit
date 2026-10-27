import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/features/silence_detector/domain/services/interval_algebra.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressions for the interval algebra behind SR-01, SR-02, SR-03, SR-19 and
/// review findings B01-R2/B01-R3.
///
/// Each test here previously *passed while asserting the bug* in
/// `docs/reviews/repro/silence_characterization_test.dart`. They now assert the
/// correct contract: a gap between two intervals is content and is preserved at
/// every size, a guard shrinks a removal instead of growing it, union keeps the
/// wider end, an all-invalid input yields an empty result instead of throwing,
/// and no input can produce a negative length or an overlapping result.
void main() {
  const first = SilenceSegment(startSeconds: 1, endSeconds: 2);
  const second = SilenceSegment(startSeconds: 2.2, endSeconds: 3);

  group('SR-01 gap between silences is kept (never gap-filled)', () {
    test('a 200ms speech island survives normalization', () {
      final result = IntervalAlgebra.normalize([
        first,
        second,
      ], totalDuration: 10);

      expect(result, [first, second]);
      // [1,2] is 1.0s and [2.2,3] is 0.8s; the 200ms between them is content, so
      // the removed span is 1.8s of disjoint time, not the 2.0s continuous span
      // the old merge produced.
      expect(IntervalAlgebra.totalSeconds(result), closeTo(1.8, 1e-9));
    });

    test('union never absorbs a gap', () {
      expect(IntervalAlgebra.union([first, second]), [first, second]);
    });

    test('intervals that merely touch are unioned', () {
      final result = IntervalAlgebra.normalize([
        const SilenceSegment(startSeconds: 1, endSeconds: 2),
        const SilenceSegment(startSeconds: 2, endSeconds: 3),
      ], totalDuration: 10);

      expect(result, [const SilenceSegment(startSeconds: 1, endSeconds: 3)]);
      expect(IntervalAlgebra.totalSeconds(result), closeTo(2.0, 1e-9));
    });
  });

  group('B01-R2 no positive gap is filled at any size', () {
    // The removed 20ms "sample-boundary tolerance" turned a 10ms gap into
    // deleted audio. These are the gap sizes the revision asked to be pinned.
    for (final gapMs in [1, 10, 19, 20, 21, 200]) {
      test('a ${gapMs}ms gap between two silences is preserved', () {
        final gap = gapMs / 1000;
        final secondStart = 2 + gap;

        final raw = [
          const SilenceSegment(startSeconds: 1, endSeconds: 2),
          SilenceSegment(startSeconds: secondStart, endSeconds: 3),
        ];

        expect(
          IntervalAlgebra.union(raw),
          raw,
          reason: 'a ${gapMs}ms gap is content, not boundary jitter',
        );

        final normalized = IntervalAlgebra.normalize(raw, totalDuration: 10);
        expect(normalized, raw);
        // The kept ranges prove the gap survives as content.
        final kept = IntervalAlgebra.complement(
          normalized,
          totalDurationSeconds: 10,
        );
        expect(
          kept.any((k) => (k.durationSeconds - gap).abs() < 1e-9),
          isTrue,
          reason: 'the ${gapMs}ms island must appear as a kept range',
        );
      });
    }

    test('a 1ns gap is still a gap', () {
      final raw = [
        const SilenceSegment(startSeconds: 1, endSeconds: 2),
        const SilenceSegment(startSeconds: 2.000000001, endSeconds: 3),
      ];
      expect(IntervalAlgebra.union(raw), raw);
    });

    test('true overlap and exact touch still merge', () {
      expect(
        IntervalAlgebra.union([
          const SilenceSegment(startSeconds: 1, endSeconds: 2.5),
          const SilenceSegment(startSeconds: 2, endSeconds: 3),
        ]),
        [const SilenceSegment(startSeconds: 1, endSeconds: 3)],
      );
      expect(
        IntervalAlgebra.union([
          const SilenceSegment(startSeconds: 1, endSeconds: 2),
          const SilenceSegment(startSeconds: 2, endSeconds: 3),
        ]),
        [const SilenceSegment(startSeconds: 1, endSeconds: 3)],
      );
    });
  });

  group('B01-R3 union survives an input with no valid interval', () {
    test('invalid-only input returns empty instead of throwing', () {
      expect(
        IntervalAlgebra.union(const [
          SilenceSegment(startSeconds: 1, endSeconds: 1),
          SilenceSegment(startSeconds: 5, endSeconds: 2),
          SilenceSegment(startSeconds: double.nan, endSeconds: 3),
        ]),
        isEmpty,
      );
    });

    test('normalize also tolerates an invalid-only input', () {
      expect(
        IntervalAlgebra.normalize(const [
          SilenceSegment(startSeconds: 3, endSeconds: 3),
          SilenceSegment(
            startSeconds: double.infinity,
            endSeconds: double.infinity,
          ),
          SilenceSegment(startSeconds: 4, endSeconds: 1),
        ], totalDuration: 10),
        isEmpty,
      );
    });

    test('mixed valid and invalid input keeps exactly the valid intervals', () {
      final result = IntervalAlgebra.union(const [
        SilenceSegment(startSeconds: 1, endSeconds: 1),
        SilenceSegment(startSeconds: 5, endSeconds: 6),
        SilenceSegment(startSeconds: double.nan, endSeconds: 7),
        SilenceSegment(startSeconds: 8, endSeconds: 8),
        SilenceSegment(startSeconds: 9, endSeconds: 7),
        SilenceSegment(startSeconds: 9.5, endSeconds: 10),
      ]);

      expect(result, [
        const SilenceSegment(startSeconds: 5, endSeconds: 6),
        const SilenceSegment(startSeconds: 9.5, endSeconds: 10),
      ]);
    });

    test('totalSeconds measures 0 for an invalid-only input', () {
      expect(
        IntervalAlgebra.totalSeconds(const [
          SilenceSegment(startSeconds: 2, endSeconds: 1),
          SilenceSegment(startSeconds: double.nan, endSeconds: 1),
        ]),
        0,
      );
    });

    test('applyProtectedPadding tolerates an invalid-only input', () {
      expect(
        IntervalAlgebra.applyProtectedPadding(
          const [
            SilenceSegment(startSeconds: 2, endSeconds: 1),
            SilenceSegment(startSeconds: 3, endSeconds: 3),
          ],
          paddingBefore: 0.1,
          paddingAfter: 0.1,
          totalDuration: 10,
        ),
        isEmpty,
      );
    });

    test('complement skips invalid intervals without throwing', () {
      expect(
        IntervalAlgebra.complement(const [
          SilenceSegment(startSeconds: 2, endSeconds: 1),
          SilenceSegment(startSeconds: 3, endSeconds: 5),
        ], totalDurationSeconds: 10),
        [
          const SilenceSegment(startSeconds: 0, endSeconds: 3),
          const SilenceSegment(startSeconds: 5, endSeconds: 10),
        ],
      );
    });
  });

  group('SR-19 union keeps the widest end', () {
    test('a contained interval does not shrink the union', () {
      final result = IntervalAlgebra.union([
        const SilenceSegment(startSeconds: 1, endSeconds: 5),
        const SilenceSegment(startSeconds: 2, endSeconds: 3),
      ]);

      expect(result, [const SilenceSegment(startSeconds: 1, endSeconds: 5)]);
      expect(IntervalAlgebra.totalSeconds(result), closeTo(4.0, 1e-9));
    });

    test('identical intervals collapse to one', () {
      final result = IntervalAlgebra.union([first, first]);
      expect(result, [first]);
    });

    test('unsorted input produces the same canonical output', () {
      final sorted = IntervalAlgebra.union([
        const SilenceSegment(startSeconds: 1, endSeconds: 2),
        const SilenceSegment(startSeconds: 5, endSeconds: 6),
        const SilenceSegment(startSeconds: 3, endSeconds: 4),
      ]);
      final unsorted = IntervalAlgebra.union([
        const SilenceSegment(startSeconds: 5, endSeconds: 6),
        const SilenceSegment(startSeconds: 3, endSeconds: 4),
        const SilenceSegment(startSeconds: 1, endSeconds: 2),
      ]);

      expect(unsorted, sorted);
      expect(sorted.map((s) => s.startSeconds), [1.0, 3.0, 5.0]);
      for (var i = 1; i < sorted.length; i++) {
        expect(
          sorted[i].startSeconds,
          greaterThanOrEqualTo(sorted[i - 1].endSeconds),
        );
      }
    });

    test('nested intervals in any order keep the outer bounds', () {
      expect(
        IntervalAlgebra.union([
          const SilenceSegment(startSeconds: 2, endSeconds: 3),
          const SilenceSegment(startSeconds: 1, endSeconds: 5),
        ]),
        [const SilenceSegment(startSeconds: 1, endSeconds: 5)],
      );
    });
  });

  group('SR-02 guards shrink removals and never grow them', () {
    test('guarding 150ms on each side keeps the middle of the silence', () {
      final result = IntervalAlgebra.applyProtectedPadding(
        [first],
        paddingBefore: 0.15,
        paddingAfter: 0.15,
        totalDuration: 10,
      );

      expect(result.single.startSeconds, closeTo(1.15, 1e-9));
      expect(result.single.endSeconds, closeTo(1.85, 1e-9));
      // The old behaviour expanded to [0.85, 2.15] and deleted 300ms of
      // neighbouring speech.
      expect(result.single.startSeconds, greaterThan(first.startSeconds));
      expect(result.single.endSeconds, lessThan(first.endSeconds));
    });

    test('raising a guard can only reduce the removed time', () {
      double removedFor(double guard) => IntervalAlgebra.totalSeconds(
        IntervalAlgebra.applyProtectedPadding(
          [first],
          paddingBefore: guard,
          paddingAfter: guard,
          totalDuration: 10,
        ),
      );

      final none = removedFor(0);
      final fiftyMs = removedFor(0.05);
      final oneFiftyMs = removedFor(0.15);
      final fiveHundredMs = removedFor(0.5);

      expect(none, closeTo(1.0, 1e-9));
      expect(fiftyMs, lessThan(none));
      expect(oneFiftyMs, lessThan(fiftyMs));
      expect(fiveHundredMs, lessThan(oneFiftyMs));
      // The guard amount is honoured exactly on both sides.
      expect(fiveHundredMs, closeTo(0.0, 1e-9));
    });

    test('a guard that consumes the whole interval removes it entirely', () {
      final result = IntervalAlgebra.applyProtectedPadding(
        [const SilenceSegment(startSeconds: 1, endSeconds: 1.1)],
        paddingBefore: 0.05,
        paddingAfter: 0.05,
        totalDuration: 10,
      );
      expect(result, isEmpty);
    });

    test('a guard touching one edge exactly leaves a zero-length interval', () {
      final result = IntervalAlgebra.applyProtectedPadding(
        [const SilenceSegment(startSeconds: 1, endSeconds: 2)],
        paddingBefore: 0.5,
        paddingAfter: 0.5,
        totalDuration: 10,
      );
      expect(result, isEmpty);
    });

    test('guards never push a removal outside the timeline', () {
      final result = IntervalAlgebra.applyProtectedPadding(
        [const SilenceSegment(startSeconds: 0, endSeconds: 1)],
        paddingBefore: 0.4,
        paddingAfter: 0.4,
        totalDuration: 1,
      );
      expect(result.single.startSeconds, greaterThanOrEqualTo(0));
      expect(result.single.endSeconds, lessThanOrEqualTo(1));
      expect(result.single.endSeconds, greaterThan(result.single.startSeconds));
    });

    test('guards cannot make previously disjoint intervals overlap', () {
      final result = IntervalAlgebra.applyProtectedPadding(
        [
          const SilenceSegment(startSeconds: 1, endSeconds: 2),
          const SilenceSegment(startSeconds: 2.6, endSeconds: 3.5),
        ],
        paddingBefore: 0.1,
        paddingAfter: 0.1,
        totalDuration: 10,
      );

      expect(result, [
        const SilenceSegment(startSeconds: 1.1, endSeconds: 1.9),
        const SilenceSegment(startSeconds: 2.7, endSeconds: 3.4),
      ]);
      for (var i = 1; i < result.length; i++) {
        expect(
          result[i].startSeconds,
          greaterThanOrEqualTo(result[i - 1].endSeconds),
        );
      }
      expect(
        IntervalAlgebra.totalSeconds(result) +
            IntervalAlgebra.totalSeconds(
              IntervalAlgebra.complement(result, totalDurationSeconds: 10),
            ),
        closeTo(10, 1e-9),
      );
    });

    test('500ms guards on a 1s and a 0.9s silence delete neither', () {
      // The old padding expanded these two intervals into each other; the new
      // guards shrink both below the minimum length, so nothing is removed.
      final result = IntervalAlgebra.applyProtectedPadding(
        [
          const SilenceSegment(startSeconds: 1, endSeconds: 2),
          const SilenceSegment(startSeconds: 2.6, endSeconds: 3.5),
        ],
        paddingBefore: 0.5,
        paddingAfter: 0.5,
        totalDuration: 10,
      );

      expect(result, isEmpty);
    });
  });

  group('SR-03 normalization rejects hostile input deterministically', () {
    test('NaN and Infinity bounds are dropped, never clamped', () {
      final result = IntervalAlgebra.normalize([
        const SilenceSegment(startSeconds: double.nan, endSeconds: 5),
        const SilenceSegment(startSeconds: 1, endSeconds: double.infinity),
        const SilenceSegment(
          startSeconds: double.negativeInfinity,
          endSeconds: 5,
        ),
        first,
      ], totalDuration: 10);

      expect(result, [first]);
    });

    test('inverted and zero-length intervals are dropped', () {
      final result = IntervalAlgebra.normalize([
        const SilenceSegment(startSeconds: 5, endSeconds: 2),
        const SilenceSegment(startSeconds: 3, endSeconds: 3),
        first,
      ], totalDuration: 10);

      expect(result, [first]);
    });

    test('intervals are clamped to [0, totalDuration]', () {
      final result = IntervalAlgebra.normalize([
        const SilenceSegment(startSeconds: -3, endSeconds: 1),
        const SilenceSegment(startSeconds: 9, endSeconds: 30),
      ], totalDuration: 10);

      expect(result, [
        const SilenceSegment(startSeconds: 0, endSeconds: 1),
        const SilenceSegment(startSeconds: 9, endSeconds: 10),
      ]);
    });

    test('a negative or non-finite duration cannot resurrect content', () {
      for (final total in [0.0, -5.0, double.nan, double.infinity]) {
        final result = IntervalAlgebra.normalize([first], totalDuration: total);
        expect(
          result,
          isEmpty,
          reason: 'totalDuration=$total must delete nothing',
        );
      }
    });

    test('totalSeconds measures the union, not a raw sum', () {
      final overlapping = [
        const SilenceSegment(startSeconds: 1, endSeconds: 2),
        const SilenceSegment(startSeconds: 1.5, endSeconds: 2.5),
      ];
      // Raw sum would be 1.5s; the union is 1.5s too, so use a nested case.
      expect(IntervalAlgebra.totalSeconds(overlapping), closeTo(1.5, 1e-9));

      final nested = [
        const SilenceSegment(startSeconds: 1, endSeconds: 5),
        const SilenceSegment(startSeconds: 2, endSeconds: 3),
      ];
      final rawSum = nested.fold<double>(
        0,
        (sum, s) => sum + s.durationSeconds,
      );
      expect(rawSum, closeTo(5.0, 1e-9));
      expect(IntervalAlgebra.totalSeconds(nested), closeTo(4.0, 1e-9));
    });
  });

  group('complement covers the timeline exactly once', () {
    test('kept ranges are the complement inside the duration', () {
      final kept = IntervalAlgebra.complement([
        first,
      ], totalDurationSeconds: 10);

      expect(kept, [
        const SilenceSegment(startSeconds: 0, endSeconds: 1),
        const SilenceSegment(startSeconds: 2, endSeconds: 10),
      ]);
    });

    test('no removals means one kept range', () {
      final kept = IntervalAlgebra.complement(
        const [],
        totalDurationSeconds: 10,
      );
      expect(kept, [const SilenceSegment(startSeconds: 0, endSeconds: 10)]);
    });

    test('a removal covering everything leaves nothing kept', () {
      final kept = IntervalAlgebra.complement([
        const SilenceSegment(startSeconds: 0, endSeconds: 10),
      ], totalDurationSeconds: 10);
      expect(kept, isEmpty);
    });

    test('removed plus kept always equals the timeline', () {
      final normalized = IntervalAlgebra.normalize([
        const SilenceSegment(startSeconds: 1, endSeconds: 2),
        const SilenceSegment(startSeconds: 2.6, endSeconds: 3.5),
        const SilenceSegment(startSeconds: 8, endSeconds: 9),
      ], totalDuration: 10);
      final kept = IntervalAlgebra.complement(
        normalized,
        totalDurationSeconds: 10,
      );

      final removed = IntervalAlgebra.totalSeconds(normalized);
      final keptTotal = IntervalAlgebra.totalSeconds(kept);
      expect(removed, closeTo(1 + 0.9 + 1, 1e-9));
      expect(removed + keptTotal, closeTo(10, 1e-9));
      expect(removed, lessThanOrEqualTo(10));
      expect(kept.every((k) => k.durationSeconds > 0), isTrue);
    });
  });

  test('segment validity helpers reject non-finite and inverted ranges', () {
    expect(first.isValid, isTrue);
    expect(first.hasFiniteBounds, isTrue);
    expect(
      const SilenceSegment(startSeconds: double.nan, endSeconds: 1).isValid,
      isFalse,
    );
    expect(
      const SilenceSegment(startSeconds: 2, endSeconds: 1).isValid,
      isFalse,
    );
    expect(first.contains(1.5), isTrue);
    expect(first.contains(2.0), isTrue);
    expect(first.contains(2.1), isFalse);
    expect(first.overlaps(second), isFalse);
    expect(
      first.overlaps(const SilenceSegment(startSeconds: 1.5, endSeconds: 3)),
      isTrue,
    );
  });
}
