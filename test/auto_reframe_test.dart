import 'dart:typed_data';

import 'package:ai_video_editing/core/services/face_detection_service.dart';
import 'package:ai_video_editing/features/auto_reframe/data/services/ffmpeg_auto_reframe_service.dart';
import 'package:ai_video_editing/features/auto_reframe/domain/entities/reframe_config.dart';
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

    test('a speaker switch is an instant cut, never a crawl through the wall',
        () {
      final raw = <FaceTrackPoint>[
        for (var i = 0; i < 10; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.2, normY: 0.5),
        for (var i = 10; i < 20; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.8, normY: 0.5),
      ];

      final keyframes = FaceDetectionService.buildKeyframes(raw);

      // The transition happens within a single millisecond — no frames are
      // spent drifting across the empty space between the two faces.
      var instantCutFound = false;
      for (var i = 1; i < keyframes.length; i++) {
        final dt = keyframes[i].timeSec - keyframes[i - 1].timeSec;
        final dx = (keyframes[i].normX - keyframes[i - 1].normX).abs();
        if (dx >= 0.55 && dt <= 0.0011) instantCutFound = true;
        // No emitted sample may ever sit between the two speakers.
        expect(
          keyframes[i].normX < 0.3 || keyframes[i].normX > 0.7,
          isTrue,
          reason: 'camera must never rest between speakers (got '
              '${keyframes[i].normX})',
        );
      }
      expect(instantCutFound, isTrue);

      // The FFmpeg expression snaps too: evaluating the built expression at
      // mid-clip times returns the active speaker, not the wall at 0.5.
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
      expect(keyframes.last.timeSec, raw.last.timeSec);
      for (var i = 1; i < keyframes.length; i++) {
        expect(
          keyframes[i].timeSec,
          greaterThan(keyframes[i - 1].timeSec),
        );
      }
    });

    test('short tracks are kept as-is', () {
      const raw = [
        FaceTrackPoint(timeSec: 0, normX: 0.4, normY: 0.3),
        FaceTrackPoint(timeSec: 1, normX: 0.6, normY: 0.5),
      ];
      final keyframes = FaceDetectionService.buildKeyframes(raw);
      expect(keyframes.length, 2);
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
      // 0.001s span.
      expect(expr, contains('(0.8000-0.2000)*(t-1.999)/0.001'));
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

    test('update within ±0.35s happens in place (no new keyframe)', () {
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
        timeSec: 3.2, // inside the ±0.35s window
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
        timeSec: 4.0, // > 0.35s away
        normX: 0.1,
        normY: 0.2,
      );

      expect(added.length, 3);
      expect(added.map((k) => k.timeSec), [0.0, 3.0, 4.0]);
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

    test('normalize folds synthetic 1ms helpers into cut keyframes', () {
      final raw = FaceDetectionService.buildKeyframes(<FaceTrackPoint>[
        for (var i = 0; i < 10; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.2, normY: 0.5),
        for (var i = 10; i < 20; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.8, normY: 0.5),
      ]);

      final normalized = FaceDetectionService.normalizeKeyframesForEditing(raw);

      // No sub-5ms duplicates remain: the pair collapsed into ONE logical cut
      // keyframe at the shot boundary carrying the NEW position.
      for (var i = 1; i < normalized.length; i++) {
        expect(
          normalized[i].timeSec - normalized[i - 1].timeSec,
          greaterThan(0.005),
        );
      }
      final cut = normalized.firstWhere((k) => k.isCut);
      expect(cut.normX, closeTo(0.8, 1e-9));
      expect(cut.timeSec, closeTo(5.0, 1e-9));
    });
  });

  group('silhouette / motion subject fallback', () {
    test('dark silhouette on bright background is detected', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      final rgba = Uint8List(w * h * 4);

      void fill(int value) {
        for (var i = 0; i < w * h; i++) {
          rgba[i * 4] = value;
          rgba[i * 4 + 1] = value;
          rgba[i * 4 + 2] = value;
          rgba[i * 4 + 3] = 255;
        }
      }

      // Bright studio background, pitch-black silhouette guest on the right.
      fill(140);
      for (var gy = 10; gy <= 30; gy++) {
        for (var gx = 50; gx <= 62; gx++) {
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
      // X centered on the blob (50..62 of 80), within the search region.
      expect(subject!.normX, inInclusiveRange(0.55, 0.85));
      expect(subject.normX, closeTo((56 + 0.5) / w, 0.06));
      // Y biased to the head / upper-torso of the cluster.
      expect(subject.normY, closeTo((10 + 21 * 0.32) / h, 0.06));
      expect(subject.sceneChanged, isFalse);
      expect(subject.normH, greaterThan(0.1));
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

    test('frame-to-frame motion finds a bright moving subject', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      Uint8List uniform(int value) {
        final bytes = Uint8List(w * h * 4);
        for (var i = 0; i < w * h; i++) {
          bytes[i * 4] = value;
          bytes[i * 4 + 1] = value;
          bytes[i * 4 + 2] = value;
          bytes[i * 4 + 3] = 255;
        }
        return bytes;
      }

      final prev = uniform(140);
      final current = uniform(140);
      // A mid-gray subject (NOT dark enough for the silhouette term) moved
      // into place — only the motion term can find him.
      for (var gy = 10; gy <= 30; gy++) {
        for (var gx = 50; gx <= 62; gx++) {
          final o = (gy * w + gx) * 4;
          current[o] = 60;
          current[o + 1] = 60;
          current[o + 2] = 60;
        }
      }

      final subject = FaceDetectionService.detectSilhouetteOrMotionSubject(
        current,
        w,
        h,
        prev,
      );

      expect(subject, isNotNull);
      expect(subject!.normX, closeTo((56 + 0.5) / w, 0.06));
      // 273 changed cells of 3600 → mean luma diff ~6: not a scene cut.
      expect(subject.sceneChanged, isFalse);
    });

    test('a hard scene cut is flagged so identity never carries over', () {
      const w = FaceDetectionService.silhouetteGridWidth;
      const h = FaceDetectionService.silhouetteGridHeight;
      Uint8List frame(int background, int blob) {
        final bytes = Uint8List(w * h * 4);
        for (var i = 0; i < w * h; i++) {
          bytes[i * 4] = background;
          bytes[i * 4 + 1] = background;
          bytes[i * 4 + 2] = background;
          bytes[i * 4 + 3] = 255;
        }
        for (var gy = 10; gy <= 30; gy++) {
          for (var gx = 50; gx <= 62; gx++) {
            final o = (gy * w + gx) * 4;
            bytes[o] = blob;
            bytes[o + 1] = blob;
            bytes[o + 2] = blob;
          }
        }
        return bytes;
      }

      final prev = frame(200, 200); // bright empty shot
      final current = frame(140, 8); // bright studio shot + black silhouette

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
      expect(expr, contains('(t-0.000)'));
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
      // jump between the two keyframes is materialized as a 1ms snap.
      expect(filter, contains('iw*(if(lt(t\\,1.999)'));
      expect(filter, contains('0.3000+(0.3000-0.3000)*(t-0.000)/1.999'));
      expect(filter, contains('(0.7000-0.3000)*(t-1.999)/0.001'));
      expect(filter, contains('ih*(if(lt(t\\,1.999)'));
      expect(filter, contains('(0.6000-0.4000)*(t-1.999)/0.001'));

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
