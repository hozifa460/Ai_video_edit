import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import '../../../../core/utils/logger.dart';

enum CutterMediaType { video, audio }

enum CutterMode { keepSelection, removeSelection, splitAudio }

/// Thrown when an export is stopped through
/// [FfmpegMediaCutterService.cancel].
class MediaCutterCancelledException implements Exception {
  const MediaCutterCancelledException();

  @override
  String toString() => 'Media cutter export cancelled';
}

class MediaCutCommand {
  final String command;
  final String outputPath;

  /// Output duration in seconds, used to normalize per-part progress.
  final double durationSeconds;

  const MediaCutCommand({
    required this.command,
    required this.outputPath,
    this.durationSeconds = 0,
  });
}

/// An immutable half-open time range [start, end) in seconds to delete from
/// the media in the multi-range remove flow.
class RemoveRange {
  final double start;
  final double end;

  const RemoveRange({required this.start, required this.end});
}

class FfmpegMediaCutterService {
  FfmpegMediaCutterService();

  bool _cancelled = false;
  FFmpegSession? _activeSession;
  void Function(double progress)? _progressSink;
  double Function(double timeMs)? _progressMapper;
  int _activePartIndex = 0;
  double _activePartDurationMs = 1.0;
  int _activePartCount = 1;

  /// Mirrors the project-wide statistics callback pattern (see
  /// FfmpegAdjustmentDatasource): raw processed milliseconds are mapped to
  /// 0.0-1.0 before reaching [onProgress].
  void _enableProgressReporting(
    void Function(double progress)? onProgress,
    double Function(double timeMs) mapper,
  ) {
    _progressSink = onProgress;
    _progressMapper = mapper;
    if (onProgress == null) return;
    FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
      final time = statistics.getTime();
      final sink = _progressSink;
      final progress = _progressMapper?.call(time.toDouble());
      if (time > 0 && !_cancelled && sink != null && progress != null) {
        sink(progress);
      }
    });
  }

  /// Clears the global statistics callback so it cannot leak into other
  /// FFmpeg calls. ffmpeg_kit_flutter_new 4.1.0 has no dedicated disable
  /// method; calling enableStatisticsCallback() without arguments resets it.
  void _disableProgressReporting(void Function(double progress)? onProgress) {
    if (onProgress == null) return;
    _progressSink = null;
    _progressMapper = null;
    FFmpegKitConfig.enableStatisticsCallback();
  }

  /// Builds a trim command. With [streamCopy] the streams are copied verbatim
  /// (keyframe-aligned, no re-encode — fast but slightly imprecise); the
  /// default re-encodes for frame-accurate cuts.
  static String buildTrimCommand({
    required String inputPath,
    required String outputPath,
    required double startSeconds,
    required double endSeconds,
    required CutterMediaType mediaType,
    bool streamCopy = false,
  }) {
    _validateRange(startSeconds, endSeconds);
    final input = _q(inputPath);
    final output = _q(outputPath);
    final start = _fmt(startSeconds);
    final duration = _fmt(endSeconds - startSeconds);

    if (streamCopy) {
      if (mediaType == CutterMediaType.audio) {
        return '-ss $start -i $input -t $duration -vn -c copy -y $output';
      }
      return '-ss $start -i $input -t $duration '
          '-map 0:v:0 -map 0:a? '
          '-c copy -avoid_negative_ts make_zero -movflags +faststart -y $output';
    }

    if (mediaType == CutterMediaType.audio) {
      return '-ss $start -i $input -t $duration -vn '
          '-c:a aac -b:a 256k -y $output';
    }

    return '-ss $start -i $input -t $duration '
        '-map 0:v:0 -map 0:a? '
        '-c:v libx264 -crf 18 -preset veryfast '
        '-c:a aac -b:a 192k '
        '-avoid_negative_ts make_zero -movflags +faststart -y $output';
  }

  static String buildRemoveCommand({
    required String inputPath,
    required String outputPath,
    required double removeStartSeconds,
    required double removeEndSeconds,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool hasAudio = true,
  }) {
    _validateRange(removeStartSeconds, removeEndSeconds);
    if (totalDurationSeconds <= 0) {
      throw ArgumentError('totalDurationSeconds must be positive');
    }
    if (removeStartSeconds <= 0 && removeEndSeconds >= totalDurationSeconds) {
      throw ArgumentError('Cannot remove the entire media file');
    }
    if (removeStartSeconds <= 0) {
      return buildTrimCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        startSeconds: removeEndSeconds,
        endSeconds: totalDurationSeconds,
        mediaType: mediaType,
      );
    }
    if (removeEndSeconds >= totalDurationSeconds) {
      return buildTrimCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        startSeconds: 0,
        endSeconds: removeStartSeconds,
        mediaType: mediaType,
      );
    }

    final input = _q(inputPath);
    final output = _q(outputPath);
    final start = _fmt(removeStartSeconds);
    final end = _fmt(removeEndSeconds);
    final total = _fmt(totalDurationSeconds);

    if (mediaType == CutterMediaType.audio) {
      final filter =
          '[0:a]atrim=start=0.000:end=$start,asetpts=PTS-STARTPTS[a0];'
          '[0:a]atrim=start=$end:end=$total,asetpts=PTS-STARTPTS[a1];'
          '[a0][a1]concat=n=2:v=0:a=1[outa]';
      return '-i $input -filter_complex "$filter" -map "[outa]" '
          '-c:a aac -b:a 256k -y $output';
    }

    if (!hasAudio) {
      final filter =
          '[0:v]trim=start=0.000:end=$start,setpts=PTS-STARTPTS[v0];'
          '[0:v]trim=start=$end:end=$total,setpts=PTS-STARTPTS[v1];'
          '[v0][v1]concat=n=2:v=1:a=0[outv]';
      return '-i $input -filter_complex "$filter" '
          '-map "[outv]" '
          '-c:v libx264 -crf 18 -preset veryfast '
          '-movflags +faststart -y $output';
    }

    final filter =
        '[0:v]trim=start=0.000:end=$start,setpts=PTS-STARTPTS[v0];'
        '[0:a]atrim=start=0.000:end=$start,asetpts=PTS-STARTPTS[a0];'
        '[0:v]trim=start=$end:end=$total,setpts=PTS-STARTPTS[v1];'
        '[0:a]atrim=start=$end:end=$total,asetpts=PTS-STARTPTS[a1];'
        '[v0][a0][v1][a1]concat=n=2:v=1:a=1[outv][outa]';
    return '-i $input -filter_complex "$filter" '
        '-map "[outv]" -map "[outa]" '
        '-c:v libx264 -crf 18 -preset veryfast '
        '-c:a aac -b:a 192k -movflags +faststart -y $output';
  }

  /// Builds a single filter_complex command that removes every [ranges]
  /// interval from the media in one pass: the kept (complement) segments are
  /// extracted with trim/atrim and concatenated in timeline order, reusing
  /// the exact filter and encoding patterns of [buildRemoveCommand].
  static String buildMultiRemoveCommand({
    required String inputPath,
    required String outputPath,
    required List<RemoveRange> ranges,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool hasAudio = true,
  }) {
    final kept = _keptSegments(ranges, totalDurationSeconds);
    if (kept.isEmpty) {
      throw ArgumentError('Cannot remove the entire media file');
    }
    return _buildMultiSegmentCommand(
      inputPath: inputPath,
      outputPath: outputPath,
      segments: kept,
      mediaType: mediaType,
      hasAudio: hasAudio,
    );
  }

  /// Builds the fast (stream-copy) removal plan as sequential commands:
  /// - middle removal: part1 [0, removeStart] + part2 [removeEnd, total], then
  ///   a concat-demuxer merge step reading [listFilePath] (the caller provides
  ///   that path; the executor writes the file and cleans it up afterwards);
  /// - removal touching one edge: a single copy straight to the output, no
  ///   merge step.
  /// The intermediate part files sit next to the output and are removed by
  /// [cutFastRemove] once the export settles.
  static List<MediaCutCommand> buildFastRemoveCommands({
    required String inputPath,
    required String outputPath,
    required String listFilePath,
    required double removeStartSeconds,
    required double removeEndSeconds,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
  }) {
    _validateRange(removeStartSeconds, removeEndSeconds);
    if (totalDurationSeconds <= 0) {
      throw ArgumentError('totalDurationSeconds must be positive');
    }
    if (removeStartSeconds <= 0 && removeEndSeconds >= totalDurationSeconds) {
      throw ArgumentError('Cannot remove the entire media file');
    }

    MediaCutCommand copyPart(String partOutput, double start, double end) {
      return MediaCutCommand(
        command: buildTrimCommand(
          inputPath: inputPath,
          outputPath: partOutput,
          startSeconds: start,
          endSeconds: end,
          mediaType: mediaType,
          streamCopy: true,
        ),
        outputPath: partOutput,
        durationSeconds: end - start,
      );
    }

    if (removeStartSeconds <= 0) {
      return [copyPart(outputPath, removeEndSeconds, totalDurationSeconds)];
    }
    if (removeEndSeconds >= totalDurationSeconds) {
      return [copyPart(outputPath, 0, removeStartSeconds)];
    }

    final part1 = copyPart(
      _siblingOutputPath(outputPath, '_fast_part1'),
      0,
      removeStartSeconds,
    );
    final part2 = copyPart(
      _siblingOutputPath(outputPath, '_fast_part2'),
      removeEndSeconds,
      totalDurationSeconds,
    );
    final merge = MediaCutCommand(
      // Same shape as every other command here: FFmpegKit supplies the binary,
      // so the string starts at the arguments.
      command: '-f concat -safe 0 -i ${_q(listFilePath)} '
          '-c copy -movflags +faststart -y ${_q(outputPath)}',
      outputPath: outputPath,
      // The merge is a container-level copy with no meaningful duration to
      // weight; progress jumps when the step completes instead.
      durationSeconds: 0,
    );
    return [part1, part2, merge];
  }

  /// Fast (stream-copy) multi-range removal plan: every kept segment is
  /// copied with [buildTrimCommand] (streamCopy) into `_fast_partN` siblings
  /// of [outputPath], then a concat-demuxer merge step joins them (the caller
  /// provides [listFilePath], writes nothing and cleans everything up — see
  /// [cutFastMultiRemove]). A single kept segment copies straight to the
  /// output with no merge step. Same guards as [buildMultiRemoveCommand].
  static List<MediaCutCommand> buildFastMultiRemoveCommands({
    required String inputPath,
    required String outputPath,
    required String listFilePath,
    required List<RemoveRange> ranges,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
  }) {
    final kept = _keptSegments(ranges, totalDurationSeconds);
    if (kept.isEmpty) {
      throw ArgumentError('Cannot remove the entire media file');
    }

    if (kept.length == 1) {
      return [
        MediaCutCommand(
          command: buildTrimCommand(
            inputPath: inputPath,
            outputPath: outputPath,
            startSeconds: kept.first.$1,
            endSeconds: kept.first.$2,
            mediaType: mediaType,
            streamCopy: true,
          ),
          outputPath: outputPath,
          durationSeconds: kept.first.$2 - kept.first.$1,
        ),
      ];
    }

    final commands = <MediaCutCommand>[];
    for (var i = 0; i < kept.length; i++) {
      final partOutput = _siblingOutputPath(outputPath, '_fast_part${i + 1}');
      commands.add(
        MediaCutCommand(
          command: buildTrimCommand(
            inputPath: inputPath,
            outputPath: partOutput,
            startSeconds: kept[i].$1,
            endSeconds: kept[i].$2,
            mediaType: mediaType,
            streamCopy: true,
          ),
          outputPath: partOutput,
          durationSeconds: kept[i].$2 - kept[i].$1,
        ),
      );
    }
    commands.add(
      MediaCutCommand(
        command: '-f concat -safe 0 -i ${_q(listFilePath)} '
            '-c copy -movflags +faststart -y ${_q(outputPath)}',
        outputPath: outputPath,
        durationSeconds: 0,
      ),
    );
    return commands;
  }

  static const Set<String> _fastCopyVideoCodecs = {'h264', 'hevc', 'h265', 'mpeg4'};
  static const Set<String> _fastCopyAudioCodecs = {'aac', 'mp3'};

  /// Pure compatibility decision for stream-copy exports: only widely muxed
  /// codec pairs are allowed. vp8/vp9/opus and anything unknown are rejected
  /// on purpose — they either mux poorly into mp4 or trip up players.
  /// A missing/unknown audio codec is fine: the copy maps audio optionally.
  static bool isFastCopyCompatible({
    required String? videoCodec,
    required String? audioCodec,
  }) {
    final video = videoCodec?.trim().toLowerCase() ?? '';
    final audio = audioCodec?.trim().toLowerCase() ?? '';
    if (!_fastCopyVideoCodecs.contains(video)) return false;
    return audio.isEmpty || _fastCopyAudioCodecs.contains(audio);
  }

  /// Inserts [suffix] before the extension of an output path, e.g.
  /// out.mp4 -> out_fast_part1.mp4. Paths without an extension get the
  /// suffix appended.
  static String _siblingOutputPath(String outputPath, String suffix) {
    final posix = outputPath.replaceAll('\\', '/');
    final dot = posix.lastIndexOf('.');
    final slash = posix.lastIndexOf('/');
    if (dot <= slash) return '$posix$suffix';
    return '${posix.substring(0, dot)}$suffix${posix.substring(dot)}';
  }

  /// Builds a short preview command for remove-selection mode: instead of
  /// re-encoding the whole file, it keeps only a [windowSeconds]-long window
  /// before and after the removed range and concatenates the two pieces so
  /// the splice point stays visible. Falls back to a single trim when the
  /// removal touches one edge of the file.
  static String buildRemovePreviewCommand({
    required String inputPath,
    required String outputPath,
    required double removeStartSeconds,
    required double removeEndSeconds,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool hasAudio = true,
    double windowSeconds = 5,
  }) {
    _validateRange(removeStartSeconds, removeEndSeconds);
    if (totalDurationSeconds <= 0) {
      throw ArgumentError('totalDurationSeconds must be positive');
    }
    if (windowSeconds <= 0) {
      throw ArgumentError('windowSeconds must be positive');
    }
    if (removeStartSeconds <= 0 && removeEndSeconds >= totalDurationSeconds) {
      throw ArgumentError('Cannot remove the entire media file');
    }

    final hasPrePart = removeStartSeconds > 0;
    final hasPostPart = removeEndSeconds < totalDurationSeconds;

    if (!hasPrePart) {
      return buildTrimCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        startSeconds: removeEndSeconds,
        endSeconds: (removeEndSeconds + windowSeconds)
            .clamp(0.0, totalDurationSeconds)
            .toDouble(),
        mediaType: mediaType,
      );
    }
    if (!hasPostPart) {
      return buildTrimCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        startSeconds: (removeStartSeconds - windowSeconds)
            .clamp(0.0, double.infinity)
            .toDouble(),
        endSeconds: removeStartSeconds,
        mediaType: mediaType,
      );
    }

    final input = _q(inputPath);
    final output = _q(outputPath);
    final preStart = _fmt(
      (removeStartSeconds - windowSeconds)
          .clamp(0.0, double.infinity)
          .toDouble(),
    );
    final preEnd = _fmt(removeStartSeconds);
    final postStart = _fmt(removeEndSeconds);
    final postEnd = _fmt(
      (removeEndSeconds + windowSeconds)
          .clamp(0.0, totalDurationSeconds)
          .toDouble(),
    );

    if (mediaType == CutterMediaType.audio) {
      final filter =
          '[0:a]atrim=start=$preStart:end=$preEnd,asetpts=PTS-STARTPTS[a0];'
          '[0:a]atrim=start=$postStart:end=$postEnd,asetpts=PTS-STARTPTS[a1];'
          '[a0][a1]concat=n=2:v=0:a=1[outa]';
      return '-i $input -filter_complex "$filter" -map "[outa]" '
          '-c:a aac -b:a 256k -y $output';
    }

    if (!hasAudio) {
      final filter =
          '[0:v]trim=start=$preStart:end=$preEnd,setpts=PTS-STARTPTS[v0];'
          '[0:v]trim=start=$postStart:end=$postEnd,setpts=PTS-STARTPTS[v1];'
          '[v0][v1]concat=n=2:v=1:a=0[outv]';
      return '-i $input -filter_complex "$filter" '
          '-map "[outv]" '
          '-c:v libx264 -crf 18 -preset veryfast '
          '-movflags +faststart -y $output';
    }

    final filter =
        '[0:v]trim=start=$preStart:end=$preEnd,setpts=PTS-STARTPTS[v0];'
        '[0:a]atrim=start=$preStart:end=$preEnd,asetpts=PTS-STARTPTS[a0];'
        '[0:v]trim=start=$postStart:end=$postEnd,setpts=PTS-STARTPTS[v1];'
        '[0:a]atrim=start=$postStart:end=$postEnd,asetpts=PTS-STARTPTS[a1];'
        '[v0][a0][v1][a1]concat=n=2:v=1:a=1[outv][outa]';
    return '-i $input -filter_complex "$filter" '
        '-map "[outv]" -map "[outa]" '
        '-c:v libx264 -crf 18 -preset veryfast '
        '-c:a aac -b:a 192k -movflags +faststart -y $output';
  }

  /// Multi-range version of [buildRemovePreviewCommand]: every removal range
  /// contributes a [windowSeconds]-long window before its start and after its
  /// end (clamped to the file like the single-range preview), then all
  /// windows are concatenated with the same filter patterns. Windows that
  /// clamp down to nothing or overlap a neighbour are dropped/merged so close
  /// ranges never duplicate content.
  static String buildMultiRemovePreviewCommand({
    required String inputPath,
    required String outputPath,
    required List<RemoveRange> ranges,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool hasAudio = true,
    double windowSeconds = 5,
  }) {
    if (totalDurationSeconds <= 0) {
      throw ArgumentError('totalDurationSeconds must be positive');
    }
    if (windowSeconds <= 0) {
      throw ArgumentError('windowSeconds must be positive');
    }
    final sorted = _validatedSortedRanges(ranges);

    final windows = <(double, double)>[];
    for (final range in sorted) {
      final start = range.start.clamp(0.0, totalDurationSeconds).toDouble();
      final end = range.end.clamp(0.0, totalDurationSeconds).toDouble();
      windows.add((
        (start - windowSeconds).clamp(0.0, double.infinity).toDouble(),
        start,
      ));
      windows.add((
        end,
        (end + windowSeconds).clamp(0.0, totalDurationSeconds).toDouble(),
      ));
    }
    windows.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(double, double)>[];
    for (final window in windows) {
      if (window.$2 - window.$1 < 0.001) continue;
      final last = merged.isEmpty ? null : merged.last;
      if (last != null && window.$1 <= last.$2 + 0.001) {
        if (window.$2 > last.$2) {
          merged[merged.length - 1] = (last.$1, window.$2);
        }
      } else {
        merged.add(window);
      }
    }
    if (merged.isEmpty) {
      throw ArgumentError('Cannot remove the entire media file');
    }

    return _buildMultiSegmentCommand(
      inputPath: inputPath,
      outputPath: outputPath,
      segments: merged,
      mediaType: mediaType,
      hasAudio: hasAudio,
    );
  }

  Future<String?> cut({
    required String inputPath,
    required String outputPath,
    required double startSeconds,
    required double endSeconds,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    required CutterMode mode,
    bool hasAudio = true,
    void Function(double progress)? onProgress,
  }) async {
    final command = mode == CutterMode.keepSelection
        ? buildTrimCommand(
            inputPath: inputPath,
            outputPath: outputPath,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            mediaType: mediaType,
          )
        : buildRemoveCommand(
            inputPath: inputPath,
            outputPath: outputPath,
            removeStartSeconds: startSeconds,
            removeEndSeconds: endSeconds,
            totalDurationSeconds: totalDurationSeconds,
            mediaType: mediaType,
            hasAudio: hasAudio,
          );

    AppLogger().i('Media cutter command: $command');
    final totalMs = (totalDurationSeconds <= 0 ? 1.0 : totalDurationSeconds * 1000)
        .clamp(1.0, double.infinity)
        .toDouble();
    _enableProgressReporting(
      onProgress,
      (timeMs) => (timeMs / totalMs).clamp(0.0, 1.0),
    );
    try {
      final session = await _run(command);
      if (_cancelled) throw const MediaCutterCancelledException();

      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) return outputPath;

      final logs = await session.getAllLogsAsString();
      AppLogger().e('Media cutter failed: $logs');
      return null;
    } finally {
      _disableProgressReporting(onProgress);
    }
  }

  /// Fast variant of [cut] for keep-selection exports: the trim copies the
  /// streams instead of re-encoding ([buildTrimCommand] with streamCopy).
  /// Progress works like [cut]; if the copy fails (return code unsuccessful),
  /// the reasons are logged and the export automatically falls back to the
  /// re-encoding [cut] so container/codec quirks never surface to the user.
  Future<String?> cutFast({
    required String inputPath,
    required String outputPath,
    required double startSeconds,
    required double endSeconds,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    void Function(double progress)? onProgress,
  }) async {
    final command = buildTrimCommand(
      inputPath: inputPath,
      outputPath: outputPath,
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      mediaType: mediaType,
      streamCopy: true,
    );

    AppLogger().i('Media cutter fast command: $command');
    final totalMs = (totalDurationSeconds <= 0 ? 1.0 : totalDurationSeconds * 1000)
        .clamp(1.0, double.infinity)
        .toDouble();
    _enableProgressReporting(
      onProgress,
      (timeMs) => (timeMs / totalMs).clamp(0.0, 1.0),
    );
    final String? fastResult;
    try {
      final session = await _run(command);
      if (_cancelled) throw const MediaCutterCancelledException();

      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) {
        fastResult = outputPath;
      } else {
        final logs = await session.getAllLogsAsString();
        AppLogger().e(
          'Media cutter fast copy failed; falling back to re-encode: $logs',
        );
        fastResult = null;
      }
    } finally {
      _disableProgressReporting(onProgress);
    }
    if (fastResult != null) return fastResult;

    return cut(
      inputPath: inputPath,
      outputPath: outputPath,
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      totalDurationSeconds: totalDurationSeconds,
      mediaType: mediaType,
      mode: CutterMode.keepSelection,
      onProgress: onProgress,
    );
  }

  /// Fast remove-selection export: copies the two kept parts with
  /// [buildFastRemoveCommands] and merges them via the concat demuxer, all
  /// without re-encoding. [listFilePath] (provided by the caller) receives the
  /// concat list file; it and the intermediate parts are deleted in a finally
  /// block on success, failure or cancellation. If any copy step fails, the
  /// reasons are logged and the export falls back to the re-encoding [cut]
  /// ([hasAudio] is only used by that fallback path). Progress is part-aware
  /// like [splitAtCuts], with the quick merge step jumping on completion.
  Future<String?> cutFastRemove({
    required String inputPath,
    required String outputPath,
    required String listFilePath,
    required double removeStartSeconds,
    required double removeEndSeconds,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool hasAudio = true,
    void Function(double progress)? onProgress,
  }) async {
    final commands = buildFastRemoveCommands(
      inputPath: inputPath,
      outputPath: outputPath,
      listFilePath: listFilePath,
      removeStartSeconds: removeStartSeconds,
      removeEndSeconds: removeEndSeconds,
      totalDurationSeconds: totalDurationSeconds,
      mediaType: mediaType,
    );
    final needsMerge = commands.length > 1;
    final partPaths = commands
        .take(needsMerge ? commands.length - 1 : 0)
        .map((item) => item.outputPath)
        .toList();
    final intermediates = [...partPaths, if (needsMerge) listFilePath];

    var copySucceeded = true;
    _activePartCount = commands.length;
    _enableProgressReporting(onProgress, _partAwareProgress);
    try {
      if (needsMerge) await _writeConcatListFile(listFilePath, partPaths);
      for (var i = 0; i < commands.length; i++) {
        if (_cancelled) throw const MediaCutterCancelledException();
        _startPart(i, commands[i].durationSeconds);
        await _runSplitPart(commands[i], 'Fast remove step ${i + 1}');
        onProgress?.call((i + 1) / commands.length);
      }
    } on MediaCutterCancelledException {
      rethrow;
    } on Exception catch (e, stack) {
      AppLogger().e(
        'Media cutter fast remove failed; falling back to re-encode',
        e,
        stack,
      );
      copySucceeded = false;
    } finally {
      _disableProgressReporting(onProgress);
      _deleteQuietly(intermediates);
    }

    if (!copySucceeded) {
      return cut(
        inputPath: inputPath,
        outputPath: outputPath,
        startSeconds: removeStartSeconds,
        endSeconds: removeEndSeconds,
        totalDurationSeconds: totalDurationSeconds,
        mediaType: mediaType,
        mode: CutterMode.removeSelection,
        hasAudio: hasAudio,
        onProgress: onProgress,
      );
    }
    return outputPath;
  }

  /// Remove-selection export over multiple [ranges] in a single re-encoding
  /// pass ([buildMultiRemoveCommand]). Progress and cancellation work exactly
  /// like [cut]: raw processed time is mapped onto the whole media duration.
  Future<String?> cutMultiRemove({
    required String inputPath,
    required String outputPath,
    required List<RemoveRange> ranges,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool hasAudio = true,
    void Function(double progress)? onProgress,
  }) async {
    final command = buildMultiRemoveCommand(
      inputPath: inputPath,
      outputPath: outputPath,
      ranges: ranges,
      totalDurationSeconds: totalDurationSeconds,
      mediaType: mediaType,
      hasAudio: hasAudio,
    );

    AppLogger().i('Media cutter multi remove command: $command');
    final totalMs = (totalDurationSeconds <= 0 ? 1.0 : totalDurationSeconds * 1000)
        .clamp(1.0, double.infinity)
        .toDouble();
    _enableProgressReporting(
      onProgress,
      (timeMs) => (timeMs / totalMs).clamp(0.0, 1.0),
    );
    try {
      final session = await _run(command);
      if (_cancelled) throw const MediaCutterCancelledException();

      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) return outputPath;

      final logs = await session.getAllLogsAsString();
      AppLogger().e('Media cutter multi remove failed: $logs');
      return null;
    } finally {
      _disableProgressReporting(onProgress);
    }
  }

  /// Fast multi-range removal: copies every kept segment with
  /// [buildFastMultiRemoveCommands] and merges them via the concat demuxer,
  /// all without re-encoding. [listFilePath] (provided by the caller)
  /// receives the concat list file; it and the intermediate parts are deleted
  /// in a finally block on success, failure or cancellation. If any step
  /// fails, the reasons are logged and the export falls back to the
  /// re-encoding [cutMultiRemove] over the same ranges ([hasAudio] is only
  /// used by that fallback path). Progress is part-aware like
  /// [cutFastRemove], with the quick merge step jumping on completion.
  Future<String?> cutFastMultiRemove({
    required String inputPath,
    required String outputPath,
    required String listFilePath,
    required List<RemoveRange> ranges,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool hasAudio = true,
    void Function(double progress)? onProgress,
  }) async {
    final commands = buildFastMultiRemoveCommands(
      inputPath: inputPath,
      outputPath: outputPath,
      listFilePath: listFilePath,
      ranges: ranges,
      totalDurationSeconds: totalDurationSeconds,
      mediaType: mediaType,
    );
    final needsMerge = commands.length > 1;
    final partPaths = commands
        .take(needsMerge ? commands.length - 1 : 0)
        .map((item) => item.outputPath)
        .toList();
    final intermediates = [...partPaths, if (needsMerge) listFilePath];

    var copySucceeded = true;
    _activePartCount = commands.length;
    _enableProgressReporting(onProgress, _partAwareProgress);
    try {
      if (needsMerge) await _writeConcatListFile(listFilePath, partPaths);
      for (var i = 0; i < commands.length; i++) {
        if (_cancelled) throw const MediaCutterCancelledException();
        _startPart(i, commands[i].durationSeconds);
        await _runSplitPart(commands[i], 'Fast multi remove step ${i + 1}');
        onProgress?.call((i + 1) / commands.length);
      }
    } on MediaCutterCancelledException {
      rethrow;
    } on Exception catch (e, stack) {
      AppLogger().e(
        'Media cutter fast multi remove failed; falling back to re-encode',
        e,
        stack,
      );
      copySucceeded = false;
    } finally {
      _disableProgressReporting(onProgress);
      _deleteQuietly(intermediates);
    }

    if (!copySucceeded) {
      return cutMultiRemove(
        inputPath: inputPath,
        outputPath: outputPath,
        ranges: ranges,
        totalDurationSeconds: totalDurationSeconds,
        mediaType: mediaType,
        hasAudio: hasAudio,
        onProgress: onProgress,
      );
    }
    return outputPath;
  }

  /// Runs the short remove-selection preview built by
  /// [buildRemovePreviewCommand]. Only ~[windowSeconds] per side are encoded,
  /// so there is no progress reporting (see cut() for the full export).
  Future<String?> cutRemovePreview({
    required String inputPath,
    required String outputPath,
    required double removeStartSeconds,
    required double removeEndSeconds,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool hasAudio = true,
    double windowSeconds = 5,
  }) async {
    final command = buildRemovePreviewCommand(
      inputPath: inputPath,
      outputPath: outputPath,
      removeStartSeconds: removeStartSeconds,
      removeEndSeconds: removeEndSeconds,
      totalDurationSeconds: totalDurationSeconds,
      mediaType: mediaType,
      hasAudio: hasAudio,
      windowSeconds: windowSeconds,
    );

    AppLogger().i('Media cutter preview command: $command');
    final session = await _run(command);

    final rc = await session.getReturnCode();
    if (ReturnCode.isSuccess(rc)) return outputPath;

    final logs = await session.getAllLogsAsString();
    AppLogger().e('Media cutter preview failed: $logs');
    return null;
  }

  /// Runs the multi-range remove preview built by
  /// [buildMultiRemovePreviewCommand]. Only ~[windowSeconds] around every
  /// splice point are encoded, so there is no progress reporting (see
  /// [cutMultiRemove] for the full export).
  Future<String?> cutMultiRemovePreview({
    required String inputPath,
    required String outputPath,
    required List<RemoveRange> ranges,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool hasAudio = true,
    double windowSeconds = 5,
  }) async {
    final command = buildMultiRemovePreviewCommand(
      inputPath: inputPath,
      outputPath: outputPath,
      ranges: ranges,
      totalDurationSeconds: totalDurationSeconds,
      mediaType: mediaType,
      hasAudio: hasAudio,
      windowSeconds: windowSeconds,
    );

    AppLogger().i('Media cutter multi preview command: $command');
    final session = await _run(command);

    final rc = await session.getReturnCode();
    if (ReturnCode.isSuccess(rc)) return outputPath;

    final logs = await session.getAllLogsAsString();
    AppLogger().e('Media cutter multi preview failed: $logs');
    return null;
  }

  static List<MediaCutCommand> buildAudioSplitCommands({
    required String inputPath,
    required String outputDirectory,
    required String baseName,
    required double segmentSeconds,
    required double totalDurationSeconds,
  }) {
    if (segmentSeconds <= 0 || totalDurationSeconds <= 0) {
      throw ArgumentError(
        'segmentSeconds and totalDurationSeconds must be positive',
      );
    }

    final commands = <MediaCutCommand>[];
    var start = 0.0;
    var index = 1;

    while (start < totalDurationSeconds) {
      final duration = (totalDurationSeconds - start)
          .clamp(0.0, segmentSeconds)
          .toDouble();
      final outputPath =
          '${outputDirectory.replaceAll('\\', '/')}/${baseName}_part_${index.toString().padLeft(3, '0')}.m4a';
      final command =
          '-ss ${_fmt(start)} -i ${_q(inputPath)} -t ${_fmt(duration)} -vn '
          '-c:a aac -b:a 256k -y ${_q(outputPath)}';
      commands.add(
        MediaCutCommand(
          command: command,
          outputPath: outputPath,
          durationSeconds: duration,
        ),
      );
      start += segmentSeconds;
      index++;
    }

    return commands;
  }

  static List<MediaCutCommand> buildSplitAtCutsCommands({
    required String inputPath,
    required String outputDirectory,
    required String baseName,
    required List<double> cutPointsSeconds,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool streamCopy = false,
  }) {
    if (totalDurationSeconds <= 0) {
      throw ArgumentError('totalDurationSeconds must be positive');
    }

    final cuts =
        cutPointsSeconds
            .where((point) => point > 0 && point < totalDurationSeconds)
            .map((point) => double.parse(_fmt(point)))
            .toSet()
            .toList()
          ..sort();
    if (cuts.isEmpty) {
      throw ArgumentError('At least one cut point is required');
    }

    final ext = mediaType == CutterMediaType.audio ? 'm4a' : 'mp4';
    final commands = <MediaCutCommand>[];
    final points = <double>[0, ...cuts, totalDurationSeconds];
    for (var i = 0; i < points.length - 1; i++) {
      final start = points[i];
      final end = points[i + 1];
      final outputPath =
          '${outputDirectory.replaceAll('\\', '/')}/${baseName}_part_${(i + 1).toString().padLeft(3, '0')}.$ext';
      commands.add(
        MediaCutCommand(
          command: buildTrimCommand(
            inputPath: inputPath,
            outputPath: outputPath,
            startSeconds: start,
            endSeconds: end,
            mediaType: mediaType,
            streamCopy: streamCopy,
          ),
          outputPath: outputPath,
          durationSeconds: end - start,
        ),
      );
    }

    return commands;
  }

  Future<List<String>> splitAudio({
    required String inputPath,
    required String outputDirectory,
    required String baseName,
    required double segmentSeconds,
    required double totalDurationSeconds,
    void Function(double progress)? onProgress,
  }) async {
    final commands = buildAudioSplitCommands(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
      baseName: baseName,
      segmentSeconds: segmentSeconds,
      totalDurationSeconds: totalDurationSeconds,
    );
    final outputs = <String>[];

    _activePartCount = commands.length;
    _enableProgressReporting(onProgress, _partAwareProgress);
    try {
      for (var i = 0; i < commands.length; i++) {
        if (_cancelled) throw const MediaCutterCancelledException();
        _startPart(i, commands[i].durationSeconds);
        await _runSplitPart(commands[i], 'Audio split');
        outputs.add(commands[i].outputPath);
        onProgress?.call((i + 1) / commands.length);
      }
    } finally {
      _disableProgressReporting(onProgress);
    }

    return outputs;
  }

  Future<List<String>> splitAtCuts({
    required String inputPath,
    required String outputDirectory,
    required String baseName,
    required List<double> cutPointsSeconds,
    required double totalDurationSeconds,
    required CutterMediaType mediaType,
    bool streamCopy = false,
    void Function(double progress)? onProgress,
  }) async {
    final commands = buildSplitAtCutsCommands(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
      baseName: baseName,
      cutPointsSeconds: cutPointsSeconds,
      totalDurationSeconds: totalDurationSeconds,
      mediaType: mediaType,
      streamCopy: streamCopy,
    );
    final outputs = <String>[];

    var copySucceeded = true;
    _activePartCount = commands.length;
    _enableProgressReporting(onProgress, _partAwareProgress);
    try {
      for (var i = 0; i < commands.length; i++) {
        if (_cancelled) throw const MediaCutterCancelledException();
        _startPart(i, commands[i].durationSeconds);
        try {
          await _runSplitPart(commands[i], 'Split at cuts');
        } on MediaCutterCancelledException {
          rethrow;
        } on Exception catch (e, stack) {
          if (!streamCopy) rethrow;
          // Stream copy is best-effort: one incompatible part falls back to a
          // full re-encode run (same paths, parts are overwritten) instead of
          // failing the whole export.
          AppLogger().e(
            'Split at cuts stream copy failed; falling back to re-encode',
            e,
            stack,
          );
          copySucceeded = false;
          break;
        }
        outputs.add(commands[i].outputPath);
        onProgress?.call((i + 1) / commands.length);
      }
    } finally {
      _disableProgressReporting(onProgress);
    }

    if (!copySucceeded) {
      return splitAtCuts(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        baseName: baseName,
        cutPointsSeconds: cutPointsSeconds,
        totalDurationSeconds: totalDurationSeconds,
        mediaType: mediaType,
        streamCopy: false,
        onProgress: onProgress,
      );
    }

    return outputs;
  }

  /// Stops the running export immediately, if any. The pending await in the
  /// service resolves and the export methods throw
  /// [MediaCutterCancelledException].
  void cancel() {
    _cancelled = true;
    // Fire-and-forget: if the session already finished, the cancel request is
    // harmless and the _cancelled flag still reports the cancellation.
    _activeSession?.cancel().ignore();
  }

  /// Runs a command and resolves when it finishes. Stores the live session so
  /// [cancel] can stop the native process immediately instead of only
  /// noticing cancellation after encoding already completed.
  Future<FFmpegSession> _run(String command) async {
    _cancelled = false;
    final completer = Completer<void>();
    final session = await FFmpegKit.executeAsync(
      command,
      (s) {
        if (!completer.isCompleted) completer.complete();
      },
      (log) {},
    );
    _activeSession = session;
    if (_cancelled) session.cancel().ignore();
    await completer.future;
    _activeSession = null;
    return session;
  }

  void _startPart(int partIndex, double partDurationSeconds) {
    _activePartIndex = partIndex;
    _activePartDurationMs =
        (partDurationSeconds <= 0 ? 1.0 : partDurationSeconds * 1000)
            .toDouble();
  }

  /// Maps raw processed milliseconds of the active part onto the whole
  /// multi-part export: (completedParts + partProgress) / totalParts.
  double _partAwareProgress(double timeMs) {
    final partProgress = (timeMs / _activePartDurationMs).clamp(0.0, 1.0);
    return ((_activePartIndex + partProgress) / _activePartCount).clamp(
      0.0,
      1.0,
    );
  }

  Future<void> _runSplitPart(MediaCutCommand item, String label) async {
    AppLogger().i('$label command: ${item.command}');
    final session = await _run(item.command);
    if (_cancelled) throw const MediaCutterCancelledException();

    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      final logs = await session.getAllLogsAsString();
      AppLogger().e('$label failed: $logs');
      throw Exception('$label failed');
    }
  }

  /// Writes the concat demuxer list file: one `file '<path>'` line per part,
  /// forward-slashed and single-quoted as the demuxer expects.
  Future<void> _writeConcatListFile(
    String listFilePath,
    List<String> partPaths,
  ) async {
    final content = partPaths
        .map((path) => "file '${path.replaceAll('\\', '/')}'")
        .join('\n');
    final listFile = File(listFilePath);
    await listFile.parent.create(recursive: true);
    await listFile.writeAsString(content);
  }

  /// Deletes intermediate stream-copy artifacts (parts + concat list). Runs
  /// on success, failure and cancellation alike so only the final output
  /// ever survives.
  void _deleteQuietly(List<String> paths) {
    for (final path in paths) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (e) {
        AppLogger().e('Media cutter intermediate cleanup failed: $path', e);
      }
    }
  }

  /// Validates [ranges] (non-empty, each a proper range, no overlaps) and
  /// returns them sorted by start time. Kept in one place so every multi-range
  /// builder rejects the same inputs with the same messages.
  static List<RemoveRange> _validatedSortedRanges(List<RemoveRange> ranges) {
    if (ranges.isEmpty) {
      throw ArgumentError('At least one removal range is required');
    }
    for (final range in ranges) {
      _validateRange(range.start, range.end);
    }
    final sorted = [...ranges]..sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].start < sorted[i - 1].end) {
        throw ArgumentError('Removal ranges overlap');
      }
    }
    return sorted;
  }

  /// Complement of the removal ranges inside [0, totalDurationSeconds]:
  /// the kept (non-removed) segments as (start, end) pairs, sorted, with
  /// ~zero-length leftovers (sub-millisecond rounding debris) ignored.
  static List<(double, double)> _keptSegments(
    List<RemoveRange> ranges,
    double totalDurationSeconds,
  ) {
    if (totalDurationSeconds <= 0) {
      throw ArgumentError('totalDurationSeconds must be positive');
    }
    final sorted = _validatedSortedRanges(ranges);

    final kept = <(double, double)>[];
    var cursor = 0.0;
    for (final range in sorted) {
      final start = range.start.clamp(0.0, totalDurationSeconds).toDouble();
      final end = range.end.clamp(0.0, totalDurationSeconds).toDouble();
      if (start > cursor) kept.add((cursor, start));
      if (end > cursor) cursor = end;
    }
    if (cursor < totalDurationSeconds) {
      kept.add((cursor, totalDurationSeconds));
    }
    return kept.where((segment) => segment.$2 - segment.$1 >= 0.001).toList();
  }

  /// Shared body of [buildMultiRemoveCommand] and
  /// [buildMultiRemovePreviewCommand]: one filter_complex over [segments]
  /// (kept segments or preview windows) reusing the exact filter and encoding
  /// patterns of buildRemoveCommand, so a two-segment command is
  /// character-for-character identical to the single-range command.
  static String _buildMultiSegmentCommand({
    required String inputPath,
    required String outputPath,
    required List<(double, double)> segments,
    required CutterMediaType mediaType,
    required bool hasAudio,
  }) {
    final input = _q(inputPath);
    final output = _q(outputPath);
    final n = segments.length;

    if (mediaType == CutterMediaType.audio) {
      final filter = StringBuffer();
      final concatInputs = StringBuffer();
      for (var i = 0; i < n; i++) {
        final start = _fmt(segments[i].$1);
        final end = _fmt(segments[i].$2);
        filter.write('[0:a]atrim=start=$start:end=$end,'
            'asetpts=PTS-STARTPTS[a$i];');
        concatInputs.write('[a$i]');
      }
      filter.write('${concatInputs}concat=n=$n:v=0:a=1[outa]');
      return '-i $input -filter_complex "$filter" -map "[outa]" '
          '-c:a aac -b:a 256k -y $output';
    }

    if (!hasAudio) {
      final filter = StringBuffer();
      final concatInputs = StringBuffer();
      for (var i = 0; i < n; i++) {
        final start = _fmt(segments[i].$1);
        final end = _fmt(segments[i].$2);
        filter.write('[0:v]trim=start=$start:end=$end,'
            'setpts=PTS-STARTPTS[v$i];');
        concatInputs.write('[v$i]');
      }
      filter.write('${concatInputs}concat=n=$n:v=1:a=0[outv]');
      return '-i $input -filter_complex "$filter" '
          '-map "[outv]" '
          '-c:v libx264 -crf 18 -preset veryfast '
          '-movflags +faststart -y $output';
    }

    final filter = StringBuffer();
    final concatInputs = StringBuffer();
    for (var i = 0; i < n; i++) {
      final start = _fmt(segments[i].$1);
      final end = _fmt(segments[i].$2);
      filter.write('[0:v]trim=start=$start:end=$end,'
          'setpts=PTS-STARTPTS[v$i];');
      filter.write('[0:a]atrim=start=$start:end=$end,'
          'asetpts=PTS-STARTPTS[a$i];');
      concatInputs.write('[v$i][a$i]');
    }
    filter.write('${concatInputs}concat=n=$n:v=1:a=1[outv][outa]');
    return '-i $input -filter_complex "$filter" '
        '-map "[outv]" -map "[outa]" '
        '-c:v libx264 -crf 18 -preset veryfast '
        '-c:a aac -b:a 192k -movflags +faststart -y $output';
  }

  static void _validateRange(double start, double end) {
    if (start < 0 || end <= start) {
      throw ArgumentError('Invalid cut range: $start - $end');
    }
  }

  static String _q(String path) => '"${path.replaceAll('\\', '/')}"';

  static String _fmt(double seconds) => seconds.toStringAsFixed(3);
}
