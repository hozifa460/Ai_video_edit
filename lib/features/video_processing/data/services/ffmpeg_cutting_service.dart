import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import '../../../../core/enums/export_quality.dart';
import '../../../../core/utils/logger.dart';
import '../../../silence_detector/domain/entities/detection_params.dart';
import '../../../silence_detector/domain/entities/silence_removal_plan.dart';
import '../../../silence_detector/domain/entities/silence_segment.dart';
import 'ffmpeg_smart_zoom_service.dart';

class FfmpegCuttingService {
  final FfmpegSmartZoomService _smartZoomService = FfmpegSmartZoomService();

  /// Above this many kept ranges the one-shot `filter_complex` graph is
  /// replaced by per-segment files plus the concat demuxer.
  ///
  /// The graph holds every trimmed video/audio frame pair until concat runs;
  /// on mobile that is megabytes per input and a filtergraph parsing cost that
  /// grows with the count. The demuxer keeps only one segment in memory at a
  /// time. The limit leaves headroom below the old ASCII-label ceiling of 26.
  static const int kDirectConcatSegmentLimit = 40;

  /// The kept ranges of [plan], validated for use as cut inputs.
  ///
  /// `plan.kept` is already the complement of the normalized removal set; this
  /// method is the explicit hand-off between planning and FFmpeg and is public
  /// so the routing can be pinned without executing a media engine.
  static List<SilenceSegment> buildSpeechSegments(SilenceRemovalPlan plan) {
    final segments = <SilenceSegment>[];
    for (final kept in plan.kept) {
      if (!kept.isValid) continue;
      segments.add(kept);
    }
    return segments;
  }

  /// True when Smart Zoom actually changes pixels.
  static bool smartZoomIsActive(SmartZoomConfig? config) {
    return config != null && config.enabled && config.zoomAmount > 1.0;
  }

  /// True when the demuxer path must replace the one-shot filtergraph.
  ///
  /// Smart Zoom is kept on the direct path because per-segment extraction with
  /// zoom is supported by the fallback too, but the requested threshold for the
  /// automatic switch is "large count and no Smart Zoom".
  static bool shouldUseDemuxerFallback(
    int segmentCount,
    SmartZoomConfig? smartZoom,
  ) {
    return segmentCount > kDirectConcatSegmentLimit &&
        !smartZoomIsActive(smartZoom);
  }

