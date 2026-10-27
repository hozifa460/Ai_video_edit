import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video_editing/features/media_cutter/data/services/ffmpeg_media_cutter_service.dart';

void main() {
  group('Media cutter command builder', () {
    test('trims video and audio together with optional audio mapping', () {
      final command = FfmpegMediaCutterService.buildTrimCommand(
        inputPath: 'C:/clips/source video.mp4',
        outputPath: 'C:/clips/output.mp4',
        startSeconds: 1.25,
        endSeconds: 5.75,
        mediaType: CutterMediaType.video,
      );

      expect(command, contains('-ss 1.250'));
      expect(command, contains('-t 4.500'));
      expect(command, contains('-map 0:v:0'));
      expect(command, contains('-map 0:a?'));
      expect(command, contains('-c:v libx264'));
      expect(command, contains('-c:a aac'));
      expect(command, isNot(contains('-c copy')));
    });

    test('trims audio without video mapping', () {
      final command = FfmpegMediaCutterService.buildTrimCommand(
        inputPath: 'C:/clips/source.mp3',
        outputPath: 'C:/clips/output.m4a',
        startSeconds: 0,
        endSeconds: 12,
        mediaType: CutterMediaType.audio,
      );

      expect(command, contains('-vn'));
      expect(command, contains('-t 12.000'));
      expect(command, contains('-c:a aac'));
      expect(command, isNot(contains('-map 0:v')));
    });

    test('remove mode keeps both sides and concats A/V streams', () {
      final command = FfmpegMediaCutterService.buildRemoveCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        removeStartSeconds: 2,
        removeEndSeconds: 4,
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.video,
      );

      expect(command, contains('trim=start=0.000:end=2.000'));
      expect(command, contains('trim=start=4.000:end=10.000'));
      expect(command, contains('atrim=start=0.000:end=2.000'));
      expect(command, contains('concat=n=2:v=1:a=1[outv][outa]'));
    });

    test('remove mode at the beginning falls back to a tail trim', () {
      final command = FfmpegMediaCutterService.buildRemoveCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        removeStartSeconds: 0,
        removeEndSeconds: 4,
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.video,
      );

      expect(command, contains('-ss 4.000'));
      expect(command, contains('-t 6.000'));
      expect(command, isNot(contains('concat=')));
    });

    test('remove mode at the end falls back to a head trim', () {
      final command = FfmpegMediaCutterService.buildRemoveCommand(
        inputPath: 'C:/clips/source.mp3',
        outputPath: 'C:/clips/output.m4a',
        removeStartSeconds: 6,
        removeEndSeconds: 10,
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.audio,
      );

      expect(command, contains('-ss 0.000'));
      expect(command, contains('-t 6.000'));
      expect(command, contains('-vn'));
      expect(command, isNot(contains('concat=')));
    });

    test('video remove mode can build a video-only concat fallback', () {
      final command = FfmpegMediaCutterService.buildRemoveCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        removeStartSeconds: 2,
        removeEndSeconds: 4,
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.video,
        hasAudio: false,
      );

      expect(command, contains('concat=n=2:v=1:a=0[outv]'));
      expect(command, contains('-map "[outv]"'));
      expect(command, isNot(contains('[0:a]')));
    });

    test('builds audio split commands for every output piece', () {
      final commands = FfmpegMediaCutterService.buildAudioSplitCommands(
        inputPath: 'C:/clips/source.mp3',
        outputDirectory: 'C:/clips/split',
        baseName: 'source',
        segmentSeconds: 30,
        totalDurationSeconds: 75,
      );

      expect(commands, hasLength(3));
      expect(commands[0].outputPath, contains('source_part_001.m4a'));
      expect(commands[0].command, contains('-ss 0.000'));
      expect(commands[0].command, contains('-t 30.000'));
      expect(commands[2].command, contains('-ss 60.000'));
      expect(commands[2].command, contains('-t 15.000'));
      expect(commands[2].command, contains('-vn'));
    });

    test('builds split commands from manual cut points', () {
      final commands = FfmpegMediaCutterService.buildSplitAtCutsCommands(
        inputPath: 'C:/clips/source.mp3',
        outputDirectory: 'C:/clips/split',
        baseName: 'source',
        cutPointsSeconds: const [10, 25],
        totalDurationSeconds: 40,
        mediaType: CutterMediaType.audio,
      );

      expect(commands, hasLength(3));
      expect(commands[0].command, contains('-ss 0.000'));
      expect(commands[0].command, contains('-t 10.000'));
      expect(commands[1].command, contains('-ss 10.000'));
      expect(commands[1].command, contains('-t 15.000'));
      expect(commands[2].command, contains('-ss 25.000'));
      expect(commands[2].command, contains('-t 15.000'));
    });
  });

  group('Media cutter fast stream-copy commands', () {
    test('fast video trim copies streams without re-encoding', () {
      final command = FfmpegMediaCutterService.buildTrimCommand(
        inputPath: 'C:/clips/source video.mp4',
        outputPath: 'C:/clips/output.mp4',
        startSeconds: 1.25,
        endSeconds: 5.75,
        mediaType: CutterMediaType.video,
        streamCopy: true,
      );

      expect(command, contains('-ss 1.250'));
      expect(command, contains('-t 4.500'));
      expect(command, contains('-map 0:v:0'));
      expect(command, contains('-map 0:a?'));
      expect(command, contains('-c copy'));
      expect(command, contains('-avoid_negative_ts make_zero'));
      expect(command, contains('-movflags +faststart'));
      expect(command, isNot(contains('libx264')));
      expect(command, isNot(contains('-c:v')));
      expect(command, isNot(contains('-c:a')));
    });

    test('fast audio trim copies without video', () {
      final command = FfmpegMediaCutterService.buildTrimCommand(
        inputPath: 'C:/clips/source.mp3',
        outputPath: 'C:/clips/output.m4a',
        startSeconds: 0,
        endSeconds: 12,
        mediaType: CutterMediaType.audio,
        streamCopy: true,
      );

      expect(command, contains('-ss 0.000'));
      expect(command, contains('-t 12.000'));
      expect(command, contains('-vn'));
      expect(command, contains('-c copy'));
      expect(command, isNot(contains('-c:a')));
      expect(command, isNot(contains('aac')));
    });

    test('default trim behavior stays re-encoding', () {
      final command = FfmpegMediaCutterService.buildTrimCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        startSeconds: 0,
        endSeconds: 4,
        mediaType: CutterMediaType.video,
      );

      expect(command, contains('-c:v libx264'));
      expect(command, isNot(contains('-c copy')));
    });

    test('fast remove in the middle yields two copy parts and a concat step', () {
      final commands = FfmpegMediaCutterService.buildFastRemoveCommands(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        listFilePath: 'C:/clips/concat_list.txt',
        removeStartSeconds: 2,
        removeEndSeconds: 4,
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.video,
      );

      expect(commands, hasLength(3));
      expect(commands[0].outputPath, contains('output_fast_part1.mp4'));
      expect(commands[0].command, contains('-ss 0.000'));
      expect(commands[0].command, contains('-t 2.000'));
      expect(commands[1].outputPath, contains('output_fast_part2.mp4'));
      expect(commands[1].command, contains('-ss 4.000'));
      expect(commands[1].command, contains('-t 6.000'));
      // Per-part durations feed the part-aware progress reporting.
      expect(commands[0].durationSeconds, 2.0);
      expect(commands[1].durationSeconds, 6.0);

      final merge = commands[2];
      expect(merge.outputPath, 'C:/clips/output.mp4');
      expect(merge.command, contains('-f concat'));
      expect(merge.command, contains('-safe 0'));
      expect(merge.command, contains('"C:/clips/concat_list.txt"'));
      expect(merge.command, contains('-c copy'));
      expect(merge.command, contains('-movflags +faststart'));

      for (final item in commands) {
        expect(item.command, contains('-c copy'));
        expect(item.command, isNot(contains('libx264')));
        expect(item.command, isNot(contains('aac')));
      }
    });

    test('fast remove from zero copies the tail straight to the output', () {
      final commands = FfmpegMediaCutterService.buildFastRemoveCommands(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        listFilePath: 'C:/clips/concat_list.txt',
        removeStartSeconds: 0,
        removeEndSeconds: 4,
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.video,
      );

      expect(commands, hasLength(1));
      expect(commands[0].outputPath, 'C:/clips/output.mp4');
      expect(commands[0].command, contains('-ss 4.000'));
      expect(commands[0].command, contains('-t 6.000'));
      expect(commands[0].command, contains('-c copy'));
      expect(commands[0].command, isNot(contains('-f concat')));
    });

    test('fast remove to the end copies the head straight to the output', () {
      final commands = FfmpegMediaCutterService.buildFastRemoveCommands(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        listFilePath: 'C:/clips/concat_list.txt',
        removeStartSeconds: 6,
        removeEndSeconds: 10,
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.video,
      );

      expect(commands, hasLength(1));
      expect(commands[0].outputPath, 'C:/clips/output.mp4');
      expect(commands[0].command, contains('-ss 0.000'));
      expect(commands[0].command, contains('-t 6.000'));
      expect(commands[0].command, contains('-c copy'));
      expect(commands[0].command, isNot(contains('-f concat')));
    });

    test('fast remove refuses to delete the whole file', () {
      expect(
        () => FfmpegMediaCutterService.buildFastRemoveCommands(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          listFilePath: 'C:/clips/concat_list.txt',
          removeStartSeconds: 0,
          removeEndSeconds: 10,
          totalDurationSeconds: 10,
          mediaType: CutterMediaType.video,
        ),
        throwsArgumentError,
      );
    });

    test('fast split copies every part without re-encoding', () {
      final commands = FfmpegMediaCutterService.buildSplitAtCutsCommands(
        inputPath: 'C:/clips/source.mp4',
        outputDirectory: 'C:/clips/split',
        baseName: 'source',
        cutPointsSeconds: const [10, 25],
        totalDurationSeconds: 40,
        mediaType: CutterMediaType.video,
        streamCopy: true,
      );

      expect(commands, hasLength(3));
      expect(commands[0].command, contains('-ss 0.000'));
      expect(commands[1].command, contains('-ss 10.000'));
      expect(commands[2].command, contains('-t 15.000'));
      for (final item in commands) {
        expect(item.command, contains('-c copy'));
        expect(item.command, contains('-map 0:v:0'));
        expect(item.command, isNot(contains('libx264')));
      }
    });
  });

  group('Media cutter fast copy compatibility', () {
    test('h264 video with aac audio is compatible', () {
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'h264',
          audioCodec: 'aac',
        ),
        isTrue,
      );
    });

    test('h264 video without an audio stream is compatible', () {
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'h264',
          audioCodec: null,
        ),
        isTrue,
      );
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'h264',
          audioCodec: '',
        ),
        isTrue,
      );
    });

    test('vp8 video is rejected', () {
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'vp8',
          audioCodec: 'aac',
        ),
        isFalse,
      );
    });

    test('h264 video with opus audio is rejected', () {
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'h264',
          audioCodec: 'opus',
        ),
        isFalse,
      );
    });

    test('hevc and mpeg4 video with mp3 audio are compatible', () {
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'hevc',
          audioCodec: 'mp3',
        ),
        isTrue,
      );
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'h265',
          audioCodec: 'aac',
        ),
        isTrue,
      );
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'mpeg4',
          audioCodec: 'mp3',
        ),
        isTrue,
      );
    });

    test('unknown video codecs and codecs are case-insensitive', () {
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'prores',
          audioCodec: 'aac',
        ),
        isFalse,
      );
      expect(
        FfmpegMediaCutterService.isFastCopyCompatible(
          videoCodec: 'H264',
          audioCodec: 'AAC',
        ),
        isTrue,
      );
    });
  });

  group('Media cutter remove preview command', () {
    test('middle removal concats two windows around the splice point', () {
      final command = FfmpegMediaCutterService.buildRemovePreviewCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        removeStartSeconds: 20,
        removeEndSeconds: 25,
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
        windowSeconds: 4,
      );

      expect(command, contains('trim=start=16.000:end=20.000'));
      expect(command, contains('atrim=start=16.000:end=20.000'));
      expect(command, contains('trim=start=25.000:end=29.000'));
      expect(command, contains('atrim=start=25.000:end=29.000'));
      expect(command, contains('concat=n=2:v=1:a=1[outv][outa]'));
      expect(command, contains('-c:v libx264 -crf 18 -preset veryfast'));
      expect(command, contains('-c:a aac -b:a 192k'));
      expect(command, contains('-movflags +faststart'));
      // Windowed preview never seeks the whole input from 0.
      expect(command, isNot(contains('-ss ')));
    });

    test('removal starting at 0 keeps only the post window', () {
      final command = FfmpegMediaCutterService.buildRemovePreviewCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        removeStartSeconds: 0,
        removeEndSeconds: 25,
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
      );

      expect(command, contains('-ss 25.000'));
      expect(command, contains('-t 5.000'));
      expect(command, isNot(contains('concat=')));
    });

    test('removal extending to the end keeps only the pre window', () {
      final command = FfmpegMediaCutterService.buildRemovePreviewCommand(
        inputPath: 'C:/clips/source.mp3',
        outputPath: 'C:/clips/output.m4a',
        removeStartSeconds: 20,
        removeEndSeconds: 60,
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.audio,
      );

      expect(command, contains('-ss 15.000'));
      expect(command, contains('-t 5.000'));
      expect(command, contains('-vn'));
      expect(command, isNot(contains('concat=')));
    });

    test('removing the whole file throws', () {
      expect(
        () => FfmpegMediaCutterService.buildRemovePreviewCommand(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          removeStartSeconds: 0,
          removeEndSeconds: 60,
          totalDurationSeconds: 60,
          mediaType: CutterMediaType.video,
        ),
        throwsArgumentError,
      );
    });

    test('audio-only removal concats atrim windows', () {
      final command = FfmpegMediaCutterService.buildRemovePreviewCommand(
        inputPath: 'C:/clips/source.mp3',
        outputPath: 'C:/clips/output.m4a',
        removeStartSeconds: 20,
        removeEndSeconds: 25,
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.audio,
      );

      expect(command, contains('atrim=start=15.000:end=20.000'));
      expect(command, contains('atrim=start=25.000:end=30.000'));
      expect(command, contains('concat=n=2:v=0:a=1[outa]'));
      expect(command, contains('-c:a aac -b:a 256k'));
      expect(command, isNot(contains('[0:v]')));
    });

    test('video removal without audio concats video-only windows', () {
      final command = FfmpegMediaCutterService.buildRemovePreviewCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        removeStartSeconds: 20,
        removeEndSeconds: 25,
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
        hasAudio: false,
      );

      expect(command, contains('trim=start=15.000:end=20.000'));
      expect(command, contains('trim=start=25.000:end=30.000'));
      expect(command, contains('concat=n=2:v=1:a=0[outv]'));
      expect(command, contains('-map "[outv]"'));
      expect(command, isNot(contains('[0:a]')));
    });
  });

  group('Media cutter multi remove command', () {
    test('two removal ranges keep three segments in timeline order', () {
      final command = FfmpegMediaCutterService.buildMultiRemoveCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        ranges: const [
          RemoveRange(start: 10, end: 15),
          RemoveRange(start: 40, end: 50),
        ],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
      );

      // Kept segments: [0-10], [15-40], [50-60].
      expect(
        command,
        contains('[0:v]trim=start=0.000:end=10.000,setpts=PTS-STARTPTS[v0];'),
      );
      expect(
        command,
        contains(
          '[0:a]atrim=start=0.000:end=10.000,asetpts=PTS-STARTPTS[a0];',
        ),
      );
      expect(
        command,
        contains('[0:v]trim=start=15.000:end=40.000,setpts=PTS-STARTPTS[v1];'),
      );
      expect(
        command,
        contains(
          '[0:a]atrim=start=15.000:end=40.000,asetpts=PTS-STARTPTS[a1];',
        ),
      );
      expect(
        command,
        contains('[0:v]trim=start=50.000:end=60.000,setpts=PTS-STARTPTS[v2];'),
      );
      expect(
        command,
        contains(
          '[0:a]atrim=start=50.000:end=60.000,asetpts=PTS-STARTPTS[a2];',
        ),
      );
      expect(
        command,
        contains('[v0][a0][v1][a1][v2][a2]concat=n=3:v=1:a=1[outv][outa]'),
      );
      expect(command, contains('-c:v libx264 -crf 18 -preset veryfast'));
      expect(command, contains('-c:a aac -b:a 192k'));
      expect(command, contains('-movflags +faststart'));

      // trim/atrim pairs stay interleaved per segment in timeline order.
      final order = [
        command.indexOf('trim=start=0.000:end=10.000'),
        command.indexOf('atrim=start=0.000:end=10.000'),
        command.indexOf('trim=start=15.000:end=40.000'),
        command.indexOf('atrim=start=15.000:end=40.000'),
        command.indexOf('trim=start=50.000:end=60.000'),
        command.indexOf('atrim=start=50.000:end=60.000'),
      ];
      for (var i = 1; i < order.length; i++) {
        expect(order[i], greaterThan(order[i - 1]));
      }
    });

    test('single middle range matches buildRemoveCommand exactly', () {
      const inputPath = 'C:/clips/source.mp4';
      const outputPath = 'C:/clips/output.mp4';
      final multi = FfmpegMediaCutterService.buildMultiRemoveCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        ranges: const [RemoveRange(start: 2, end: 4)],
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.video,
      );
      final reference = FfmpegMediaCutterService.buildRemoveCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        removeStartSeconds: 2,
        removeEndSeconds: 4,
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.video,
      );

      expect(multi, reference);
    });

    test('single middle audio range matches buildRemoveCommand exactly', () {
      const inputPath = 'C:/clips/source.mp3';
      const outputPath = 'C:/clips/output.m4a';
      final multi = FfmpegMediaCutterService.buildMultiRemoveCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        ranges: const [RemoveRange(start: 2, end: 4)],
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.audio,
      );
      final reference = FfmpegMediaCutterService.buildRemoveCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        removeStartSeconds: 2,
        removeEndSeconds: 4,
        totalDurationSeconds: 10,
        mediaType: CutterMediaType.audio,
      );

      expect(multi, reference);
    });

    test(
      'single middle video-only range matches buildRemoveCommand exactly',
      () {
        const inputPath = 'C:/clips/source.mp4';
        const outputPath = 'C:/clips/output.mp4';
        final multi = FfmpegMediaCutterService.buildMultiRemoveCommand(
          inputPath: inputPath,
          outputPath: outputPath,
          ranges: const [RemoveRange(start: 2, end: 4)],
          totalDurationSeconds: 10,
          mediaType: CutterMediaType.video,
          hasAudio: false,
        );
        final reference = FfmpegMediaCutterService.buildRemoveCommand(
          inputPath: inputPath,
          outputPath: outputPath,
          removeStartSeconds: 2,
          removeEndSeconds: 4,
          totalDurationSeconds: 10,
          mediaType: CutterMediaType.video,
          hasAudio: false,
        );

        expect(multi, reference);
      },
    );

    test('audio-only multi remove concats atrim segments only', () {
      final command = FfmpegMediaCutterService.buildMultiRemoveCommand(
        inputPath: 'C:/clips/source.mp3',
        outputPath: 'C:/clips/output.m4a',
        ranges: const [
          RemoveRange(start: 10, end: 15),
          RemoveRange(start: 40, end: 50),
        ],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.audio,
      );

      expect(command, contains('[0:a]atrim=start=0.000:end=10.000'));
      expect(command, contains('[0:a]atrim=start=15.000:end=40.000'));
      expect(command, contains('[0:a]atrim=start=50.000:end=60.000'));
      expect(command, contains('[a0][a1][a2]concat=n=3:v=0:a=1[outa]'));
      expect(command, contains('-c:a aac -b:a 256k'));
      expect(command, isNot(contains('[0:v]')));
    });

    test('video without audio concats trim segments only', () {
      final command = FfmpegMediaCutterService.buildMultiRemoveCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        ranges: const [
          RemoveRange(start: 10, end: 15),
          RemoveRange(start: 40, end: 50),
        ],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
        hasAudio: false,
      );

      expect(command, contains('[0:v]trim=start=0.000:end=10.000'));
      expect(command, contains('[0:v]trim=start=15.000:end=40.000'));
      expect(command, contains('[0:v]trim=start=50.000:end=60.000'));
      expect(command, contains('[v0][v1][v2]concat=n=3:v=1:a=0[outv]'));
      expect(command, contains('-map "[outv]"'));
      expect(command, isNot(contains('[0:a]')));
    });

    test('empty ranges throw', () {
      expect(
        () => FfmpegMediaCutterService.buildMultiRemoveCommand(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          ranges: const [],
          totalDurationSeconds: 60,
          mediaType: CutterMediaType.video,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'At least one removal range is required',
          ),
        ),
      );
    });

    test('overlapping ranges throw', () {
      expect(
        () => FfmpegMediaCutterService.buildMultiRemoveCommand(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          ranges: const [
            RemoveRange(start: 10, end: 20),
            RemoveRange(start: 15, end: 25),
          ],
          totalDurationSeconds: 60,
          mediaType: CutterMediaType.video,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Removal ranges overlap',
          ),
        ),
      );
    });

    test('removing the whole file throws', () {
      expect(
        () => FfmpegMediaCutterService.buildMultiRemoveCommand(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          ranges: const [RemoveRange(start: 0, end: 60)],
          totalDurationSeconds: 60,
          mediaType: CutterMediaType.video,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Cannot remove the entire media file',
          ),
        ),
      );
    });

    test('zero-length kept segments are ignored', () {
      final command = FfmpegMediaCutterService.buildMultiRemoveCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        ranges: const [
          RemoveRange(start: 10, end: 15),
          RemoveRange(start: 15.0005, end: 20),
        ],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
      );

      // [15, 15.0005] is rounding debris, so only [0-10] and [20-60] remain.
      expect(command, contains('trim=start=0.000:end=10.000'));
      expect(command, contains('trim=start=20.000:end=60.000'));
      expect(command, contains('concat=n=2:v=1:a=1[outv][outa]'));
      final videoSegments = RegExp(
        'setpts=PTS-STARTPTS\\[v\\d+\\]',
      ).allMatches(command);
      expect(videoSegments, hasLength(2));
    });

    test('removal from the start starts the first trim at the range end', () {
      final command = FfmpegMediaCutterService.buildMultiRemoveCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        ranges: const [RemoveRange(start: 0, end: 10)],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
      );

      expect(command, contains('trim=start=10.000:end=60.000'));
      expect(command, contains('atrim=start=10.000:end=60.000'));
      expect(command, contains('concat=n=1:v=1:a=1[outv][outa]'));
    });
  });

  group('Media cutter fast multi remove commands', () {
    test('three kept segments yield three copies plus a concat merge', () {
      final commands = FfmpegMediaCutterService.buildFastMultiRemoveCommands(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        listFilePath: 'C:/clips/concat_list.txt',
        ranges: const [
          RemoveRange(start: 10, end: 15),
          RemoveRange(start: 40, end: 50),
        ],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
      );

      expect(commands, hasLength(4));
      expect(commands[0].outputPath, contains('output_fast_part1.mp4'));
      expect(commands[0].command, contains('-ss 0.000'));
      expect(commands[0].command, contains('-t 10.000'));
      expect(commands[1].outputPath, contains('output_fast_part2.mp4'));
      expect(commands[1].command, contains('-ss 15.000'));
      expect(commands[1].command, contains('-t 25.000'));
      expect(commands[2].outputPath, contains('output_fast_part3.mp4'));
      expect(commands[2].command, contains('-ss 50.000'));
      expect(commands[2].command, contains('-t 10.000'));
      // Per-part durations feed the part-aware progress reporting.
      expect(commands[0].durationSeconds, 10.0);
      expect(commands[1].durationSeconds, 25.0);
      expect(commands[2].durationSeconds, 10.0);

      final merge = commands[3];
      expect(merge.outputPath, 'C:/clips/output.mp4');
      expect(merge.command, contains('-f concat'));
      expect(merge.command, contains('-safe 0'));
      expect(merge.command, contains('"C:/clips/concat_list.txt"'));
      expect(merge.command, contains('-c copy'));
      expect(merge.command, contains('-movflags +faststart'));
      expect(merge.durationSeconds, 0);

      for (final item in commands) {
        expect(item.command, contains('-c copy'));
        expect(item.command, isNot(contains('libx264')));
        expect(item.command, isNot(contains('aac')));
      }
    });

    test('single kept segment copies straight to the output', () {
      final commands = FfmpegMediaCutterService.buildFastMultiRemoveCommands(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        listFilePath: 'C:/clips/concat_list.txt',
        ranges: const [RemoveRange(start: 0, end: 10)],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
      );

      expect(commands, hasLength(1));
      expect(commands[0].outputPath, 'C:/clips/output.mp4');
      expect(commands[0].command, contains('-ss 10.000'));
      expect(commands[0].command, contains('-t 50.000'));
      expect(commands[0].command, contains('-c copy'));
      expect(commands[0].command, isNot(contains('-f concat')));
    });

    test('fast multi remove rejects empty, overlapping and full ranges', () {
      expect(
        () => FfmpegMediaCutterService.buildFastMultiRemoveCommands(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          listFilePath: 'C:/clips/concat_list.txt',
          ranges: const [],
          totalDurationSeconds: 60,
          mediaType: CutterMediaType.video,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'At least one removal range is required',
          ),
        ),
      );
      expect(
        () => FfmpegMediaCutterService.buildFastMultiRemoveCommands(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          listFilePath: 'C:/clips/concat_list.txt',
          ranges: const [
            RemoveRange(start: 10, end: 20),
            RemoveRange(start: 15, end: 25),
          ],
          totalDurationSeconds: 60,
          mediaType: CutterMediaType.video,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Removal ranges overlap',
          ),
        ),
      );
      expect(
        () => FfmpegMediaCutterService.buildFastMultiRemoveCommands(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          listFilePath: 'C:/clips/concat_list.txt',
          ranges: const [RemoveRange(start: 0, end: 60)],
          totalDurationSeconds: 60,
          mediaType: CutterMediaType.video,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Cannot remove the entire media file',
          ),
        ),
      );
    });
  });

  group('Media cutter multi remove preview command', () {
    test('windows around two ranges are concatenated in order', () {
      final command = FfmpegMediaCutterService.buildMultiRemovePreviewCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        ranges: const [
          RemoveRange(start: 10, end: 15),
          RemoveRange(start: 40, end: 50),
        ],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
        windowSeconds: 5,
      );

      // One pre/post window per range: [5-10], [15-20], [35-40], [50-55].
      expect(command, contains('trim=start=5.000:end=10.000'));
      expect(command, contains('atrim=start=5.000:end=10.000'));
      expect(command, contains('trim=start=15.000:end=20.000'));
      expect(command, contains('trim=start=35.000:end=40.000'));
      expect(command, contains('trim=start=50.000:end=55.000'));
      expect(command, contains('concat=n=4:v=1:a=1[outv][outa]'));
      expect(command, contains('-c:v libx264 -crf 18 -preset veryfast'));
      expect(command, contains('-c:a aac -b:a 192k'));
      expect(command, contains('-movflags +faststart'));
      expect(command, isNot(contains('-ss ')));
    });

    test('windows clamp at 0 and total', () {
      final command = FfmpegMediaCutterService.buildMultiRemovePreviewCommand(
        inputPath: 'C:/clips/source.mp4',
        outputPath: 'C:/clips/output.mp4',
        ranges: const [
          RemoveRange(start: 0, end: 10),
          RemoveRange(start: 50, end: 60),
        ],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.video,
      );

      // Zero-length windows at the edges are dropped, keeping [10-15]
      // and [45-50].
      expect(command, contains('trim=start=10.000:end=15.000'));
      expect(command, contains('trim=start=45.000:end=50.000'));
      expect(command, contains('concat=n=2:v=1:a=1[outv][outa]'));
      expect(command, isNot(contains('trim=start=0.000:end=0.000')));
      expect(command, isNot(contains('trim=start=60.000:end=60.000')));
    });

    test('audio-only preview concats atrim windows', () {
      final command = FfmpegMediaCutterService.buildMultiRemovePreviewCommand(
        inputPath: 'C:/clips/source.mp3',
        outputPath: 'C:/clips/output.m4a',
        ranges: const [RemoveRange(start: 20, end: 25)],
        totalDurationSeconds: 60,
        mediaType: CutterMediaType.audio,
      );

      expect(command, contains('atrim=start=15.000:end=20.000'));
      expect(command, contains('atrim=start=25.000:end=30.000'));
      expect(command, contains('concat=n=2:v=0:a=1[outa]'));
      expect(command, contains('-c:a aac -b:a 256k'));
      expect(command, isNot(contains('[0:v]')));
    });

    test('empty ranges throw', () {
      expect(
        () => FfmpegMediaCutterService.buildMultiRemovePreviewCommand(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          ranges: const [],
          totalDurationSeconds: 60,
          mediaType: CutterMediaType.video,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'At least one removal range is required',
          ),
        ),
      );
    });

    test('removing the whole file throws', () {
      expect(
        () => FfmpegMediaCutterService.buildMultiRemovePreviewCommand(
          inputPath: 'C:/clips/source.mp4',
          outputPath: 'C:/clips/output.mp4',
          ranges: const [RemoveRange(start: 0, end: 60)],
          totalDurationSeconds: 60,
          mediaType: CutterMediaType.video,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Cannot remove the entire media file',
          ),
        ),
      );
    });
  });
}
