import 'package:ai_video_editing/core/enums/export_quality.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/features/video_processing/data/services/ffmpeg_cutting_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final service = FfmpegCuttingService();

  group('speech segments come from the plan kept ranges', () {
    test('kept ranges are handed to FFmpeg in order', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [
          SilenceSegment(startSeconds: 1, endSeconds: 2),
          SilenceSegment(startSeconds: 3, endSeconds: 4),
        ],
      );

      expect(FfmpegCuttingService.buildSpeechSegments(plan), const [
        SilenceSegment(startSeconds: 0, endSeconds: 1),
        SilenceSegment(startSeconds: 2, endSeconds: 3),
        SilenceSegment(startSeconds: 4, endSeconds: 10),
      ]);
    });

    test('an empty plan produces no cut inputs', () {
      final plan = SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [SilenceSegment(startSeconds: 0, endSeconds: 10)],
      );
      expect(FfmpegCuttingService.buildSpeechSegments(plan), isEmpty);
    });
  });

  group('filtergraph labels are numeric for every segment index', () {
    test('segment 26 and 39 use [vN]/[aN], never ASCII punctuation', () {
      final segments = List.generate(
        40,
        (i) => SilenceSegment(startSeconds: i * 1.0, endSeconds: i * 1.0 + 0.5),
      );

      final graph = service.buildConcatFilterGraph(
        speechSegments: segments,
        hasAudio: true,
      );

      expect(graph, contains('[v0]'));
      expect(graph, contains('[v26]'));
      expect(graph, contains('[v39]'));
      expect(graph, contains('[a39]'));
      expect(graph, contains('concat=n=40:v=1:a=1'));
      expect(graph.contains('{'), isFalse);
      expect(graph.contains('|'), isFalse);
      expect(graph.contains('}'), isFalse);
    });

    test('every branch shares pixel format, dimensions and audio layout', () {
      final graph = service.buildConcatFilterGraph(
        speechSegments: const [
          SilenceSegment(startSeconds: 0, endSeconds: 1),
          SilenceSegment(startSeconds: 2, endSeconds: 3),
        ],
        hasAudio: true,
      );

      expect(
        graph,
        contains('format=yuv420p,scale=trunc(iw/2)*2:trunc(ih/2)*2'),
      );
      expect(
        graph,
        contains('aformat=sample_rates=44100:channel_layouts=stereo'),
      );
    });

    test('video-only graphs do not reference an audio stream', () {
      final graph = service.buildConcatFilterGraph(
        speechSegments: const [
          SilenceSegment(startSeconds: 0, endSeconds: 1),
          SilenceSegment(startSeconds: 2, endSeconds: 3),
        ],
        hasAudio: false,
      );

      expect(graph, contains('[v0]'));
      expect(graph, contains('[v1]'));
      expect(graph.contains('[a0]'), isFalse);
      expect(graph, contains('concat=n=2:v=1:a=0'));
    });
  });

  group('single kept range is actually trimmed', () {
    test('start/end become input -ss plus output -t and video is re-encoded', () {
      final command = service.buildSingleSegmentCommand(
        videoPath: 'input.mp4',
        segment: const SilenceSegment(startSeconds: 1.25, endSeconds: 3.75),
        outputPath: 'out.mp4',
        quality: ExportQuality.original,
        hasAudio: true,
      );

      expect(command, contains('-ss 1.250 -i "input.mp4"'));
      // Output duration, not an input -to: VFR/B-frame sources must not yield
      // a 0-frame segment.
      expect(command, contains('-t 2.500'));
      expect(command, contains('-c:v libx264 -preset ultrafast -crf 23'));
      expect(command, contains('scale=trunc(iw/2)*2:trunc(ih/2)*2'));
      expect(command, contains('format=yuv420p'));
      expect(command, contains('-c:a aac -b:a 192k'));
      expect(command, isNot(contains('-c:v copy')));
    });

    test('a video without audio maps no audio stream', () {
      final command = service.buildSingleSegmentCommand(
        videoPath: 'input.mp4',
        segment: const SilenceSegment(startSeconds: 0, endSeconds: 1),
        outputPath: 'out.mp4',
        quality: ExportQuality.high,
        hasAudio: false,
      );

      expect(command, contains('-c:v libx264 -preset ultrafast'));
      expect(command.contains('-map 0:a'), isFalse);
    });
  });

  group('large cuts use the concat demuxer', () {
    test('the automatic switch is above 35 and only without Smart Zoom', () {
      expect(FfmpegCuttingService.shouldUseDemuxerFallback(40, null), isFalse);
      expect(FfmpegCuttingService.shouldUseDemuxerFallback(41, null), isTrue);
      expect(
        FfmpegCuttingService.shouldUseDemuxerFallback(
          41,
          const SmartZoomConfig(enabled: true),
        ),
        isFalse,
      );
      expect(
        FfmpegCuttingService.shouldUseDemuxerFallback(
          41,
          const SmartZoomConfig(enabled: true, zoomAmount: 1.0),
        ),
        isTrue,
      );
    });

    test('the manifest quotes paths and escapes single quotes', () {
      final contents = service.buildConcatListContents([
        r'C:\temp\segment_0.mp4',
        "/tmp/it's.mp4",
      ]);

      expect(contents, contains("file 'C:/temp/segment_0.mp4'"));
      expect(contents, contains(r"/tmp/it'\''s.mp4"));
    });

    test('copy and re-encode commands both use -f concat', () {
      final copy = service.buildConcatDemuxerCommand(
        listPath: 'segments.txt',
        outputPath: 'out.mp4',
        quality: ExportQuality.original,
        hasAudio: true,
      );
      expect(copy, contains('-f concat -safe 0 -i "segments.txt"'));
      expect(copy, contains('-c copy'));

      final reencode = service.buildConcatDemuxerCommand(
        listPath: 'segments.txt',
        outputPath: 'out.mp4',
        quality: ExportQuality.original,
        hasAudio: true,
        reencode: true,
      );
      expect(reencode, contains('-c:v libx264 -crf 18 -preset fast'));
      expect(reencode, contains('-c:a aac -b:a 192k'));
    });

    test('per-segment extraction keeps codec settings identical', () {
      final plain = service.buildSegmentExtractionCommand(
        videoPath: 'input.mp4',
        segment: const SilenceSegment(startSeconds: 1, endSeconds: 2),
        segmentPath: 'segment_0.mp4',
        quality: ExportQuality.medium,
        hasAudio: true,
      );
      expect(plain, contains('-ss 1.000 -i "input.mp4"'));
      expect(plain, contains('-t 1.000'));
      expect(plain, contains('-c:v libx264 -preset ultrafast -crf 23'));
      expect(plain, contains('-c:a aac -ar 44100 -ac 2 -b:a 128k'));
      expect(plain, contains('scale=trunc(iw/2)*2:trunc(ih/2)*2'));
      expect(plain, contains('format=yuv420p'));

      final zoomed = service.buildSegmentExtractionCommand(
        videoPath: 'input.mp4',
        segment: const SilenceSegment(startSeconds: 0, endSeconds: 1),
        segmentPath: 'segment_0.mp4',
        quality: ExportQuality.medium,
        hasAudio: true,
        smartZoom: const SmartZoomConfig(enabled: true),
        segmentIndex: 0,
      );
      expect(zoomed, contains('-c:v libx264 -preset ultrafast -crf 23'));
      expect(zoomed, contains('-c:a aac -ar 44100 -ac 2 -b:a 128k'));
      expect(zoomed, contains('format=yuv420p'));
    });

    test('a video without audio extracts with -an', () {
      final command = service.buildSegmentExtractionCommand(
        videoPath: 'input.mp4',
        segment: const SilenceSegment(startSeconds: 0, endSeconds: 1),
        segmentPath: 'segment_0.mp4',
        quality: ExportQuality.medium,
        hasAudio: false,
      );
      expect(command, contains('-an'));
      expect(command, isNot(contains('-c:a aac')));
    });
  });
}
