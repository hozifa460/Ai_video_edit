import 'dart:typed_data';

import 'package:ai_video_editing/core/services/face_detection_service.dart';
import 'package:ai_video_editing/features/auto_reframe/data/services/ffmpeg_auto_reframe_service.dart';
import 'package:ai_video_editing/features/auto_reframe/domain/entities/reframe_config.dart';
import 'package:ai_video_editing/features/auto_reframe/presentation/screens/auto_reframe_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('camera stabilization', () {
    test('dead-zone removes sub-threshold jitter entirely', () {
      final raw = List<FaceTrackPoint>.generate(30, (i) {
        final jitter = i.isEven ? 0.008 : -0.008;
        return FaceTrackPoint(
          timeSec: i * 0.5,
          normX: 0.5 + jitter,
          normY: 0.42 + jitter,
        );
      });

      final smoothed = FaceDetectionService.stabilizeTrack(raw);

      // The camera never moves: every emitted point equals the initial anchor
      // (the first sample), even though the face itself keeps jittering.
      for (final point in smoothed) {
        expect(point.normX, closeTo(smoothed.first.normX, 1e-9));
        expect(point.normY, closeTo(smoothed.first.normY, 1e-9));
        expect((point.normX - 0.5).abs(), lessThan(0.009));
        expect((point.normY - 0.42).abs(), lessThan(0.009));
      }
    });

    test('a gradual pan inside one shot is followed smoothly', () {
      final raw = <FaceTrackPoint>[
        for (var i = 0; i < 40; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.5 + 0.008 * i, normY: 0.42),
      ];

      final smoothed = FaceDetectionService.stabilizeTrack(raw);

      // The camera ends up close to the final position (dead-zone + EMA leave
      // a small trailing lag, but never a stuck camera at the start).
      expect(smoothed.last.normX, greaterThan(0.74));
      expect(smoothed.last.normX, lessThan(0.83));
      // Sub-threshold steps (never a speaker switch) stay a smooth pan.
      for (var i = 1; i < smoothed.length; i++) {
        expect(
          (smoothed[i].normX - smoothed[i - 1].normX).abs(),
          lessThan(FaceDetectionService.speakerJumpThreshold),
        );
      }
    });

    test('a speaker switch becomes two clean shot keyframes with a cut', () {
      final raw = <FaceTrackPoint>[
        for (var i = 0; i < 10; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.2, normY: 0.5),
        for (var i = 10; i < 20; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.8, normY: 0.5),
      ];

      final keyframes = FaceDetectionService.buildKeyframes(raw);

      // ONE clean keyframe per steady shot — not dozens of noisy RDP points.
      expect(keyframes.length, 2);
      expect(keyframes[0].timeSec, closeTo(0.0, 1e-9));
      expect(keyframes[1].timeSec, closeTo(5.0, 1e-9));
      expect(keyframes[0].normX, closeTo(0.2, 1e-9));
      expect(keyframes[1].normX, closeTo(0.8, 1e-9));
      expect(keyframes[1].isCut, isTrue);
      // No emitted keyframe may ever sit between the two speakers.
      for (final kf in keyframes) {
        expect(
          kf.normX < 0.3 || kf.normX > 0.7,
          isTrue,
          reason: 'camera must never rest between speakers (got '
              '${kf.normX})',
        );
      }

      // The FFmpeg expression snaps too: isCut keyframes are materialized
      // into a 1ms step inside normExpression, so evaluating at mid-clip
      // times returns the active speaker, not the wall at 0.5.
      final expr = FfmpegAutoReframeService.normExpression(
        keyframes,
        axisX: true,
      );
      expect(_evaluateExpr(expr, 2.0), closeTo(0.2, 1e-6));
      expect(_evaluateExpr(expr, 7.0), closeTo(0.8, 1e-6));
      expect(
        _evaluateExpr(expr, 7.0),
        isNot(closeTo(0.5, 0.05)),
        reason: 'a linear crawl would put the camera at 0.5 here',
      );
    });

    test('a steady single-speaker shot collapses to ONE clean keyframe', () {
      // A real interview/podcast shot: the person jitters slightly around a
      // single spot for the whole shot.
      final raw = List<FaceTrackPoint>.generate(20, (i) {
        return FaceTrackPoint(
          timeSec: i * 0.5,
          normX: 0.5 + (i.isEven ? 0.02 : -0.02),
          normY: 0.42 + (i.isEven ? 0.01 : -0.01),
        );
      });

      final keyframes = FaceDetectionService.buildKeyframes(raw);

      expect(keyframes.length, 1);
      expect(keyframes.first.timeSec, closeTo(0.0, 1e-9));
      expect(keyframes.first.normX, closeTo(0.5, 0.05));
      expect(keyframes.first.normY, closeTo(0.42, 0.05));
      expect(keyframes.first.isCut, isTrue);
    });

    test('a speaker genuinely traveling across one shot keeps smooth '
        'keyframes', () {
      // One continuous segment with a large, gradual sweep (>0.20 travel):
      // the collapse must NOT fire, intermediate keyframes stay smooth.
      final raw = List<FaceTrackPoint>.generate(30, (i) {
        return FaceTrackPoint(
          timeSec: i * 0.5,
          normX: 0.2 + i * 0.04,
          normY: 0.45,
        );
      });

      final keyframes = FaceDetectionService.buildKeyframes(raw);

      expect(keyframes.length, greaterThan(2));
      // Only the shot entry is a cut — the sweep itself is smooth.
      expect(
        keyframes.skip(1).any((k) => k.isCut),
        isFalse,
        reason: 'a traveling speaker must pan, not jump',
      );
    });

    test('keyframe simplification never exceeds the 60-point budget', () {
      final raw = List<FaceTrackPoint>.generate(600, (i) {
        return FaceTrackPoint(
          timeSec: i * 0.5,
          normX: 0.5 + 0.2 * (i % 37) / 37,
          normY: 0.42 + 0.1 * (i % 13) / 13,
        );
      });

      final keyframes = FaceDetectionService.buildKeyframes(raw);

      expect(keyframes.length, lessThanOrEqualTo(FaceDetectionService.maxKeyframes));
      expect(keyframes.length, greaterThanOrEqualTo(2));
      expect(keyframes.first.timeSec, raw.first.timeSec);
      // Collapsed steady shots anchor at their start; the last one still
      // covers the tail of the video (the final position holds to the end).
      expect(keyframes.last.timeSec, lessThanOrEqualTo(raw.last.timeSec));
      expect(keyframes.last.timeSec, greaterThan(raw.first.timeSec));
      for (var i = 1; i < keyframes.length; i++) {
        expect(
          keyframes[i].timeSec,
          greaterThan(keyframes[i - 1].timeSec),
        );
      }
    });

    test('a two-point jump becomes two clean shot keyframes', () {
      const raw = [
        FaceTrackPoint(timeSec: 0, normX: 0.4, normY: 0.3),
        FaceTrackPoint(timeSec: 1, normX: 0.6, normY: 0.5),
      ];
      final keyframes = FaceDetectionService.buildKeyframes(raw);
      expect(keyframes.length, 2);
      expect(keyframes[0].normX, closeTo(0.4, 1e-9));
      expect(keyframes[1].normX, closeTo(0.6, 1e-9));
      expect(keyframes[1].isCut, isTrue);
    });

    test('sampleAt interpolates linearly for manual smooth keyframes', () {
      // The second keyframe is a deliberate user "Smooth" choice: the big
      // jump heuristics must NOT turn it into a cut.
      const result = FaceTrackResult(
        rawPoints: [],
        keyframes: [
          FaceTrackPoint(timeSec: 0, normX: 0.2, normY: 0.4),
          FaceTrackPoint(
            timeSec: 2,
            normX: 0.6,
            normY: 0.8,
            isManual: true,
          ),
        ],
        avgNormX: 0.4,
        avgNormY: 0.6,
        facesDetectedCount: 4,
      );

      final (x, y) = result.sampleAt(1);
      expect(x, closeTo(0.4, 1e-9));
      expect(y, closeTo(0.6, 1e-9));

      expect(result.sampleAt(-1).$1, closeTo(0.2, 1e-9));
      expect(result.sampleAt(99).$1, closeTo(0.6, 1e-9));
    });

    test('sampleAt holds and snaps instantly across an isCut keyframe', () {
      const result = FaceTrackResult(
        rawPoints: [],
        keyframes: [
          FaceTrackPoint(timeSec: 0, normX: 0.2, normY: 0.5),
          FaceTrackPoint(
            timeSec: 1,
            normX: 0.8,
            normY: 0.5,
            isCut: true,
          ),
          FaceTrackPoint(timeSec: 3, normX: 0.85, normY: 0.5),
        ],
        avgNormX: 0.6,
        avgNormY: 0.5,
        facesDetectedCount: 2,
      );

      // Hold the previous position right up to (but excluding) the cut.
      expect(result.sampleAt(0.5).$1, closeTo(0.2, 1e-9));
      expect(result.sampleAt(0.999).$1, closeTo(0.2, 1e-9));
      // Snap immediately at the cut timestamp.
      expect(result.sampleAt(1.0).$1, closeTo(0.8, 1e-9));
      // Then smooth again towards the next keyframe (halfway to 0.85).
      expect(result.sampleAt(2.0).$1, closeTo(0.825, 1e-9));
    });
  });

  group('cut materialization for FFmpeg', () {
    test('materialize expands isCut keyframes into 1ms step pairs', () {
      const raw = [
        FaceTrackPoint(timeSec: 0, normX: 0.2, normY: 0.5),
        FaceTrackPoint(timeSec: 2, normX: 0.8, normY: 0.5, isCut: true),
        FaceTrackPoint(timeSec: 4, normX: 0.8, normY: 0.7),
      ];

      final materialized =
          FaceDetectionService.materializeKeyframesForFfmpeg(raw);

      // [a@0, helper@1.999 (old position), b@2, c@4]: only the cut pair is
      // expanded; the smooth b->c segment stays linear.
      expect(materialized.length, 4);
      expect(materialized[1].timeSec, closeTo(1.999, 1e-9));
      expect(materialized[1].normX, closeTo(0.2, 1e-9));
      expect(materialized[2].timeSec, closeTo(2.0, 1e-9));
      expect(materialized[2].normX, closeTo(0.8, 1e-9));
      expect(materialized[3].timeSec, closeTo(4.0, 1e-9));

      // Idempotent: re-expanding an already expanded list adds nothing.
      final again =
          FaceDetectionService.materializeKeyframesForFfmpeg(materialized);
      expect(again.length, materialized.length);
    });

    test('large heuristic jumps are materialized without explicit flags', () {
      const raw = [
        FaceTrackPoint(timeSec: 0, normX: 0.3, normY: 0.4),
        FaceTrackPoint(timeSec: 2, normX: 0.7, normY: 0.6),
      ];

      final materialized =
          FaceDetectionService.materializeKeyframesForFfmpeg(raw);

      expect(materialized.length, 3);
      expect(materialized[1].timeSec, closeTo(1.999, 1e-9));
      expect(materialized[1].normX, closeTo(0.3, 1e-9));
    });

    test('manual smooth override is never materialized into a cut', () {
      const raw = [
        FaceTrackPoint(timeSec: 0, normX: 0.3, normY: 0.4),
        FaceTrackPoint(
          timeSec: 2,
          normX: 0.7,
          normY: 0.6,
          isManual: true,
        ),
      ];

      final materialized =
          FaceDetectionService.materializeKeyframesForFfmpeg(raw);
      expect(materialized.length, 2);
    });

    test('buildCropFilter renders a 1ms snap for a speaker jump', () {
      final raw = FaceDetectionService.buildKeyframes(<FaceTrackPoint>[
        for (var i = 0; i < 10; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.2, normY: 0.5),
        for (var i = 10; i < 20; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.8, normY: 0.5),
      ]);

      // buildKeyframes flags the first point of the new shot as a cut.
      expect(raw.any((k) => k.isCut), isTrue);

      final filter = FfmpegAutoReframeService.buildCropFilter(
        outW: 1080,
        outH: 1920,
        keyframes: raw,
        frameFill: 1.0,
      );
      // The FFmpeg expression contains the explicit 1ms step segment.
      expect(filter, contains('/0.001'));
    });

    test('normExpression honors explicit isCut keyframes', () {
      const keyframes = [
        FaceTrackPoint(timeSec: 0, normX: 0.2, normY: 0.5),
        FaceTrackPoint(timeSec: 2, normX: 0.8, normY: 0.5, isCut: true),
      ];

      final expr =
          FfmpegAutoReframeService.normExpression(keyframes, axisX: true);
      // Materialized into [0.2@0, 0.2@1.999, 0.8@2] → the snap segment has a
      // 0.001s span, with `t` clamped into the segment (hold, no runaway
      // extrapolation past the final keyframe).
      expect(
        expr,
        contains(
          '(0.8000-0.2000)*(min(max(t\\,1.999)\\,2.000)-1.999)/0.001',
        ),
      );
    });
  });

  group('manual keyframe editing', () {
    test('insert creates a sorted manual cut keyframe', () {
      const base = [
        FaceTrackPoint(timeSec: 0, normX: 0.5, normY: 0.5),
      ];

      final inserted = FaceDetectionService.upsertManualKeyframe(
        base,
        timeSec: 3.0,
        normX: 0.25,
        normY: 0.6,
      );

      expect(inserted.length, 2);
      expect(inserted.last.timeSec, closeTo(3.0, 1e-9));
      expect(inserted.last.normX, closeTo(0.25, 1e-9));
      expect(inserted.last.isCut, isTrue);
      expect(inserted.last.isManual, isTrue);
      // Sorted time order is preserved.
      expect(inserted[0].timeSec, lessThan(inserted[1].timeSec));
    });

    test('update within the 0.25s snap tolerance happens in place', () {
      var keyframes = const [
        FaceTrackPoint(timeSec: 0, normX: 0.5, normY: 0.5),
      ];
      keyframes = FaceDetectionService.upsertManualKeyframe(
        keyframes,
        timeSec: 3.0,
        normX: 0.25,
        normY: 0.6,
      );

      final updated = FaceDetectionService.upsertManualKeyframe(
        keyframes,
        timeSec: 3.2, // inside the tight ±0.25s window
        normX: 0.75,
        normY: 0.4,
      );

      expect(updated.length, 2);
      expect(updated.last.timeSec, closeTo(3.0, 1e-9)); // time unchanged
      expect(updated.last.normX, closeTo(0.75, 1e-9));
      expect(updated.last.normY, closeTo(0.4, 1e-9));
      expect(updated.last.isManual, isTrue);
    });

    test('outside the tolerance a new keyframe is inserted in order', () {
      var keyframes = const [
        FaceTrackPoint(timeSec: 0, normX: 0.5, normY: 0.5),
      ];
      keyframes = FaceDetectionService.upsertManualKeyframe(
        keyframes,
        timeSec: 3.0,
        normX: 0.25,
        normY: 0.6,
      );

      final added = FaceDetectionService.upsertManualKeyframe(
        keyframes,
        timeSec: 3.3, // 0.3s away: beyond the 0.25s window
        normX: 0.1,
        normY: 0.2,
      );

      expect(added.length, 3);
      expect(added.map((k) => k.timeSec), [0.0, 3.0, 3.3]);
    });

    test('delete removes one keyframe but always keeps at least one', () {
      var keyframes = const [
        FaceTrackPoint(timeSec: 0, normX: 0.5, normY: 0.5),
        FaceTrackPoint(timeSec: 1, normX: 0.2, normY: 0.5, isCut: true),
        FaceTrackPoint(timeSec: 2, normX: 0.8, normY: 0.5),
      ];

      final afterDelete = FaceDetectionService.deleteKeyframe(keyframes, 1);
      expect(afterDelete.length, 2);
      expect(afterDelete[1].timeSec, closeTo(2.0, 1e-9));

      // Deleting the last remaining keyframe is a no-op.
      const single = [FaceTrackPoint(timeSec: 0, normX: 0.5, normY: 0.5)];
      expect(FaceDetectionService.deleteKeyframe(single, 0).length, 1);
      expect(FaceDetectionService.deleteKeyframe(keyframes, -1).length, 3);
    });

    test('normalize keeps clean shot keyframes and folds legacy helpers',
        () {
      // buildKeyframes now emits ONE clean keyframe per shot (no 1ms helper
      // pairs); normalize must pass them through with cuts preserved.
      final raw = FaceDetectionService.buildKeyframes(<FaceTrackPoint>[
        for (var i = 0; i < 10; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.2, normY: 0.5),
        for (var i = 10; i < 20; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.8, normY: 0.5),
      ]);

      final normalized = FaceDetectionService.normalizeKeyframesForEditing(raw);

      expect(normalized.length, 2);
      expect(normalized.first.timeSec, closeTo(0.0, 1e-9));
      expect(normalized.last.timeSec, closeTo(5.0, 1e-9));
      expect(normalized.last.normX, closeTo(0.8, 1e-9));
      expect(normalized.last.isCut, isTrue);
      // No sub-5ms duplicates.
      for (var i = 1; i < normalized.length; i++) {
        expect(
          normalized[i].timeSec - normalized[i - 1].timeSec,
          greaterThan(0.005),
        );
      }

      // Legacy/external sources (e.g. stabilizeTrack output) may still
      // contain synthetic 1ms step helpers — normalize folds those into a
      // single logical cut keyframe carrying the NEW position.
      const withHelpers = [
        FaceTrackPoint(timeSec: 0, normX: 0.2, normY: 0.5),
        FaceTrackPoint(timeSec: 4.999, normX: 0.2, normY: 0.5),
        FaceTrackPoint(timeSec: 5.0, normX: 0.8, normY: 0.5),
        FaceTrackPoint(timeSec: 9.5, normX: 0.8, normY: 0.5),
      ];

      final folded = FaceDetectionService.normalizeKeyframesForEditing(
        withHelpers,
      );

      // The helper pair collapsed into ONE logical cut keyframe at 5.0
      // carrying the NEW position; the trailing smooth anchor stays.
      expect(folded.length, 3);
      expect(folded[1].timeSec, closeTo(5.0, 1e-9));
      expect(folded[1].normX, closeTo(0.8, 1e-9));
      expect(folded[1].isCut, isTrue);
    });
  });

  group('anonymized black-mask silhouette fallback', () {
    test('a pitch-black seated silhouette on a bright studio background is '
        'detected', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);

      // Bright studio background.
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // Seated torso-sized pitch-black mask: x 48..64, y 8..34.
      for (var gy = 8; gy <= 34; gy++) {
        for (var gx = 48; gx <= 64; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 8;
          rgba[o + 1] = 8;
          rgba[o + 2] = 8;
        }
      }

      final subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
        rgba,
        w,
        h,
        null,
      );

      expect(subject, isNotNull);
      // X = centroid of the cluster's upper half (head/shoulders).
      expect(subject!.normX, closeTo((56 + 0.5) / w, 0.03));
      // Y = head level of the cluster (top + 0.28 * cluster height).
      expect(subject.normY, closeTo((8 + 27 * 0.28) / h, 0.03));
      expect(subject.normW, greaterThan(0.1));
      expect(subject.normH, greaterThan(0.4));
      expect(subject.sceneChanged, isFalse);
    });

    test('uniform bright frame (empty wall) finds nothing', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }

      expect(
        FaceDetectionService.detectSilhouetteOrMotionSubject(rgba, w, h, null),
        isNull,
      );
    });

    test('high-contrast studio stripes (sharp edges) are rejected', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);

      // Alternating 1-cell vertical stripes: every cell has a >100-luma
      // gradient neighbor. The old `gradient > 30` heuristic locked onto
      // exactly this kind of studio furniture / wall edge.
      for (var gy = 0; gy < h; gy++) {
        for (var gx = 0; gx < w; gx++) {
          final value = gx.isEven ? 60 : 200;
          final o = (gy * w + gx) * 4;
          rgba[o] = value;
          rgba[o + 1] = value;
          rgba[o + 2] = value;
          rgba[o + 3] = 255;
        }
      }

      expect(
        FaceDetectionService.detectSilhouetteOrMotionSubject(rgba, w, h, null),
        isNull,
      );
    });

    test('a thin black microphone arm is rejected by the 3x3 uniformity', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // A 1-cell-wide pitch-black vertical line: only 3 of the 9 cells in
      // its 3x3 window are dark, so the uniformity guard rejects all of it.
      for (var gy = 0; gy < h; gy++) {
        final o = (gy * w + 55) * 4;
        rgba[o] = 8;
        rgba[o + 1] = 8;
        rgba[o + 2] = 8;
      }

      expect(
        FaceDetectionService.detectSilhouetteOrMotionSubject(rgba, w, h, null),
        isNull,
      );
    });

    test('a small black prop (below human torso size) is rejected', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // A hand-sized black bag on the desk: contiguous and pitch black, but
      // far below the 6%-of-grid human-torso minimum.
      for (var gy = 30; gy <= 36; gy++) {
        for (var gx = 30; gx <= 36; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 8;
          rgba[o + 1] = 8;
          rgba[o + 2] = 8;
        }
      }

      expect(
        FaceDetectionService.detectSilhouetteOrMotionSubject(rgba, w, h, null),
        isNull,
      );
    });

    test('dark colored decor (wood/bronze) is not an anonymization mask', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // Near-black luma (15) but a wide RGB channel spread (25): dark
      // colored props must never qualify as the pitch-black mask.
      for (var gy = 8; gy <= 34; gy++) {
        for (var gx = 48; gx <= 64; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 30;
          rgba[o + 1] = 10;
          rgba[o + 2] = 5;
        }
      }

      expect(
        FaceDetectionService.detectSilhouetteOrMotionSubject(rgba, w, h, null),
        isNull,
      );
    });

    test('a hard scene cut is flagged so identity never carries over', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      Uint8List frame(int background) {
        final bytes = Uint8List(w * h * 4);
        for (var i = 0; i < w * h; i++) {
          bytes[i * 4] = background;
          bytes[i * 4 + 1] = background;
          bytes[i * 4 + 2] = background;
          bytes[i * 4 + 3] = 255;
        }
        for (var gy = 8; gy <= 34; gy++) {
          for (var gx = 48; gx <= 64; gx++) {
            final o = (gy * w + gx) * 4;
            bytes[o] = 8;
            bytes[o + 1] = 8;
            bytes[o + 2] = 8;
          }
        }
        return bytes;
      }

      final prev = frame(200); // bright empty shot
      final current = frame(140); // studio shot + black silhouette

      final subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
        current,
        w,
        h,
        prev,
      );

      expect(subject, isNotNull);
      expect(subject!.sceneChanged, isTrue);
    });
  });

  group('speaker-switch instant cuts (25+ cuts)', () {
    test('adjacent switches of 0.14-0.16 are isCut even with 25+ cuts', () {
      // 26 alternating shots at x = 0.52 / 0.68 (delta 0.16), ~4 samples
      // each — a realistic 2-minute multi-speaker interview.
      final raw = <FaceTrackPoint>[];
      for (var shot = 0; shot < 26; shot++) {
        final x = shot.isEven ? 0.52 : 0.68;
        for (var j = 0; j < 4; j++) {
          raw.add(
            FaceTrackPoint(
              timeSec: (shot * 4 + j) * 0.25,
              normX: x,
              normY: 0.45,
            ),
          );
        }
      }

      final keyframes = FaceDetectionService.buildKeyframes(raw);

      // Every transition between the two speakers must be an instant cut,
      // never a multi-second crawl — even with 25+ cuts in the video.
      for (var i = 1; i < keyframes.length; i++) {
        final dx = (keyframes[i].normX - keyframes[i - 1].normX).abs();
        if (dx >= 0.14) {
          expect(
            keyframes[i].isCut,
            isTrue,
            reason: 'switch at ${keyframes[i].timeSec}s (dx=$dx) must be '
                'an instant cut, not a smooth pan',
          );
        }
      }
      expect(
        keyframes.where((k) => k.isCut).length,
        greaterThanOrEqualTo(20),
        reason: 'a 26-shot interview must yield many cut keyframes',
      );
    });
  });

  group('silhouette thin-stripe stripping & medium shots', () {
    test('thin vertical black wall stripes do not pull normX off the head',
        () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);

      // Bright studio background.
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // Seated pitch-black silhouette on the right.
      for (var gy = 8; gy <= 34; gy++) {
        for (var gx = 48; gx <= 64; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 8;
          rgba[o + 1] = 8;
          rgba[o + 2] = 8;
        }
      }
      // A 1-cell-wide vertical black wall molding / mic boom arm to the
      // LEFT of the speaker — must be stripped before clustering so it
      // cannot drag normX toward the empty wall.
      for (var gy = 0; gy < h; gy++) {
        final o = (gy * w + 40) * 4;
        rgba[o] = 8;
        rgba[o + 1] = 8;
        rgba[o + 2] = 8;
      }

      final subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
        rgba,
        w,
        h,
        null,
      );

      expect(subject, isNotNull);
      // Head stays centered on the silhouette, not pulled to gx=40.
      expect(subject!.normX, closeTo((56 + 0.5) / w, 0.03));
    });

    test('a medium-shot silhouette (~3.5% of the grid) is detected', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);

      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // ~130 cells = 3.6% of the 80x45 grid: a medium 16:9 two-person shot
      // of the masked speaker. Must pass the lowered 2.8% guard.
      for (var gy = 19; gy <= 31; gy++) {
        for (var gx = 30; gx <= 39; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 8;
          rgba[o + 1] = 8;
          rgba[o + 2] = 8;
        }
      }

      final subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
        rgba,
        w,
        h,
        null,
      );

      expect(subject, isNotNull);
    });

    test('computeMouthRegionDelta is 0 without grids and >0 when the mouth '
        'region changes', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      // No grids -> 0.
      expect(
        FaceDetectionService.computeMouthRegionDelta(
          null,
          null,
          w,
          h,
          nx0: 0.3,
          ny0: 0.2,
          nx1: 0.7,
          ny1: 0.8,
          prevNx0: 0.3,
          prevNy0: 0.2,
          prevNx1: 0.7,
          prevNy1: 0.8,
        ),
        0.0,
      );

      // Build two grids identical except a brightening in the mouth sub-box.
      final prev = Uint8List(w * h * 4);
      final curr = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        prev[i * 4] = 100;
        prev[i * 4 + 1] = 100;
        prev[i * 4 + 2] = 100;
        prev[i * 4 + 3] = 255;
        curr[i * 4] = 100;
        curr[i * 4 + 1] = 100;
        curr[i * 4 + 2] = 100;
        curr[i * 4 + 3] = 255;
      }
      // Mouth sub-box: x [0.25..0.75], y [0.58..0.88] of the face box.
      // Face box normalized [0.3,0.2]-[0.7,0.8]; brighten a small block
      // inside it so the 6x4 sampling grid is guaranteed to hit it.
      for (var by = 27; by <= 31; by++) {
        for (var bx = 38; bx <= 42; bx++) {
          final o = (by * w + bx) * 4;
          curr[o] = 220;
          curr[o + 1] = 220;
          curr[o + 2] = 220;
        }
      }

      final delta = FaceDetectionService.computeMouthRegionDelta(
        prev,
        curr,
        w,
        h,
        nx0: 0.3,
        ny0: 0.2,
        nx1: 0.7,
        ny1: 0.8,
        prevNx0: 0.3,
        prevNy0: 0.2,
        prevNx1: 0.7,
        prevNy1: 0.8,
      );
      expect(delta, greaterThan(0.0));
    });

    test('computeMouthRegionDelta returns 0.0 for <=1 gray level noise and '
        '>0.02 for >=15 gray level change', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final prev = Uint8List(w * h * 4);
      final currNoise = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        prev[i * 4] = 100;
        prev[i * 4 + 1] = 100;
        prev[i * 4 + 2] = 100;
        prev[i * 4 + 3] = 255;
        currNoise[i * 4] = 101; // +1 gray level noise
        currNoise[i * 4 + 1] = 101;
        currNoise[i * 4 + 2] = 101;
        currNoise[i * 4 + 3] = 255;
      }
      // Noise-only diff should be killed by the 0.0065 floor.
      final noiseDelta = FaceDetectionService.computeMouthRegionDelta(
        prev,
        currNoise,
        w,
        h,
        nx0: 0.3,
        ny0: 0.2,
        nx1: 0.7,
        ny1: 0.8,
        prevNx0: 0.3,
        prevNy0: 0.2,
        prevNx1: 0.7,
        prevNy1: 0.8,
      );
      expect(noiseDelta, 0.0);

      // >= 15 gray level change in the mouth region -> > 0.02.
      final currBig = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        currBig[i * 4] = 100;
        currBig[i * 4 + 1] = 100;
        currBig[i * 4 + 2] = 100;
        currBig[i * 4 + 3] = 255;
      }
      for (var by = 24; by <= 33; by++) {
        for (var bx = 30; bx <= 50; bx++) {
          final o = (by * w + bx) * 4;
          currBig[o] = 115; // +15
          currBig[o + 1] = 115;
          currBig[o + 2] = 115;
        }
      }
      final bigDelta = FaceDetectionService.computeMouthRegionDelta(
        prev,
        currBig,
        w,
        h,
        nx0: 0.3,
        ny0: 0.2,
        nx1: 0.7,
        ny1: 0.8,
        prevNx0: 0.3,
        prevNy0: 0.2,
        prevNx1: 0.7,
        prevNy1: 0.8,
      );
      expect(bigDelta, greaterThan(0.02));
    });

    test('detectSilhouetteOrMotionSubject centers on a right-border silhouette '
        '(gx=70..79) with normX > 0.85', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // Dark silhouette touching the right border.
      for (var gy = 8; gy <= 36; gy++) {
        for (var gx = 70; gx <= 79; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 8;
          rgba[o + 1] = 8;
          rgba[o + 2] = 8;
        }
      }
      final subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
        rgba,
        w,
        h,
        null,
      );
      expect(subject, isNotNull);
      expect(subject!.normX, greaterThan(0.85));
    });

    test('detectSilhouetteOrMotionSubject does not RangeError or wrap on '
        'full-width (x0=0, x1=79) grids', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // Ceiling (gy=0..3, gx=76..79), right border (gy=0..41, gx=72..79),
      // left border (gy=0..41, gx=0..4).
      for (var gy = 0; gy <= 3; gy++) {
        for (var gx = 76; gx <= 79; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 5;
          rgba[o + 1] = 5;
          rgba[o + 2] = 5;
        }
      }
      for (var gy = 0; gy <= 41; gy++) {
        for (var gx = 72; gx <= 79; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 5;
          rgba[o + 1] = 5;
          rgba[o + 2] = 5;
        }
      }
      for (var gy = 0; gy <= 41; gy++) {
        for (var gx = 0; gx <= 4; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 5;
          rgba[o + 1] = 5;
          rgba[o + 2] = 5;
        }
      }

      SilhouetteSubject? subject;
      expect(() {
        subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
          rgba,
          w,
          h,
          null,
        );
      }, returnsNormally);
      // No wrap-around: detected cluster must not span the whole width.
      expect(subject, isNotNull);
      expect(subject!.normW, lessThan(0.5));
    });

    test('ceiling-connected wall pillar is stripped and normX stays on the '
        'silhouette head', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);

      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // Seated silhouette on the right.
      for (var gy = 8; gy <= 36; gy++) {
        for (var gx = 55; gx <= 70; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 8;
          rgba[o + 1] = 8;
          rgba[o + 2] = 8;
        }
      }
      // Ceiling-connected vertical pillar (gy=0..24, gx=34..37) plus a
      // horizontal mic arm bridging to the silhouette (gy=20..24, gx=34..55).
      for (var gy = 0; gy <= 24; gy++) {
        for (var gx = 34; gx <= 37; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 8;
          rgba[o + 1] = 8;
          rgba[o + 2] = 8;
        }
      }
      for (var gy = 20; gy <= 24; gy++) {
        for (var gx = 34; gx <= 55; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 8;
          rgba[o + 1] = 8;
          rgba[o + 2] = 8;
        }
      }

      final subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
        rgba,
        w,
        h,
        null,
      );

      expect(subject, isNotNull);
      // normX stays on the silhouette's head, NOT pulled to 0.58 by the
      // ceiling pillar.
      expect(subject!.normX, greaterThan(0.72));
    });

    test('a wide 3-person shot silhouette behind a desk is detected', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);

      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // Seated speaker behind a studio desk: gx 65..72, gy 20..27 (64 cells),
      // bottom 27/45=0.60, height 8/45=0.178, luma 21.
      for (var gy = 20; gy <= 27; gy++) {
        for (var gx = 65; gx <= 72; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 21;
          rgba[o + 1] = 21;
          rgba[o + 2] = 21;
        }
      }

      final subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
        rgba,
        w,
        h,
        null,
      );

      expect(subject, isNotNull);
    });

    test('expanded excludeRects mask out a dark jacket/table below a face',
        () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);

      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 140;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 140;
        rgba[i * 4 + 3] = 255;
      }
      // Dark jacket/table directly below a visible speaker's face: without
      // the expanded rect this would be detected as a silhouette.
      for (var gy = 20; gy <= 40; gy++) {
        for (var gx = 30; gx <= 60; gx++) {
          final o = (gy * w + gx) * 4;
          rgba[o] = 8;
          rgba[o + 1] = 8;
          rgba[o + 2] = 8;
        }
      }

      final exclude = <({double x0, double y0, double x1, double y1})>[
        // Face box roughly centered above the jacket, expanded per Bug 2.
        (
          x0: (0.5 - 0.2 * 1.45).clamp(0.0, 1.0),
          y0: (0.25 - 0.3 * 0.45).clamp(0.0, 1.0),
          x1: (0.5 + 0.2 * 1.45).clamp(0.0, 1.0),
          y1: (0.55 + 0.3 * 3.20).clamp(0.0, 1.0),
        ),
      ];

      final subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
        rgba,
        w,
        h,
        null,
        excludeRects: exclude,
      );

      // The jacket/table region is masked out, so no silhouette is found.
      expect(subject, isNull);
    });

  });
  group('FFmpeg crop expressions', () {
    const keyframes = [
      FaceTrackPoint(timeSec: 0, normX: 0.3, normY: 0.4),
      FaceTrackPoint(timeSec: 2, normX: 0.7, normY: 0.6),
    ];

    void expectCommon(String filter, int outW, int outH, String aspect) {
      expect(filter, contains('4*trunc(if(gt(iw/ih\\,$aspect)'));
      expect(filter, contains('2*trunc(if(gt(iw/ih\\,$aspect)'));
      expect(filter, contains('iw-out_w'));
      expect(filter, contains('ih-out_h'));
      expect(filter, contains('-out_w/2'));
      expect(filter, contains('-out_h/2'));
      expect(filter, contains('scale=$outW:$outH:flags=bilinear'));
      expect(filter, contains('setsar=1'));
      expect(filter, contains('format=yuv420p'));
    }

    test('9:16 TikTok crop is centered on the face in both axes', () {
      final filter = FfmpegAutoReframeService.buildCropFilter(
        outW: 1080,
        outH: 1920,
        keyframes: keyframes,
      );
      expectCommon(filter, 1080, 1920, '0.562500');
    });

    test('16:9 YouTube crop uses the same universal math', () {
      final filter = FfmpegAutoReframeService.buildCropFilter(
        outW: 1920,
        outH: 1080,
        keyframes: keyframes,
      );
      expectCommon(filter, 1920, 1080, '1.777778');
    });

    test('1:1 square crop', () {
      final filter = FfmpegAutoReframeService.buildCropFilter(
        outW: 1080,
        outH: 1080,
        keyframes: keyframes,
      );
      expectCommon(filter, 1080, 1080, '1.000000');
    });

    test('4:5 Instagram crop', () {
      final filter = FfmpegAutoReframeService.buildCropFilter(
        outW: 1080,
        outH: 1350,
        keyframes: keyframes,
      );
      expectCommon(filter, 1080, 1350, '0.800000');
    });

    test('custom ratio crop and even output dimensions', () {
      const config = ReframeConfig(
        preset: AspectRatioPreset.custom,
        customWidthRatio: 3,
        customHeightRatio: 4,
      );
      expect(config.aspectRatio, closeTo(0.75, 1e-9));

      final (outW, outH) = config.outputSize;
      expect(outW % 4, 0);
      expect(outH % 4, 0);

      final filter = FfmpegAutoReframeService.buildCropFilter(
        outW: outW,
        outH: outH,
        keyframes: keyframes,
      );
      expectCommon(filter, outW, outH, '0.750000');
    });

    test('center crop ignores the face trajectory', () {
      final filter = FfmpegAutoReframeService.buildCropFilter(
        outW: 1080,
        outH: 1920,
        keyframes: keyframes,
        faceTracking: false,
      );
      expect(filter, contains("x='(iw-out_w)/2'"));
      expect(filter, contains("y='(ih-out_h)/2'"));
    });

    test('norm expression is piecewise linear and FFmpeg-escaped', () {
      final expr = FfmpegAutoReframeService.normExpression(
        keyframes,
        axisX: true,
      );
      expect(expr, contains('0.3000'));
      expect(expr, contains('0.7000'));
      // The single segment clamps `t` into [0.000, 2.000] so the camera
      // holds the edge keyframes instead of extrapolating.
      expect(expr, contains('min(max(t\\,0.000)\\,2.000)'));
      expect(expr, isNot(contains('if('))); // only two points -> one segment

      final many = FfmpegAutoReframeService.normExpression(const [
        FaceTrackPoint(timeSec: 0, normX: 0.1),
        FaceTrackPoint(timeSec: 1, normX: 0.2),
        FaceTrackPoint(timeSec: 2, normX: 0.3),
      ], axisX: true);
      expect(many, contains('if(lt(t\\,1.000)'));
      expect(many.split('if(').length - 1, 1);
    });

    test('norm expression is a balanced tree, deep only logarithmically', () {
      // 64 keyframes: a linear right-nested chain would nest `if(` 63 levels
      // deep (paren depth ~129) and overflow FFmpeg's expression parser.
      final keyframes = List<FaceTrackPoint>.generate(
        64,
        (i) => FaceTrackPoint(
          timeSec: i * 0.5,
          normX: 0.1 + 0.8 * i / 63,
          normY: 0.3,
        ),
      );
      final expr = FfmpegAutoReframeService.normExpression(
        keyframes,
        axisX: true,
      );

      // Full binary tree over 63 segments → exactly 62 internal `if` nodes.
      expect(expr.split('if(').length - 1, 62);

      var depth = 0;
      var maxDepth = 0;
      for (final code in expr.codeUnits) {
        if (code == 0x28) {
          depth++;
          if (depth > maxDepth) maxDepth = depth;
        } else if (code == 0x29) {
          depth--;
        }
      }
      expect(maxDepth, lessThan(30), reason: 'balanced depth must be ~2*log2');
      expect(maxDepth, greaterThan(4));

      // Correctness: the evaluator returns the right value along the ramp.
      expect(_evaluateExpr(expr, 0.0), closeTo(0.1, 1e-6));
      expect(_evaluateExpr(expr, 31.5), closeTo(0.9, 1e-6));
      expect(
        _evaluateExpr(expr, 15.75),
        closeTo(0.1 + 0.8 * 15.75 / 31.5, 1e-6),
      );
    });

    test('frameFill below 100% scales into an inner box and pads black bars',
        () {
      const keyframes = [
        FaceTrackPoint(timeSec: 0, normX: 0.3, normY: 0.4),
        FaceTrackPoint(timeSec: 2, normX: 0.7, normY: 0.6),
      ];

      final filter = FfmpegAutoReframeService.buildCropFilter(
        outW: 1080,
        outH: 1920,
        keyframes: keyframes,
        frameFill: 0.5,
      );
      // Inner box 1080x960 → wider effective aspect 1.125 → black bars.
      expect(filter, contains('gt(iw/ih\\,1.125000)'));
      expect(filter, contains('scale=1080:960:flags=bilinear'));
      expect(
        filter,
        contains('pad=1080:1920:(1080-1080)/2:(1920-960)/2:black'),
      );
      expect(filter, contains('setsar=1'));
      expect(filter, contains('format=yuv420p'));
      // The face still sits at the center of the cropped region; the 0.4
      // jump between the two keyframes is materialized as a 1ms snap (and
      // `t` is clamped into each segment: hold, never extrapolate).
      expect(filter, contains('iw*(if(lt(t\\,1.999)'));
      expect(
        filter,
        contains(
          '0.3000+(0.3000-0.3000)*(min(max(t\\,0.000)\\,1.999)-0.000)/1.999',
        ),
      );
      expect(
        filter,
        contains(
          '(0.7000-0.3000)*(min(max(t\\,1.999)\\,2.000)-1.999)/0.001',
        ),
      );
      expect(filter, contains('ih*(if(lt(t\\,1.999)'));
      expect(
        filter,
        contains(
          '(0.6000-0.4000)*(min(max(t\\,1.999)\\,2.000)-1.999)/0.001',
        ),
      );

      // Landscape: bars move to the sides.
      final landscape = FfmpegAutoReframeService.buildCropFilter(
        outW: 1920,
        outH: 1080,
        keyframes: keyframes,
        frameFill: 0.8,
      );
      expect(landscape, contains('scale=1536:1080:flags=bilinear'));
      expect(
        landscape,
        contains('pad=1920:1080:(1920-1536)/2:(1080-1080)/2:black'),
      );

      // Full bleed keeps the classic single scale, no padding.
      final full = FfmpegAutoReframeService.buildCropFilter(
        outW: 1080,
        outH: 1920,
        keyframes: keyframes,
        frameFill: 1.0,
      );
      expect(full, isNot(contains('pad=')));
      expect(full, contains('scale=1080:1920:flags=bilinear'));

      // innerBoxForFill rounds to multiples of 4 as FFmpeg expects.
      final box = FfmpegAutoReframeService.innerBoxForFill(
        outW: 1080,
        outH: 1920,
        frameFill: 0.65,
      );
      expect(box.boxW, 1080);
      expect(box.boxH % 4, 0);
      expect(box.boxH, closeTo(1920 * 0.65, 4));
    });

    test('empty track falls back to a safe default position', () {
      final filter = FfmpegAutoReframeService.buildCropFilter(
        outW: 1080,
        outH: 1920,
      );
      expect(filter, contains('0.5000'));
      expect(filter, contains('0.4200'));
    });

    test('blur background graph blurs the backdrop and overlays the frame', () {
      final graph = FfmpegAutoReframeService.buildBlurGraph(
        outW: 1080,
        outH: 1920,
      );
      expect(graph, contains('gblur'));
      expect(graph, contains('overlay=(W-w)/2:(H-h)/2'));
      expect(graph, contains('[outv]'));
    });
  });

  group('crop drag accumulation (preview gesture math)', () {
    // onPanUpdate delivers PER-FRAME pixel deltas: each step must be applied
    // to the CURRENT drag position (the screen advances _dragOrigin with the
    // returned center), otherwise the box would only nudge by one frame's
    // delta (~2px) for the whole gesture.
    const previewW = 500.0;
    const previewH = 500.0;
    // Source 1:1 inside a 16:9 crop: X is unconstrained, Y clamps to
    // [0.28125, 0.71875].
    const aspect = 16 / 9;

    test('per-frame deltas accumulate across a continuous drag', () {
      // Landscape 2:1 preview with a 16:9 crop: the crop spans the full
      // height (Y locked at 0.5) while X moves inside [4/9, 5/9].
      const previewW = 1000.0;
      const previewH = 500.0;
      var position = (0.5, 0.5);
      final xs = <double>[];
      for (var frame = 0; frame < 3; frame++) {
        position = AutoReframeScreen.dragStepCenter(
          origin: position,
          deltaXPx: 10,
          deltaYPx: 0,
          previewW: previewW,
          previewH: previewH,
          effectiveAspect: aspect,
        );
        xs.add(position.$1);
      }
      // 10px of a 1000px-wide preview = 0.01 per frame: 0.51, 0.52, 0.53.
      expect(xs[0], closeTo(0.51, 1e-9));
      expect(xs[1], closeTo(0.52, 1e-9));
      expect(xs[2], closeTo(0.53, 1e-9));
      expect(position.$2, closeTo(0.5, 1e-9));
    });

    test('leftward drags accumulate too (negative deltas)', () {
      const previewW = 1000.0;
      const previewH = 500.0;
      var position = (0.5, 0.5);
      for (var frame = 0; frame < 4; frame++) {
        position = AutoReframeScreen.dragStepCenter(
          origin: position,
          deltaXPx: -10,
          deltaYPx: 0,
          previewW: previewW,
          previewH: previewH,
          effectiveAspect: aspect,
        );
      }
      expect(position.$1, closeTo(0.46, 1e-9));
    });

    test('the clamped edge position keeps accumulating without overshoot',
        () {
      // Start near the bottom clamp (0.71875) and keep dragging down: the
      // origin advances with the CLAMPED value, so a second over-edge step
      // stays exactly at the edge instead of drifting further out.
      var position = AutoReframeScreen.dragStepCenter(
        origin: (0.5, 0.70),
        deltaXPx: 0,
        deltaYPx: 50, // +0.10 -> 0.80, clamped to 0.71875
        previewW: previewW,
        previewH: previewH,
        effectiveAspect: aspect,
      );
      expect(position.$2, closeTo(0.71875, 1e-9));

      position = AutoReframeScreen.dragStepCenter(
        origin: position,
        deltaXPx: 0,
        deltaYPx: 50,
        previewW: previewW,
        previewH: previewH,
        effectiveAspect: aspect,
      );
      expect(position.$2, closeTo(0.71875, 1e-9));
    });
  });

  group('reframe configuration', () {
    test('presets expose their documented output sizes', () {
      expect(AspectRatioPreset.tiktok9x16.defaultOutputSize, (1080, 1920));
      expect(AspectRatioPreset.youtube16x9.defaultOutputSize, (1920, 1080));
      expect(AspectRatioPreset.square1x1.defaultOutputSize, (1080, 1080));
      expect(AspectRatioPreset.instagram4x5.defaultOutputSize, (1080, 1350));
      expect(AspectRatioPreset.tiktok9x16.ratio, closeTo(9 / 16, 1e-9));
    });

    test('custom output sizes stay multiples of 4 for any ratio', () {
      for (final aspect in [0.4, 0.5625, 0.75, 1.0, 1.3333, 1.7778, 2.4]) {
        final (w, h) = ReframeConfig.customOutputSize(aspect);
        expect(w % 4, 0, reason: 'width for $aspect');
        expect(h % 4, 0, reason: 'height for $aspect');
        expect(w, greaterThanOrEqualTo(16));
        expect(h, greaterThanOrEqualTo(16));
      }
    });

    test('camera motion presets map to dead-zone and smoothness', () {
      expect(
        CameraMotionPreset.steady.deadZone,
        greaterThan(CameraMotionPreset.dynamic.deadZone),
      );
      expect(
        CameraMotionPreset.dynamic.smoothness,
        greaterThan(CameraMotionPreset.steady.smoothness),
      );
    });

    test('frameFill and selectedSpeakerId round-trip through copyWith', () {
      const config = ReframeConfig();
      expect(config.frameFill, 1.0);
      expect(config.frameFillClamped, 1.0);
      expect(config.selectedSpeakerId, isNull);

      final lowered = config.copyWith(frameFill: 0.65);
      expect(lowered.frameFill, 0.65);
      expect(lowered.frameFillClamped, 0.65);

      // Out-of-range values clamp to the slider bounds.
      expect(config.copyWith(frameFill: 0.2).frameFillClamped, 0.45);
      expect(config.copyWith(frameFill: 2.0).frameFillClamped, 1.0);

      final locked = config.copyWith(selectedSpeakerId: 1);
      expect(locked.selectedSpeakerId, 1);
      // Unrelated copyWith keeps the lock...
      expect(locked.copyWith(preset: AspectRatioPreset.square1x1).selectedSpeakerId, 1);
      // ...while an explicit null returns to Auto Active Speaker.
      expect(locked.copyWith(selectedSpeakerId: null).selectedSpeakerId, isNull);
      expect(locked.frameFill, 1.0);
    });

    test('rigid whole-face luma shift (nodding bystander) is canceled out by upper-face reference', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final prev = Uint8List(w * h * 4);
      final curr = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        prev[i * 4] = 100;
        prev[i * 4 + 1] = 100;
        prev[i * 4 + 2] = 100;
        prev[i * 4 + 3] = 255;
        // Whole frame / whole face shifts by +20 gray levels (rigid nod/lighting)
        curr[i * 4] = 120;
        curr[i * 4 + 1] = 120;
        curr[i * 4 + 2] = 120;
        curr[i * 4 + 3] = 255;
      }
      final delta = FaceDetectionService.computeMouthRegionDelta(
        prev,
        curr,
        w,
        h,
        nx0: 0.3,
        ny0: 0.2,
        nx1: 0.7,
        ny1: 0.8,
        prevNx0: 0.3,
        prevNy0: 0.2,
        prevNx1: 0.7,
        prevNy1: 0.8,
      );
      // Rigid whole-face change is canceled by the upper-face subtraction
      expect(delta, lessThan(0.01));
    });

    test('moderate speaker movement (10% of frame) pans smoothly like a camera without cutting', () {
      // Speaker moves from x=0.44 to x=0.56 over 12 samples (dx=0.01 per frame):
      // total travel is 0.12 (> shotSteadyTolerance 0.04, < 0.35), so the
      // camera must follow smoothly (isCut: false) and never turn into a cut.
      final raw = List<FaceTrackPoint>.generate(13, (i) {
        return FaceTrackPoint(
          timeSec: i * 0.25,
          normX: 0.44 + i * 0.01,
          normY: 0.45,
        );
      });

      final built = FaceDetectionService.buildKeyframes(raw);
      final normalized = FaceDetectionService.normalizeKeyframesForEditing(built);
      expect(normalized.length, greaterThanOrEqualTo(2));
      expect(normalized.skip(1).any((k) => k.isCut), isFalse);

      final materialized =
          FaceDetectionService.materializeKeyframesForFfmpeg(normalized);
      // Smooth camera follow: no synthetic 1ms cut helpers added.
      expect(materialized.length, normalized.length);
    });

    test('interactive camera drag creates smooth keyframe and prunes conflicting AI points', () {
      const aiKeyframes = [
        FaceTrackPoint(timeSec: 0.0, normX: 0.3, normY: 0.45, isCut: true),
        FaceTrackPoint(timeSec: 1.5, normX: 0.32, normY: 0.45, isCut: false),
        FaceTrackPoint(timeSec: 3.0, normX: 0.35, normY: 0.45, isCut: false),
        FaceTrackPoint(timeSec: 6.0, normX: 0.75, normY: 0.45, isCut: true),
      ];

      final edited = FaceDetectionService.upsertManualKeyframe(
        aiKeyframes,
        timeSec: 1.4,
        normX: 0.65,
        normY: 0.45,
        isCut: false,
        clearNearbyAiKeyframes: true,
      );

      // The nearby 1.5s AI keyframe is updated to a smooth manual keyframe at
      // x=0.65, the trailing 3.0s intra-shot AI point is pruned so the camera
      // does not snap back to 0.35, and the next shot cut at 6.0s is preserved.
      expect(edited.length, 3);
      expect(edited[1].normX, closeTo(0.65, 1e-9));
      expect(edited[1].isCut, isFalse);
      expect(edited[1].isManual, isTrue);
      expect(edited[2].timeSec, closeTo(6.0, 1e-9));
    });

    test('computeAudioVisualSyncScore rewards synchronized lip-voice modulation and rejects silent nodding', () {
      const audioMod = [0.65, 0.72, 0.68, 0.75];
      const syncedMouth = [0.025, 0.032, 0.028, 0.035];
      const silentMouth = [0.001, 0.001, 0.001, 0.001];

      final syncScore = FaceDetectionService.computeAudioVisualSyncScore(
        mouthHistory: syncedMouth,
        audioModHistory: audioMod,
      );
      final silentScore = FaceDetectionService.computeAudioVisualSyncScore(
        mouthHistory: silentMouth,
        audioModHistory: audioMod,
      );

      expect(syncScore, greaterThan(0.55));
      expect(silentScore, equals(0.0));
    });

    test('buildKeyframesWithShotOverrides locks a specific shot onto a chosen speaker', () {
      final raw = <FaceTrackPoint>[
        for (var i = 0; i < 6; i++)
          FaceTrackPoint(
            timeSec: i * 0.25,
            normX: 0.25,
            normY: 0.45,
            shotId: 0,
            isCut: i == 0,
            persons: const [
              DetectedPersonCandidate(personId: 1, normX: 0.25, normY: 0.45),
              DetectedPersonCandidate(personId: 2, normX: 0.78, normY: 0.48),
            ],
          ),
      ];

      final overridden = FaceDetectionService.buildKeyframesWithShotOverrides(
        raw,
        shotTargetOverrides: const {0: 2},
      );

      expect(overridden, isNotEmpty);
      expect(overridden.first.normX, closeTo(0.78, 0.05));
    });
  });
}

