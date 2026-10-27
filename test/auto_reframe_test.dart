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

    test('a real move beyond the dead-zone is followed smoothly', () {
      final raw = <FaceTrackPoint>[
        for (var i = 0; i < 10; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.5, normY: 0.42),
        for (var i = 10; i < 30; i++)
          FaceTrackPoint(timeSec: i * 0.5, normX: 0.8, normY: 0.6),
      ];

      final smoothed = FaceDetectionService.stabilizeTrack(raw);

      expect(smoothed.last.normX, closeTo(0.8, 0.02));
      expect(smoothed.last.normY, closeTo(0.6, 0.02));
      // The pan is gradual, never a single-frame jump.
      for (var i = 1; i < smoothed.length; i++) {
        expect(
          (smoothed[i].normX - smoothed[i - 1].normX).abs(),
          lessThan(0.15),
        );
      }
    });

    test('keyframe simplification never exceeds 18 points on long videos', () {
      final raw = List<FaceTrackPoint>.generate(600, (i) {
        return FaceTrackPoint(
          timeSec: i * 0.5,
          normX: 0.5 + 0.2 * (i % 37) / 37,
          normY: 0.42 + 0.1 * (i % 13) / 13,
        );
      });

      final keyframes = FaceDetectionService.buildKeyframes(raw);

      expect(keyframes.length, lessThanOrEqualTo(18));
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

    test('sampleAt interpolates linearly between keyframes', () {
      const result = FaceTrackResult(
        rawPoints: [],
        keyframes: [
          FaceTrackPoint(timeSec: 0, normX: 0.2, normY: 0.4),
          FaceTrackPoint(timeSec: 2, normX: 0.6, normY: 0.8),
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
      expect(many, contains('if(lte(t\\,1.000)'));
      expect(many.split('if(').length - 1, 1);
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
  });
}
