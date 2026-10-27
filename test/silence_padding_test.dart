import 'package:ai_video_editing/features/silence_detector/data/repositories/silence_detector_repository_impl.dart';
import 'package:ai_video_editing/features/silence_detector/data/services/breathing_protection_service.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final repository = SilenceDetectorRepositoryImpl();

  group('speech guards shrink silence from the inside', () {
    test('padding removes guarded edges, never neighbouring speech', () {
      final result = repository.applyPadding(
        const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
        paddingBefore: 0.15,
        paddingAfter: 0.15,
        totalDuration: 10,
      );

      expect(result, const [
        SilenceSegment(startSeconds: 1.15, endSeconds: 1.85),
      ]);
      // The old inverted formula produced [0.85, 2.15], deleting 300ms of the
      // words on both sides of the silence.
      expect(result.single.startSeconds, greaterThan(1));
      expect(result.single.endSeconds, lessThan(2));
    });

    test('raising the guard can only remove less audio', () {
      double removedFor(double guard) {
        final result = repository.applyPadding(
          const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
          paddingBefore: guard,
          paddingAfter: guard,
          totalDuration: 10,
        );
        return result.fold(0.0, (sum, s) => sum + s.durationSeconds);
      }

      final none = removedFor(0);
      final fifty = removedFor(0.05);
      final oneFifty = removedFor(0.15);

      expect(none, closeTo(1.0, 1e-9));
      expect(fifty, closeTo(0.9, 1e-9));
      expect(oneFifty, closeTo(0.7, 1e-9));
      expect(fifty, lessThan(none));
      expect(oneFifty, lessThan(fifty));
    });

    test('a guarded remainder below 50ms is discarded', () {
      final result = repository.applyPadding(
        const [SilenceSegment(startSeconds: 1, endSeconds: 1.1)],
        paddingBefore: 0.03,
        paddingAfter: 0.03,
        totalDuration: 10,
      );

      expect(result, isEmpty);
    });

    test('an unguarded short detection survives the guard floor', () {
      // SR-06: at min=10ms the datasource already accepted this interval.
      // The 50ms guard floor must not silently override that verdict when no
      // guard was requested.
      final result = repository.applyPadding(
        const [SilenceSegment(startSeconds: 3600.01, endSeconds: 3600.02)],
        paddingBefore: 0,
        paddingAfter: 0,
        totalDuration: 3600.02,
      );

      expect(result, const [
        SilenceSegment(startSeconds: 3600.01, endSeconds: 3600.02),
      ]);
    });

    test('a guarded remainder of exactly 50ms is kept', () {
      final result = repository.applyPadding(
        const [SilenceSegment(startSeconds: 1, endSeconds: 1.15)],
        paddingBefore: 0.05,
        paddingAfter: 0.05,
        totalDuration: 10,
      );

      expect(result.length, 1);
      expect(result.single.startSeconds, closeTo(1.05, 1e-9));
      expect(result.single.endSeconds, closeTo(1.10, 1e-9));
    });

    test('end <= start is discarded instead of inverted or zero-length', () {
      final result = repository.applyPadding(
        const [SilenceSegment(startSeconds: 1, endSeconds: 1.2)],
        paddingBefore: 0.1,
        paddingAfter: 0.1,
        totalDuration: 10,
      );

      expect(result, isEmpty);
    });

    test('guarded bounds are clamped to the timeline', () {
      final result = repository.applyPadding(
        const [SilenceSegment(startSeconds: 0, endSeconds: 0.5)],
        paddingBefore: 0.1,
        paddingAfter: 0.1,
        totalDuration: 0.2,
      );

      expect(result, const [
        SilenceSegment(startSeconds: 0.1, endSeconds: 0.2),
      ]);
    });

    test('invalid bounds never enter the padded result', () {
      final result = repository.applyPadding(
        const [
          SilenceSegment(startSeconds: double.nan, endSeconds: 3),
          SilenceSegment(startSeconds: 2, endSeconds: 1),
          SilenceSegment(startSeconds: 4, endSeconds: 5),
        ],
        paddingBefore: 0,
        paddingAfter: 0,
        totalDuration: 10,
      );

      expect(result, const [SilenceSegment(startSeconds: 4, endSeconds: 5)]);
    });
  });

  group('breathing protection preserves breath tails', () {
    test('micro-silences below 150ms are not cut', () {
      final protected = BreathingProtectionService().protect(const [
        SilenceSegment(startSeconds: 1, endSeconds: 1.149),
      ]);
      expect(protected, isEmpty);
    });

    test('a 150ms pause is ignored as shorter than the minimum', () {
      final protected = BreathingProtectionService().protect(const [
        SilenceSegment(startSeconds: 1, endSeconds: 1.15),
      ]);
      expect(protected, isEmpty);
    });

    test('a pause just over 250ms pulls back 80ms before speech', () {
      final protected = BreathingProtectionService().protect(const [
        SilenceSegment(startSeconds: 1, endSeconds: 1.26),
      ]);
      expect(protected.single.startSeconds, closeTo(1, 1e-9));
      expect(protected.single.endSeconds, closeTo(1.18, 1e-9));
    });

    test('a long pause is trimmed by 80ms at its speech-facing tail', () {
      final protected = BreathingProtectionService().protect(const [
        SilenceSegment(startSeconds: 1, endSeconds: 3),
      ]);
      expect(protected, const [
        SilenceSegment(startSeconds: 1, endSeconds: 2.92),
      ]);
    });
  });
}