/// Minimal FFmpeg expression evaluator for the balanced `if(lt(t\,x),a,b)` +
/// piecewise-linear grammar emitted by `normExpression`. Lets the tests verify
/// the numeric camera position FFmpeg would compute at any instant.
double _evaluateExpr(String source, double t) =>
    _ExprEvaluator(source, t).evaluate();

class _ExprEvaluator {
  _ExprEvaluator(String source, this.t) : s = source.replaceAll(r'\,', ',');

  final String s;
  final double t;
  int i = 0;

  double evaluate() => _expr();

  void _skip() {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
  }

  void _expectChar(String char) {
    _skip();
    if (i >= s.length || s[i] != char) {
      throw FormatException('Expected "$char" at $i in $s');
    }
    i++;
  }

  bool _startsWith(String token) {
    _skip();
    return s.startsWith(token, i);
  }

  double _expr() {
    if (_startsWith('if(')) {
      i += 3;
      final condition = _comparison();
      _expectChar(',');
      final whenTrue = _expr();
      _expectChar(',');
      final whenFalse = _expr();
      _expectChar(')');
      return condition ? whenTrue : whenFalse;
    }
    return _additive();
  }

  bool _comparison() {
    if (_startsWith('lt(')) {
      i += 3;
      final left = _additive();
      _expectChar(',');
      final right = _additive();
      _expectChar(')');
      return left < right;
    }
    return _additive() != 0;
  }