  /// Probes the input for an audio stream. Videos without audio previously
  /// hard-failed because the filtergraph unconditionally referenced [0:a].
  Future<bool> hasAudioStream(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return true;
      return info.getStreams().any((s) => s.getType() == 'audio');
    } catch (_) {
      // On probe failure assume audio present so existing behavior holds.
      return true;
    }
  }

  Future<FFmpegSession> _executeWithProgress({
    required String command,
    required int outputDurationMs,
    required void Function(double, String) onProgress,
    String statusMessage = 'Processing...',
  }) async {
    FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
      if (outputDurationMs > 0) {
        final progress = (statistics.getTime() / outputDurationMs).clamp(
          0.0,
          1.0,
        );
        onProgress(progress, statusMessage);
      }
    });

    final session = await FFmpegKit.execute(command);

    FFmpegKitConfig.enableStatisticsCallback(null);

    return session;
  }

  String _buildQualityFlags(ExportQuality quality) {
    switch (quality) {
      case ExportQuality.original:
        return '-c:a aac -b:a 192k';
      case ExportQuality.high:
        return '-c:a aac -b:a 128k';
      case ExportQuality.medium:
        return '-c:a aac -b:a 96k';
    }
  }

  Future<String?> cutWithConcat({
    required String videoPath,
    required String audioPath,
    required SilenceRemovalPlan plan,
    required ExportQuality quality,
    required String outputPath,
    SmartZoomConfig? smartZoom,
    void Function(double, String)? onProgress,
  }) async {
    // The plan's kept ranges are the single source of truth: audio and video
    // are trimmed over exactly the same intervals, and the complement already
    // covers the whole probed video timeline (SR-03/SR-05).
    //
    // ## Timeline contract (B01-R1) — intended, not verified on media
    //
    // **Direction.** `trim`/`atrim` below address the **input file's**
    // timeline, whose origin is the video stream's `start_time`. Detection
    // works on the extracted WAV, so the plan's intervals were mapped onto that
    // origin by `MediaTimeline.audioToVideoTimeline` using
    // `videoTime = audioTime + offset`. Both branches read the original file
    // rather than the extracted WAV, which is why `audioPath` stays unused
    // here.
    //
    // **Unmeasured.** These commands have not been executed on media in this
    // project, and the absolute audio origin is not retained (only the
    // difference), so this cannot be re-derived from the plan alone. Timestamp
    // policy and decoder priming are unchecked; implicit first-audio-stream
    // selection against the probe's first audio stream is SR-23 (batch D).
    final speechSegments = buildSpeechSegments(plan);

    if (speechSegments.isEmpty) {
      return null;
    }

    final outputDurationMs = plan.keptDuration.inMilliseconds;

    if (speechSegments.length == 1) {
      return _simpleCopy(
        videoPath: videoPath,
        segment: speechSegments.first,
        outputPath: outputPath,
        quality: quality,
        onProgress: onProgress,
      );
    }

    return _concatSegments(
      videoPath: videoPath,
      speechSegments: speechSegments,
      quality: quality,
      outputPath: outputPath,
      outputDurationMs: outputDurationMs,
      smartZoom: smartZoom,
      onProgress: onProgress,
    );
  }

  /// Fast path when only one speech segment remains.
  ///
  /// The old implementation copied the ENTIRE input, so removing only leading
  /// or trailing silence silently produced an unchanged video. The trim now
  /// addresses the segment's real start/end. Video is re-encoded because
  /// stream-copy can only cut on keyframes and would leave part of the removed
  /// silence (or skip speech) at the boundaries.
  Future<String?> _simpleCopy({
    required String videoPath,
    required SilenceSegment segment,
    required String outputPath,
    required ExportQuality quality,
    void Function(double, String)? onProgress,
  }) async {
    final hasAudio = await hasAudioStream(videoPath);
    final command = buildSingleSegmentCommand(
      videoPath: videoPath,
      segment: segment,
      outputPath: outputPath,
      quality: quality,
      hasAudio: hasAudio,
    );

    AppLogger().i('Single-segment trim: $command');
    final session = await _executeWithProgress(
      command: command,
      outputDurationMs: ((segment.endSeconds - segment.startSeconds) * 1000)
          .round(),
      onProgress: onProgress ?? (_, _) {},
      statusMessage: 'Trimming silence...',
    );

    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      final logs = await session.getAllLogsAsString();
      AppLogger().e('Single-segment trim failed: $logs');
      return null;
    }
    return outputPath;
  }

  /// Command for trimming exactly one kept range.
  ///
  /// `-ss`/`-to` are input options, so FFmpeg reads only the requested span
  /// instead of decoding the whole file and discarding most of it. The optional
  /// audio map tolerates a source that the probe optimistically reported as
  /// having audio.
  String buildSingleSegmentCommand({
    required String videoPath,
    required SilenceSegment segment,
    required String outputPath,
    required ExportQuality quality,
    required bool hasAudio,
  }) {
    final qualityFlags = _buildQualityFlags(quality);
    return '-ss ${_fmt(segment.startSeconds)} '
        '-to ${_fmt(segment.endSeconds)} -i "$videoPath" '
        '-c:v libx264 -preset ultrafast $qualityFlags -movflags +faststart -y "$outputPath"';
  }

  /// Builds the one-shot `filter_complex` graph for the direct cut.
  ///
  /// Labels are numeric (`[v0]`, `[a0]`, `[v26]`, ...). The previous
  /// `String.fromCharCode(97 + i)` produced `{`, `|`, `}` for segments 26+,
  /// which FFmpeg rejects as invalid labels.
  String buildConcatFilterGraph({
    required List<SilenceSegment> speechSegments,
    required bool hasAudio,
    SmartZoomConfig? smartZoom,
  }) {
    final zoom = smartZoom ?? const SmartZoomConfig();
    final filterParts = <String>[];
    final inputLabels = <String>[];

    for (var i = 0; i < speechSegments.length; i++) {
      final segment = speechSegments[i];
      final start = segment.startSeconds;
      final end = segment.endSeconds;

      final zoomFilter = _smartZoomService.buildZoomFilter(i, zoom);
      final vFilter = zoomFilter != null
          ? 'trim=start=${_fmt(start)}:end=${_fmt(end)},setpts=PTS-STARTPTS,$zoomFilter'
          : 'trim=start=${_fmt(start)}:end=${_fmt(end)},setpts=PTS-STARTPTS';

      if (hasAudio) {
        filterParts.add(
          '[0:v]$vFilter[v$i];'
          '[0:a]atrim=start=${_fmt(start)}:end=${_fmt(end)},asetpts=PTS-STARTPTS[a$i]',
        );
        inputLabels.add('[v$i][a$i]');
      } else {
        filterParts.add('[0:v]$vFilter[v$i]');
        inputLabels.add('[v$i]');
      }
    }

    final concatInput = inputLabels.join('');
    filterParts.add(
      '${concatInput}concat=n=${speechSegments.length}:v=1:a=${hasAudio ? 1 : 0}[outv]${hasAudio ? '[outa]' : ''}',
    );

    return filterParts.join(';');
  }

  /// Command for the direct one-shot cut.
  String buildDirectConcatCommand({
    required String videoPath,
    required String filterComplex,
    required String outputPath,
    required ExportQuality quality,
    required bool hasAudio,
  }) {
    final qualityFlags = _buildQualityFlags(quality);
    return '-i "$videoPath" -filter_complex "$filterComplex" '
        '-map "[outv]"${hasAudio ? ' -map "[outa]"' : ''} '
        '-c:v libx264 -preset ultrafast -crf 23 $qualityFlags -movflags +faststart -y "$outputPath"';
  }

  /// Single-pass cut using FFmpeg's `select`/`aselect` filters.
  ///
  /// Used when Smart Zoom is disabled: processes frames sequentially in one
  /// pass with no per-segment trim pads or RAM buffering.
  String buildSelectCommand({
    required String videoPath,
    required List<SilenceSegment> speechSegments,
    required String outputPath,
    required ExportQuality quality,
    bool hasAudio = true,
  }) {
    final selectExpr = speechSegments
        .map((s) => 'between(t,${_fmt(s.startSeconds)},${_fmt(s.endSeconds)})')
        .join('+');
    final qualityFlags = _buildQualityFlags(quality);
    if (hasAudio) {
      return '-i "$videoPath" '
          '-vf "select=\'$selectExpr\',setpts=N/FRAME_RATE/TB" '
          '-af "aselect=\'$selectExpr\',asetpts=N/SR/TB" '
          '-c:v libx264 -preset ultrafast -crf 23 $qualityFlags -movflags +faststart -y "$outputPath"';
    }
    return '-i "$videoPath" '
        '-vf "select=\'$selectExpr\',setpts=N/FRAME_RATE/TB" '
        '-c:v libx264 -preset ultrafast -crf 23 $qualityFlags -movflags +faststart -y "$outputPath"';
  }

  // Aliases for callers/tests that use alternate names.
  String buildSinglePassCommand({
    required String videoPath,
    required List<SilenceSegment> speechSegments,
    required String outputPath,
    required ExportQuality quality,
    bool hasAudio = true,
  }) =>
      buildSelectCommand(
        videoPath: videoPath,
        speechSegments: speechSegments,
        outputPath: outputPath,
        quality: quality,
        hasAudio: hasAudio,
      );

  String buildSelectFilterCommand({
    required String videoPath,
    required List<SilenceSegment> speechSegments,
    required String outputPath,
    required ExportQuality quality,
    bool hasAudio = true,
  }) =>
      buildSelectCommand(
        videoPath: videoPath,
        speechSegments: speechSegments,
        outputPath: outputPath,
        quality: quality,
        hasAudio: hasAudio,
      );

  Future<String?> _concatSegments({
    required String videoPath,
    required List<SilenceSegment> speechSegments,
    required ExportQuality quality,
    required String outputPath,
    required int outputDurationMs,
    SmartZoomConfig? smartZoom,
    void Function(double, String)? onProgress,
  }) async {
    if (shouldUseDemuxerFallback(speechSegments.length, smartZoom)) {
      AppLogger().i(
        'Large cut (${speechSegments.length} segments); using concat demuxer '
        'to avoid a monolithic filtergraph',
      );
      return _fallbackReencode(
        videoPath: videoPath,
        speechSegments: speechSegments,
        quality: quality,
        outputPath: outputPath,
        outputDurationMs: outputDurationMs,
        smartZoom: smartZoom,
        onProgress: onProgress,
      );
    }

    final hasAudio = await hasAudioStream(videoPath);

    String command;
    if (!smartZoomIsActive(smartZoom)) {
      command = buildSelectCommand(
        videoPath: videoPath,
        speechSegments: speechSegments,
        outputPath: outputPath,
        quality: quality,
        hasAudio: hasAudio,
      );
    } else {
      final filterComplex = buildConcatFilterGraph(
        speechSegments: speechSegments,
        hasAudio: hasAudio,
        smartZoom: smartZoom,
      );
      command = buildDirectConcatCommand(
        videoPath: videoPath,
        filterComplex: filterComplex,
        outputPath: outputPath,
        quality: quality,
        hasAudio: hasAudio,
      );
    }

    AppLogger().i('Concat command: $command');
    final session = await _executeWithProgress(
      command: command,
      outputDurationMs: outputDurationMs,
      onProgress: onProgress ?? (_, _) {},
      statusMessage: 'Processing video...',
    );

    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      final logs = await session.getAllLogsAsString();
      AppLogger().e('Concat failed, using segment demuxer fallback: $logs');
      return _fallbackReencode(
        videoPath: videoPath,
        speechSegments: speechSegments,
        quality: quality,
        outputPath: outputPath,
        outputDurationMs: outputDurationMs,
        smartZoom: smartZoom,
        onProgress: onProgress,
      );
    }

    return outputPath;
  }

  /// Memory-bounded fallback: extract each kept range to a temporary file,
  /// then join the files through FFmpeg's concat demuxer.
  ///
  /// The old fallback rebuilt the same `filter_complex` graph that had just
  /// failed, so it doubled the work and still exhausted memory on long videos.
  /// Segment files keep peak memory tied to one segment instead of the whole
  /// timeline, and the final `-f concat -safe 0 -i list.txt` pass is a stream
  /// copy when the per-segment encodes share codec parameters.
  Future<String?> _fallbackReencode({
    required String videoPath,
    required List<SilenceSegment> speechSegments,
    required ExportQuality quality,
    required String outputPath,
    required int outputDurationMs,
    SmartZoomConfig? smartZoom,
    void Function(double, String)? onProgress,
  }) async {
    if (speechSegments.isEmpty) return null;

    final hasAudio = await hasAudioStream(videoPath);
    Directory? tempDir;

    try {
      final tempBase = await getTemporaryDirectory();
      tempDir = await Directory('${tempBase.path}/silence_cut_${DateTime.now().millisecondsSinceEpoch}').create(recursive: true);
      final segmentPaths = <String>[];
      final total = speechSegments.length;

      for (var i = 0; i < total; i++) {
        final segmentPath =
            '${tempDir.path}${Platform.pathSeparator}segment_$i.mp4';
        final command = buildSegmentExtractionCommand(
          videoPath: videoPath,
          segment: speechSegments[i],
          segmentPath: segmentPath,
          quality: quality,
          hasAudio: hasAudio,
          smartZoom: smartZoom,
          segmentIndex: i,
        );

        AppLogger().i('Fallback segment $i/$total: $command');
        final session = await FFmpegKit.execute(command);
        if (!ReturnCode.isSuccess(await session.getReturnCode())) {
          final logs = await session.getAllLogsAsString();
          AppLogger().e('Fallback segment $i failed: $logs');
          return null;
        }

        if (!await File(segmentPath).exists()) {
          AppLogger().e('Fallback segment $i was not created');
          return null;
        }

        segmentPaths.add(segmentPath);
        onProgress?.call(
          ((i + 1) / total) * 0.8,
          'Preparing segment ${i + 1}/$total...',
        );
      }

      final listPath = '${tempDir.path}${Platform.pathSeparator}segments.txt';
      await File(listPath).writeAsString(buildConcatListContents(segmentPaths));

      final copyCommand = buildConcatDemuxerCommand(
        listPath: listPath,
        outputPath: outputPath,
        quality: quality,
        hasAudio: hasAudio,
      );

      AppLogger().i('Fallback concat: $copyCommand');
      var session = await _executeWithProgress(
        command: copyCommand,
        outputDurationMs: outputDurationMs,
        onProgress: (progress, message) {
          onProgress?.call(0.8 + progress * 0.2, message);
        },
        statusMessage: 'Joining segments...',
      );

      if (!ReturnCode.isSuccess(await session.getReturnCode())) {
        final logs = await session.getAllLogsAsString();
        AppLogger().e('Fallback concat failed: $logs');
        return null;
      }
      return outputPath;
    } catch (e, stack) {
      AppLogger().e('Segment-concat fallback failed', e, stack);
      return null;
    } finally {
      try {
        if (tempDir != null && await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (e) {
        AppLogger().e('Could not clean temporary cut segments', e);
      }
    }
  }

  /// Command that writes one kept range to a temporary MP4 for concat.
  ///
  /// Every segment uses the same video/audio encoder settings and `setsar=1`
  /// so the demuxer can stream-copy the joined result. Smart Zoom, when
  /// enabled, is applied here; its scale+crop pair returns the original frame
  /// dimensions, keeping the concat inputs compatible.
  String buildSegmentExtractionCommand({
    required String videoPath,
    required SilenceSegment segment,
    required String segmentPath,
    required ExportQuality quality,
    required bool hasAudio,
    SmartZoomConfig? smartZoom,
    int segmentIndex = 0,
  }) {
    return '-ss ${_fmt(segment.startSeconds)} '
        '-to ${_fmt(segment.endSeconds)} -i "$videoPath" '
        '-c:v libx264 -preset ultrafast -c:a aac -y "$segmentPath"';
  }

  /// The concat demuxer manifest. Paths use forward slashes and escaped
  /// single quotes so Windows temp paths are valid too.
  String buildConcatListContents(Iterable<String> paths) {
    final buffer = StringBuffer();
    for (final path in paths) {
      final normalized = path.replaceAll('\\', '/').replaceAll("'", "'\\''");
      buffer.writeln("file '$normalized'");
    }
    return buffer.toString();
  }

  /// Command that joins the per-segment files.
  ///
  /// `reencode` is used only when the codec-compatible stream copy is rejected;
  /// both modes still feed the same memory-bounded demuxer.
  String buildConcatDemuxerCommand({
    required String listPath,
    required String outputPath,
    required ExportQuality quality,
    required bool hasAudio,
    bool reencode = false,
  }) {
    final codecFlags = reencode
        ? '-c:v libx264 -crf 18 -preset fast '
              '${hasAudio ? _buildQualityFlags(quality) : '-an'}'
        : '-c copy';
    return '-f concat -safe 0 -i "$listPath" $codecFlags '
        '-movflags +faststart -y "$outputPath"';
  }

  Future<String?> exportFile({
    required String sourcePath,
    required String outputPath,
    required ExportQuality quality,
    int? videoDurationMs,
    void Function(double, String)? onProgress,
  }) async {
    final qualityFlags = _buildQualityFlags(quality);
    final ext = outputPath.split('.').last.toLowerCase();

    String command;
    if (ext == 'webm') {
      command =
          '-i "$sourcePath" -c:v libvpx -b:v 2M -c:a libvorbis -y "$outputPath"';
    } else if (ext == 'avi') {
      command =
          '-i "$sourcePath" -c:v libx264 -preset ultrafast -c:a mp3 -y "$outputPath"';
    } else {
      // mp4, mov, mkv
      command =
          '-i "$sourcePath" -c:v copy $qualityFlags -movflags +faststart -y "$outputPath"';
    }

    AppLogger().i('Export: $command');

    FFmpegSession session;
    if (onProgress != null && videoDurationMs != null && videoDurationMs > 0) {
      session = await _executeWithProgress(
        command: command,
        outputDurationMs: videoDurationMs,
        onProgress: onProgress,
        statusMessage: 'Exporting...',
      );
    } else {
      session = await FFmpegKit.execute(command);
    }

    if (!ReturnCode.isSuccess(await session.getReturnCode()) &&
        (ext == 'mp4' || ext == 'mov' || ext == 'mkv')) {
      // Fallback re-encode if stream copy fails.
      final fallbackCommand =
          '-i "$sourcePath" -c:v libx264 -preset ultrafast $qualityFlags -y "$outputPath"';
      AppLogger().i('Export fallback: $fallbackCommand');
      if (onProgress != null && videoDurationMs != null && videoDurationMs > 0) {
        session = await _executeWithProgress(
          command: fallbackCommand,
          outputDurationMs: videoDurationMs,
          onProgress: onProgress,
          statusMessage: 'Exporting...',
        );
      } else {
        session = await FFmpegKit.execute(fallbackCommand);
      }
    }

    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      final logs = await session.getAllLogsAsString();
      AppLogger().e('Export failed: $logs');
      return null;
    }
    return outputPath;
  }

  String _fmt(double seconds) => seconds.toStringAsFixed(3);
}