  double _additive() {
    var value = _multiplicative();
    while (true) {
      _skip();
      if (i < s.length && (s[i] == '+' || s[i] == '-')) {
        final op = s[i];
        i++;
        final right = _multiplicative();
        value = op == '+' ? value + right : value - right;
      } else {
        return value;
      }
    }
  }

  double _multiplicative() {
    var value = _primary();
    while (true) {
      _skip();
      if (i < s.length && (s[i] == '*' || s[i] == '/')) {
        final op = s[i];
        i++;
        final right = _primary();
        value = op == '*' ? value * right : value / right;
      } else {
        return value;
      }
    }
  }

  double _primary() {
    _skip();
    if (i < s.length && s[i] == '(') {
      i++;
      final value = _expr();
      _expectChar(')');
      return value;
    }
    // FFmpeg's min()/max() — used by the leaf segments to clamp `t` into
    // the segment so the camera holds (not extrapolates) past the ends.
    if (_startsWith('min(')) {
      i += 4;
      final a = _additive();
      _expectChar(',');
      final b = _additive();
      _expectChar(')');
      return a < b ? a : b;
    }
    if (_startsWith('max(')) {
      i += 4;
      final a = _additive();
      _expectChar(',');
      final b = _additive();
      _expectChar(')');
      return a > b ? a : b;
    }
    if (i < s.length && s[i] == 't') {
      i++;
      return t;
    }
    final start = i;
    if (i < s.length && (s[i] == '-' || s[i] == '+')) i++;
    while (i < s.length) {
      final code = s.codeUnitAt(i);
      final isDigit = code >= 0x30 && code <= 0x39;
      if (!isDigit && s[i] != '.') break;
      i++;
    }
    if (start == i) {
      throw FormatException('Unexpected token at $i in $s');
    }
    return double.parse(s.substring(start, i));
  }
}
