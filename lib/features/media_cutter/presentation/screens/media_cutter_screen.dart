import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/utils/media_scanner.dart';
import '../../../../core/utils/result.dart';
import '../../../../core/services/video_download_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/logger.dart';
import '../../../audio_processing/data/repositories/audio_processor_repository_impl.dart';
import '../../../audio_processing/domain/entities/waveform_data.dart';
import '../../data/services/ffmpeg_media_cutter_service.dart';

class MediaCutterScreen extends StatefulWidget {
  final String mediaPath;
  final bool isAudio;
  final bool hasAudio;
  final Duration? duration;

  const MediaCutterScreen({
    super.key,
    required this.mediaPath,
    required this.isAudio,
    this.hasAudio = true,
    this.duration,
  });

  @override
  State<MediaCutterScreen> createState() => _MediaCutterScreenState();
}

class _MediaCutterScreenState extends State<MediaCutterScreen> {
  final FfmpegMediaCutterService _service = FfmpegMediaCutterService();
  final AudioProcessorRepositoryImpl _audioRepository =
      AudioProcessorRepositoryImpl();
  VideoPlayerController? _controller;
  VideoPlayerController? _previewController;
  CutterMode _mode = CutterMode.keepSelection;
  double _durationSeconds = 1;
  double _startSeconds = 0;
  double _endSeconds = 1;
  final List<double> _cutPoints = [];
  final List<RemoveRange> _removeRanges = [];
  WaveformData? _waveform;
  String? _extractedWaveformAudioPath;
  bool _isLoading = true;
  bool _isWaveformLoading = true;
  bool _isExporting = false;
  bool _isPreviewing = false;
  String? _previewPath;
  bool _actualHasAudio = true;
  bool _isFastCopyCompatible = false;

  /// Optional fast export (stream copy, no re-encode). Off by default so the
  /// precise re-encoding behavior stays the default.
  bool _fastExport = false;
  final ValueNotifier<double> _exportProgress = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _actualHasAudio = widget.hasAudio;
    _init();
  }

  @override
  void dispose() {
    if (_isExporting) _service.cancel();
    _controller?.removeListener(_stopAtSelectionEnd);
    _controller?.dispose();
    _previewController?.dispose();
    if (_previewPath != null) File(_previewPath!).delete().ignore();
    if (_extractedWaveformAudioPath != null) {
      File(_extractedWaveformAudioPath!).delete().ignore();
    }
    _removeRanges.clear();
    _exportProgress.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final provided = widget.duration;
      if (provided != null && provided.inMilliseconds > 0) {
        _durationSeconds = provided.inMilliseconds / 1000;
      }

      // Single probe serves both the duration fallback and audio-track
      // detection so exports don't assume a stream that isn't there.
      final probe = await FFprobeKit.getMediaInformation(widget.mediaPath);
      final info = probe.getMediaInformation();
      if (provided == null || provided.inMilliseconds <= 0) {
        final dur = info?.getDuration();
        _durationSeconds = double.tryParse(dur ?? '') ?? 1;
      }

      final streams = info?.getStreams() ?? const [];
      final detectedAudio = streams.any(
        (stream) => stream.getType() == 'audio',
      );
      // The same probe also feeds the fast-export compatibility check:
      // StreamInformation.getCodec() returns ffprobe's `codec_name`
      // (getter confirmed in the ffmpeg_kit_flutter_new 4.1.0 sources).
      String? videoCodec;
      String? audioCodec;
      for (final stream in streams) {
        final type = stream.getType();
        if (type == 'video') videoCodec ??= stream.getCodec();
        if (type == 'audio') audioCodec ??= stream.getCodec();
      }
      final fastCopyCompatible = FfmpegMediaCutterService
          .isFastCopyCompatible(videoCodec: videoCodec, audioCodec: audioCodec);
      if (mounted) {
        setState(() {
          _actualHasAudio = detectedAudio;
          _isFastCopyCompatible = fastCopyCompatible;
        });
      }

      _endSeconds = _durationSeconds.clamp(1.0, double.infinity).toDouble();

      if (VideoDownloadService.isUrl(widget.mediaPath)) {
        _controller = VideoPlayerController.networkUrl(
          Uri.parse(widget.mediaPath),
        );
      } else {
        _controller = VideoPlayerController.file(File(widget.mediaPath));
      }
      await _controller!.initialize();
      _controller!.addListener(_stopAtSelectionEnd);
      _loadWaveform();
    } catch (e, stack) {
      AppLogger().e('Media cutter init failed', e, stack);
      if (mounted) setState(() => _isWaveformLoading = false);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadWaveform() async {
    if (VideoDownloadService.isUrl(widget.mediaPath)) {
      if (mounted) setState(() => _isWaveformLoading = false);
      return;
    }

    try {
      final audioPath = widget.isAudio
          ? widget.mediaPath
          : await _extractWaveformAudio();
      if (audioPath == null) {
        if (mounted) setState(() => _isWaveformLoading = false);
        return;
      }

      final result = await _audioRepository.analyzeWaveform(audioPath);
      if (!mounted) return;
      switch (result) {
        case Success<WaveformData>(value: final data):
          setState(() {
            _waveform = data;
            _isWaveformLoading = false;
          });
        case AppError<WaveformData>(error: final error):
          AppLogger().e('Media cutter waveform failed: $error');
          setState(() => _isWaveformLoading = false);
      }
    } catch (e, stack) {
      AppLogger().e('Media cutter waveform error', e, stack);
      if (mounted) setState(() => _isWaveformLoading = false);
    }
  }

  Future<String?> _extractWaveformAudio() async {
    final result = await _audioRepository.extractAudio(widget.mediaPath);
    switch (result) {
      case Success<String>(value: final path):
        _extractedWaveformAudioPath = path;
        return path;
      case AppError<String>(error: final error):
        AppLogger().e('Media cutter audio extraction failed: $error');
        return null;
    }
  }

  void _stopAtSelectionEnd() {
    final controller = _controller;
    if (controller == null || !controller.value.isPlaying) return;
    if (controller.value.position.inMilliseconds / 1000 >= _endSeconds) {
      controller.pause();
    }
  }

  Future<void> _previewSelection() async {
    if (_isPreviewing || _isExporting) return;
    if (VideoDownloadService.isUrl(widget.mediaPath)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Preview requires a local file. Import or download the media first.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    setState(() => _isPreviewing = true);

    try {
      final tempDir = await getTemporaryDirectory();
      final ext = widget.isAudio ? 'm4a' : 'mp4';
      final path =
          '${tempDir.path}/media_cutter_preview_${DateTime.now().millisecondsSinceEpoch}.$ext';
      // Remove-selection preview only encodes the short windows around the
      // splice points instead of re-encoding the whole file.
      final result = _mode == CutterMode.removeSelection
          ? (_removeRanges.isEmpty
                ? await _service.cutRemovePreview(
                    inputPath: widget.mediaPath,
                    outputPath: path,
                    removeStartSeconds: _startSeconds,
                    removeEndSeconds: _endSeconds,
                    totalDurationSeconds: _durationSeconds,
                    mediaType: widget.isAudio
                        ? CutterMediaType.audio
                        : CutterMediaType.video,
                    hasAudio: _actualHasAudio,
                  )
                : await _service.cutMultiRemovePreview(
                    inputPath: widget.mediaPath,
                    outputPath: path,
                    ranges: _removeRanges,
                    totalDurationSeconds: _durationSeconds,
                    mediaType: widget.isAudio
                        ? CutterMediaType.audio
                        : CutterMediaType.video,
                    hasAudio: _actualHasAudio,
                  ))
          : await _service.cut(
              inputPath: widget.mediaPath,
              outputPath: path,
              startSeconds: _mode == CutterMode.splitAudio ? 0 : _startSeconds,
              endSeconds: _mode == CutterMode.splitAudio
                  ? _firstSplitPreviewEnd()
                  : _endSeconds,
              totalDurationSeconds: _durationSeconds,
              mediaType: widget.isAudio
                  ? CutterMediaType.audio
                  : CutterMediaType.video,
              mode: _mode == CutterMode.splitAudio ? CutterMode.keepSelection : _mode,
              hasAudio: _actualHasAudio,
            );

      if (result == null || !File(result).existsSync()) {
        throw Exception('Preview file was not created');
      }
      await _ensurePlayableCutPreview(result);

      final ctrl = VideoPlayerController.file(File(result));
      await ctrl.initialize();
      await _previewController?.dispose();
      if (_previewPath != null) File(_previewPath!).delete().ignore();
      _previewController = ctrl;
      _previewPath = result;
      await ctrl.play();

      if (!mounted) return;
      _showGeneratedPreviewDialog();
    } catch (e, stack) {
      AppLogger().e('Media cutter preview failed', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Preview failed: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPreviewing = false);
    }
  }

  /// Fast export is offered for video files only: audio re-encodes are cheap,
  /// and stream-copying audio containers is far more likely to hit player
  /// quirks. It also requires the probed codecs to be stream-copy friendly.
  /// Split mode keeps the toggle too — long-video splitting benefits the most,
  /// and every fast path falls back to re-encoding automatically.
  bool get _canUseFastExport => !widget.isAudio && _isFastCopyCompatible;

  Future<void> _exportCut() async {
    if (_isExporting) return;
    if (VideoDownloadService.isUrl(widget.mediaPath)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cutting requires a local file. Import or download the media first.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    setState(() => _isExporting = true);
    _showExportDialog();

    String? singleOutputPath;
    Directory? splitOutputDir;

    try {
      final dir = await FileUtils.getExportDirectory();
      final baseName = widget.mediaPath
          .split('/')
          .last
          .split('\\')
          .last
          .replaceAll(RegExp(r'\.[^.]+$'), '');
      final suffix = _mode == CutterMode.keepSelection ? 'trimmed' : 'cut';
      final ext = widget.isAudio ? 'm4a' : 'mp4';
      // Read defensively so a stale toggle can never enable stream copy for
      // audio files or incompatible codecs.
      final fast = _fastExport && _canUseFastExport;

      if (_mode == CutterMode.splitAudio) {
        if (_cutPoints.isEmpty) {
          if (mounted) Navigator.of(context).pop();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Add at least one cut point before exporting.'),
                backgroundColor: AppColors.error,
              ),
            );
          }
          return;
        }

        final splitDir = Directory(
          '${dir.path}/${baseName}_parts_${DateTime.now().millisecondsSinceEpoch}',
        );
        await splitDir.create(recursive: true);
        splitOutputDir = splitDir;
        final outputs = await _service.splitAtCuts(
          inputPath: widget.mediaPath,
          outputDirectory: splitDir.path,
          baseName: baseName,
          cutPointsSeconds: _cutPoints,
          totalDurationSeconds: _durationSeconds,
          mediaType: widget.isAudio
              ? CutterMediaType.audio
              : CutterMediaType.video,
          streamCopy: fast,
          onProgress: _updateExportProgress,
        );

        for (final output in outputs) {
          await MediaScanner.scanFile(output);
        }

        if (mounted) Navigator.of(context).pop();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved ${outputs.length} parts'),
              backgroundColor: AppColors.success,
            ),
          );
        }
        return;
      }

      final outputPath =
          '${dir.path}/${baseName}_${suffix}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      singleOutputPath = outputPath;

      final String? result;
      if (fast && _mode == CutterMode.keepSelection) {
        result = await _service.cutFast(
          inputPath: widget.mediaPath,
          outputPath: outputPath,
          startSeconds: _startSeconds,
          endSeconds: _endSeconds,
          totalDurationSeconds: _durationSeconds,
          mediaType: widget.isAudio
              ? CutterMediaType.audio
              : CutterMediaType.video,
          onProgress: _updateExportProgress,
        );
      } else if (fast &&
          _mode == CutterMode.removeSelection &&
          _removeRanges.isNotEmpty) {
        // The concat list lives in the temp dir; the service cleans it up
        // together with the intermediate parts once the export settles.
        final listFile = File(
          '${(await getTemporaryDirectory()).path}/media_cutter_concat_${DateTime.now().millisecondsSinceEpoch}.txt',
        );
        result = await _service.cutFastMultiRemove(
          inputPath: widget.mediaPath,
          outputPath: outputPath,
          listFilePath: listFile.path,
          ranges: _removeRanges,
          totalDurationSeconds: _durationSeconds,
          mediaType: widget.isAudio
              ? CutterMediaType.audio
              : CutterMediaType.video,
          hasAudio: _actualHasAudio,
          onProgress: _updateExportProgress,
        );
      } else if (fast) {
        // The concat list lives in the temp dir; the service cleans it up
        // together with the intermediate parts once the export settles.
        final listFile = File(
          '${(await getTemporaryDirectory()).path}/media_cutter_concat_${DateTime.now().millisecondsSinceEpoch}.txt',
        );
        result = await _service.cutFastRemove(
          inputPath: widget.mediaPath,
          outputPath: outputPath,
          listFilePath: listFile.path,
          removeStartSeconds: _startSeconds,
          removeEndSeconds: _endSeconds,
          totalDurationSeconds: _durationSeconds,
          mediaType: widget.isAudio
              ? CutterMediaType.audio
              : CutterMediaType.video,
          hasAudio: _actualHasAudio,
          onProgress: _updateExportProgress,
        );
      } else if (_mode == CutterMode.removeSelection &&
          _removeRanges.isNotEmpty) {
        result = await _service.cutMultiRemove(
          inputPath: widget.mediaPath,
          outputPath: outputPath,
          ranges: _removeRanges,
          totalDurationSeconds: _durationSeconds,
          mediaType: widget.isAudio
              ? CutterMediaType.audio
              : CutterMediaType.video,
          hasAudio: _actualHasAudio,
          onProgress: _updateExportProgress,
        );
      } else {
        result = await _service.cut(
          inputPath: widget.mediaPath,
          outputPath: outputPath,
          startSeconds: _startSeconds,
          endSeconds: _endSeconds,
          totalDurationSeconds: _durationSeconds,
          mediaType: widget.isAudio
              ? CutterMediaType.audio
              : CutterMediaType.video,
          mode: _mode,
          hasAudio: _actualHasAudio,
          onProgress: _updateExportProgress,
        );
      }

      if (result != null) await MediaScanner.scanFile(result);

      if (mounted) Navigator.of(context).pop();

      if (result != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved: ${result.split('/').last.split('\\').last}'),
            backgroundColor: AppColors.success,
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cut failed. Check logs for FFmpeg details.'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } on MediaCutterCancelledException {
      _deletePartialExport(singleOutputPath, splitOutputDir);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Export cancelled'),
            backgroundColor: AppColors.warning,
          ),
        );
      }
    } catch (e, stack) {
      AppLogger().e('Media cutter export failed', e, stack);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cut failed: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  void _updateExportProgress(double progress) {
    _exportProgress.value = progress.clamp(0.0, 1.0);
  }

  void _cancelExport() {
    AppLogger().i('Media cutter export cancelled by user');
    _service.cancel();
  }

  /// Deletes the unfinished output of a cancelled export, if any was written.
  void _deletePartialExport(String? singleOutputPath, Directory? splitDir) {
    try {
      if (singleOutputPath != null) {
        final file = File(singleOutputPath);
        if (file.existsSync()) file.delete().ignore();
      } else if (splitDir != null && splitDir.existsSync()) {
        splitDir.deleteSync(recursive: true);
      }
    } catch (e) {
      AppLogger().e('Media cutter partial export cleanup failed', e);
    }
  }

  /// Status line for the export progress dialog: multi-range removals
  /// announce their section count, every other path keeps its classic text.
  String _exportStatusLabel() {
    final removingSections =
        _mode == CutterMode.removeSelection && _removeRanges.isNotEmpty;
    return widget.isAudio
        ? (_mode == CutterMode.splitAudio
              ? 'Splitting audio into cuts...'
              : removingSections
                    ? 'Removing ${_removeRanges.length} sections...'
                    : 'Cutting audio...')
        : (_mode == CutterMode.splitAudio
              ? 'Splitting video and audio...'
              : removingSections
                    ? 'Removing ${_removeRanges.length} sections...'
                    : 'Cutting video and audio...');
  }

  void _showExportDialog() {
    _exportProgress.value = 0;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          content: ValueListenableBuilder<double>(
            valueListenable: _exportProgress,
            builder: (context, progress, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _exportStatusLabel(),
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  backgroundColor: AppColors.surfaceLighter,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppColors.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${(progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _cancelExport,
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _ensurePlayableCutPreview(String path) async {
    final probe = await FFprobeKit.getMediaInformation(path);
    final info = probe.getMediaInformation();
    final duration = double.tryParse(info?.getDuration() ?? '') ?? 0;
    final streams = info?.getStreams() ?? const [];
    final requiredType = widget.isAudio ? 'audio' : 'video';
    final hasRequiredStream = streams.any(
      (stream) => stream.getType() == requiredType,
    );
    if (!hasRequiredStream || duration <= 0.05) {
      final logs = await probe.getAllLogsAsString() ?? '';
      AppLogger().e('Media cutter preview is not playable. Logs: $logs');
      throw Exception('Preview has no playable $requiredType stream');
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isAudio ? 'Audio Cutter' : 'Video + Audio Cutter';
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(title), backgroundColor: AppColors.surface),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildPreview(),
                  const SizedBox(height: 16),
                  _buildModeSelector(),
                  const SizedBox(height: 16),
                  _buildRangeEditor(),
                  const SizedBox(height: 20),
                  _buildActions(),
                ],
              ),
            ),
    );
  }

  Widget _buildPreview() {
    final controller = _controller;
    final initialized = controller != null && controller.value.isInitialized;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: widget.isAudio
                ? 16 / 5
                : (initialized ? controller.value.aspectRatio : 16 / 9),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: initialized && !widget.isAudio
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: VideoPlayer(controller),
                    )
                  : const Center(
                      child: Icon(
                        Icons.graphic_eq,
                        color: AppColors.primary,
                        size: 44,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            widget.mediaPath.split('/').last.split('\\').last,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (initialized) ...[
            const SizedBox(height: 10),
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final seconds = value.position.inMilliseconds / 1000;
                return Row(
                  children: [
                    IconButton(
                      onPressed: () async {
                        if (value.isPlaying) {
                          await controller.pause();
                        } else {
                          if (seconds < _startSeconds ||
                              seconds >= _endSeconds) {
                            await _seekTo(_startSeconds);
                          }
                          await controller.play();
                        }
                      },
                      icon: Icon(
                        value.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Expanded(
                      child: LinearProgressIndicator(
                        value:
                            (_durationSeconds > 0
                                    ? seconds / _durationSeconds
                                    : 0.0)
                                .clamp(0.0, 1.0),
                        backgroundColor: AppColors.surfaceLighter,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _fmtDuration(seconds),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _modeButton(
                label: 'Keep selection',
                icon: Icons.content_cut,
                selected: _mode == CutterMode.keepSelection,
                onTap: () => setState(() => _mode = CutterMode.keepSelection),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _modeButton(
                label: 'Remove selection',
                icon: Icons.do_not_disturb_on,
                selected: _mode == CutterMode.removeSelection,
                onTap: () => setState(() => _mode = CutterMode.removeSelection),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _modeButton(
          label: 'Split at cut points',
          icon: Icons.call_split,
          selected: _mode == CutterMode.splitAudio,
          onTap: () => setState(() => _mode = CutterMode.splitAudio),
        ),
      ],
    );
  }

  Widget _modeButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.1)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.cardBorder,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 17,
              color: selected ? AppColors.primary : AppColors.textTertiary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRangeEditor() {
    final max = _durationSeconds <= 0 ? 1.0 : _durationSeconds;
    if (_mode == CutterMode.splitAudio) {
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: _timeBox('Playhead', _currentSeconds())),
                const SizedBox(width: 10),
                Expanded(child: _valueBox('Parts', '${_cutPoints.length + 1}')),
              ],
            ),
            const SizedBox(height: 12),
            _playheadBuilder(
              (playhead) => _WaveformSplitEditor(
                waveform: _waveform,
                isLoading: _isWaveformLoading,
                cutPointsSeconds: _cutPoints,
                durationSeconds: max,
                playheadSeconds: playhead,
                onSeek: (seconds) async {
                  await _seekTo(seconds);
                  if (mounted) setState(() {});
                },
              ),
            ),
            const SizedBox(height: 12),
            _buildCutPointActions(),
            if (_cutPoints.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildCutPointList(),
            ],
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _timeBox('Start', _startSeconds)),
              const SizedBox(width: 10),
              Expanded(child: _timeBox('End', _endSeconds)),
              const SizedBox(width: 10),
              Expanded(child: _timeBox('Length', _endSeconds - _startSeconds)),
            ],
          ),
          const SizedBox(height: 12),
          _playheadBuilder(
            (playhead) => _WaveformRangeEditor(
              waveform: _waveform,
              isLoading: _isWaveformLoading,
              startSeconds: _startSeconds,
              endSeconds: _endSeconds,
              durationSeconds: max,
              playheadSeconds: playhead,
              onChanged: _setSelection,
              onSeek: _seekTo,
            ),
          ),
          const SizedBox(height: 12),
          _buildFineTrimControls(),
          if (_mode == CutterMode.removeSelection) ...[
            const SizedBox(height: 12),
            _buildRemoveRangeActions(),
            if (_removeRanges.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildRemoveRangeList(),
            ],
          ],
        ],
      ),
    );
  }

  void _setSelection(double start, double end) {
    final max = _durationSeconds <= 0 ? 1.0 : _durationSeconds;
    final safeStart = start.clamp(0.0, max - 0.05).toDouble();
    final safeEnd = end.clamp(safeStart + 0.05, max).toDouble();
    setState(() {
      _startSeconds = safeStart;
      _endSeconds = safeEnd;
    });
  }

  void _nudgeStart(double delta) {
    _setSelection(_startSeconds + delta, _endSeconds);
  }

  void _nudgeEnd(double delta) {
    _setSelection(_startSeconds, _endSeconds + delta);
  }

  Future<void> _seekTo(double seconds) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.seekTo(Duration(milliseconds: (seconds * 1000).round()));
  }

  /// Rebuilds [builder]'s subtree on every player position tick so the
  /// waveform playhead tracks playback without rebuilding the whole screen.
  Widget _playheadBuilder(Widget Function(double playheadSeconds) builder) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return builder(_currentSeconds());
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) =>
          builder(value.position.inMilliseconds / 1000),
    );
  }

  double _currentSeconds() {
    return (_controller?.value.position.inMilliseconds ?? 0) / 1000;
  }

  double _firstSplitPreviewEnd() {
    if (_cutPoints.isEmpty) return _durationSeconds.clamp(0.1, 12).toDouble();
    return _cutPoints.first.clamp(0.1, _durationSeconds).toDouble();
  }

  void _addCutPoint() {
    final point = _currentSeconds();
    if (point <= 0.05 || point >= _durationSeconds - 0.05) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Move the playhead inside the file before adding a cut.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    if (_cutPoints.any((existing) => (existing - point).abs() < 0.05)) {
      return;
    }
    setState(() {
      _cutPoints.add(double.parse(point.toStringAsFixed(3)));
      _cutPoints.sort();
    });
    AppLogger().i('Added media cut point: ${point.toStringAsFixed(3)}s');
  }

  void _removeCutPoint(double point) {
    setState(() => _cutPoints.remove(point));
    AppLogger().i('Removed media cut point: ${point.toStringAsFixed(3)}s');
  }

  Widget _buildCutPointActions() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _addCutPoint,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add cut here'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCutPointList() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _cutPoints
          .map(
            (point) => InputChip(
              label: Text(_fmtDuration(point)),
              onDeleted: () => _removeCutPoint(point),
              deleteIconColor: AppColors.textPrimary,
              backgroundColor: AppColors.background,
              labelStyle: const TextStyle(color: AppColors.textPrimary),
              side: const BorderSide(color: AppColors.cardBorder),
            ),
          )
          .toList(),
    );
  }

  /// Queues the current [start, end] selection as another section to delete
  /// in remove-selection mode. Reuses the cut-point discipline: 0.05s minimum
  /// length and no two ranges closer than 0.05s to each other.
  void _addRemoveRange() {
    const tolerance = 0.05;
    if (_endSeconds - _startSeconds < tolerance) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a range of at least 0.05 seconds first.'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    if (_startSeconds <= tolerance &&
        _endSeconds >= _durationSeconds - tolerance) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot remove the entire media file.'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    final overlaps = _removeRanges.any(
      (range) =>
          _startSeconds < range.end + tolerance &&
          range.start < _endSeconds + tolerance,
    );
    if (overlaps) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This range overlaps an existing removal range.'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    setState(() {
      _removeRanges.add(
        RemoveRange(
          start: double.parse(_startSeconds.toStringAsFixed(3)),
          end: double.parse(_endSeconds.toStringAsFixed(3)),
        ),
      );
      _removeRanges.sort((a, b) => a.start.compareTo(b.start));
    });
    AppLogger().i(
      'Added removal range: ${_startSeconds.toStringAsFixed(3)}s - '
      '${_endSeconds.toStringAsFixed(3)}s',
    );
  }

  void _removeRemoveRange(RemoveRange range) {
    setState(() => _removeRanges.remove(range));
    AppLogger().i(
      'Removed removal range: ${range.start.toStringAsFixed(3)}s - '
      '${range.end.toStringAsFixed(3)}s',
    );
  }

  Widget _buildRemoveRangeActions() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _addRemoveRange,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add range'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRemoveRangeList() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _removeRanges
          .map(
            (range) => InputChip(
              label: Text(
                '${_fmtDuration(range.start)} - ${_fmtDuration(range.end)}',
              ),
              onDeleted: () => _removeRemoveRange(range),
              deleteIconColor: AppColors.textPrimary,
              backgroundColor: AppColors.background,
              labelStyle: const TextStyle(color: AppColors.textPrimary),
              side: const BorderSide(color: AppColors.cardBorder),
            ),
          )
          .toList(),
    );
  }

  Widget _buildFineTrimControls() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _nudgeGroup(
                label: 'Start trim',
                onBack: () => _nudgeStart(-0.1),
                onForward: () => _nudgeStart(0.1),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _nudgeGroup(
                label: 'End trim',
                onBack: () => _nudgeEnd(-0.1),
                onForward: () => _nudgeEnd(0.1),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _nudgeGroup({
    required String label,
    required VoidCallback onBack,
    required VoidCallback onForward,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _tinyIconButton(Icons.remove, onBack),
          const SizedBox(width: 4),
          _tinyIconButton(Icons.add, onForward),
        ],
      ),
    );
  }

  Widget _tinyIconButton(IconData icon, VoidCallback onPressed) {
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        icon: Icon(icon, size: 16, color: AppColors.textPrimary),
      ),
    );
  }

  Widget _timeBox(String label, double seconds) {
    return _valueBox(label, _fmtDuration(seconds));
  }

  Widget _valueBox(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(color: AppColors.textTertiary, fontSize: 10),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 380;
        final preview = OutlinedButton.icon(
          onPressed: _isPreviewing ? null : _previewSelection,
          icon: _isPreviewing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow, size: 18),
          label: Text(_isPreviewing ? 'Preparing...' : 'Preview'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textPrimary,
            side: const BorderSide(color: AppColors.cardBorder),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        );
        final export = ElevatedButton.icon(
          onPressed: _isExporting ? null : _exportCut,
          icon: _isExporting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_alt, size: 18),
          label: Text(
            _isExporting
                ? 'Exporting...'
                : (_mode == CutterMode.splitAudio
                      ? 'Export ${_cutPoints.length + 1} Parts'
                      : (_mode == CutterMode.removeSelection &&
                                _removeRanges.isNotEmpty
                            ? 'Remove ${_removeRanges.length} section(s)'
                            : 'Export Cut')),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        );

        final buttons = compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [preview, const SizedBox(height: 10), export],
              )
            : Row(
                children: [
                  Expanded(child: preview),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: export),
                ],
              );

        if (!_canUseFastExport) return buttons;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildFastExportToggle(),
            const SizedBox(height: 12),
            buttons,
          ],
        );
      },
    );
  }

  Widget _buildFastExportToggle() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: SwitchListTile(
        value: _fastExport,
        onChanged: _isExporting
            ? null
            : (value) => setState(() => _fastExport = value),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: const Text(
          'Fast export (no re-encode)',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: const Text(
          'Keyframe-aligned, much faster, slightly imprecise',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
        ),
      ),
    );
  }

  void _showGeneratedPreviewDialog() {
    final controller = _previewController!;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        content: SizedBox(
          width: double.maxFinite,
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final pos = value.position;
              final dur = value.duration;
              final progress = dur.inMilliseconds > 0
                  ? pos.inMilliseconds / dur.inMilliseconds
                  : 0.0;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AspectRatio(
                    aspectRatio: widget.isAudio
                        ? 16 / 5
                        : controller.value.aspectRatio,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: widget.isAudio
                          ? const Center(
                              child: Icon(
                                Icons.graphic_eq,
                                color: AppColors.primary,
                                size: 44,
                              ),
                            )
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: VideoPlayer(controller),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    backgroundColor: AppColors.surfaceLighter,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${pos.inSeconds}s / ${dur.inSeconds}s',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 8),
                  IconButton(
                    onPressed: () {
                      value.isPlaying ? controller.pause() : controller.play();
                    },
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ).then((_) => controller.pause());
  }

  String _fmtDuration(double seconds) {
    final total = seconds.round();
    final mins = total ~/ 60;
    final secs = total % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }
}

enum _TimelineDragMode { start, end, range }

class _WaveformRangeEditor extends StatefulWidget {
  final WaveformData? waveform;
  final bool isLoading;
  final double startSeconds;
  final double endSeconds;
  final double durationSeconds;
  final double playheadSeconds;
  final void Function(double startSeconds, double endSeconds) onChanged;
  final ValueChanged<double> onSeek;

  const _WaveformRangeEditor({
    required this.waveform,
    required this.isLoading,
    required this.startSeconds,
    required this.endSeconds,
    required this.durationSeconds,
    required this.playheadSeconds,
    required this.onChanged,
    required this.onSeek,
  });

  @override
  State<_WaveformRangeEditor> createState() => _WaveformRangeEditorState();
}

class _WaveformRangeEditorState extends State<_WaveformRangeEditor> {
  _TimelineDragMode? _dragMode;
  double _rangeDragOffset = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final seconds = _secondsFromDx(details.localPosition.dx, width);
            widget.onSeek(seconds);
          },
          onPanStart: (details) {
            final seconds = _secondsFromDx(details.localPosition.dx, width);
            final handleTolerance = (28 / width * widget.durationSeconds).clamp(
              0.15,
              2.0,
            );
            final startDistance = (seconds - widget.startSeconds).abs();
            final endDistance = (seconds - widget.endSeconds).abs();
            if (startDistance <= handleTolerance &&
                startDistance <= endDistance) {
              _dragMode = _TimelineDragMode.start;
            } else if (endDistance <= handleTolerance) {
              _dragMode = _TimelineDragMode.end;
            } else if (seconds > widget.startSeconds &&
                seconds < widget.endSeconds) {
              _dragMode = _TimelineDragMode.range;
              _rangeDragOffset = seconds - widget.startSeconds;
            } else {
              _dragMode = startDistance < endDistance
                  ? _TimelineDragMode.start
                  : _TimelineDragMode.end;
              _applyDrag(seconds);
            }
          },
          onPanUpdate: (details) {
            _applyDrag(_secondsFromDx(details.localPosition.dx, width));
          },
          onPanEnd: (_) => _dragMode = null,
          onPanCancel: () => _dragMode = null,
          child: SizedBox(
            height: 132,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _WaveformRangePainter(
                    waveform: widget.waveform,
                    startSeconds: widget.startSeconds,
                    endSeconds: widget.endSeconds,
                    durationSeconds: widget.durationSeconds,
                    playheadSeconds: widget.playheadSeconds,
                  ),
                ),
                if (widget.isLoading)
                  const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _applyDrag(double seconds) {
    const minLength = 0.05;
    final max = widget.durationSeconds;
    switch (_dragMode) {
      case _TimelineDragMode.start:
        widget.onChanged(
          seconds.clamp(0.0, widget.endSeconds - minLength).toDouble(),
          widget.endSeconds,
        );
      case _TimelineDragMode.end:
        widget.onChanged(
          widget.startSeconds,
          seconds.clamp(widget.startSeconds + minLength, max).toDouble(),
        );
      case _TimelineDragMode.range:
        final length = widget.endSeconds - widget.startSeconds;
        final start = (seconds - _rangeDragOffset)
            .clamp(0.0, max - length)
            .toDouble();
        widget.onChanged(start, start + length);
      case null:
        break;
    }
  }

  double _secondsFromDx(double dx, double width) {
    if (width <= 0) return 0;
    return (dx / width * widget.durationSeconds)
        .clamp(0.0, widget.durationSeconds)
        .toDouble();
  }
}

class _WaveformRangePainter extends CustomPainter {
  final WaveformData? waveform;
  final double startSeconds;
  final double endSeconds;
  final double durationSeconds;
  final double playheadSeconds;

  const _WaveformRangePainter({
    required this.waveform,
    required this.startSeconds,
    required this.endSeconds,
    required this.durationSeconds,
    required this.playheadSeconds,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()..color = AppColors.background;
    final border = Paint()
      ..color = AppColors.cardBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final radius = BorderRadius.circular(10).toRRect(rect);
    canvas.drawRRect(radius, bg);
    canvas.drawRRect(radius, border);

    final content = rect.deflate(12);
    final midY = content.center.dy;
    final samples = waveform?.getDownsampledSamples(size.width.round());
    if (samples == null || samples.isEmpty) {
      final line = Paint()
        ..color = AppColors.surfaceLighter
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(content.left, midY),
        Offset(content.right, midY),
        line,
      );
    } else {
      final wavePaint = Paint()
        ..color = AppColors.textTertiary.withValues(alpha: 0.75)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      final xStep = content.width / samples.length;
      for (var i = 0; i < samples.length; i++) {
        final x = content.left + i * xStep;
        final amp = samples[i].clamp(0.03, 1.0) * content.height * 0.42;
        canvas.drawLine(
          Offset(x, midY - amp),
          Offset(x, midY + amp),
          wavePaint,
        );
      }
    }

    final startX = _xFor(startSeconds, content);
    final endX = _xFor(endSeconds, content);
    final playheadX = _xFor(playheadSeconds, content);
    final outsidePaint = Paint()..color = Colors.black.withValues(alpha: 0.42);
    canvas.drawRect(
      Rect.fromLTRB(content.left, content.top, startX, content.bottom),
      outsidePaint,
    );
    canvas.drawRect(
      Rect.fromLTRB(endX, content.top, content.right, content.bottom),
      outsidePaint,
    );

    final selectedPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.16);
    canvas.drawRect(
      Rect.fromLTRB(startX, content.top, endX, content.bottom),
      selectedPaint,
    );

    final handlePaint = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(startX, content.top),
      Offset(startX, content.bottom),
      handlePaint,
    );
    canvas.drawLine(
      Offset(endX, content.top),
      Offset(endX, content.bottom),
      handlePaint,
    );

    final playPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.82)
      ..strokeWidth = 1;
    if (playheadSeconds >= 0 && playheadSeconds <= durationSeconds) {
      canvas.drawLine(
        Offset(playheadX, content.top),
        Offset(playheadX, content.bottom),
        playPaint,
      );
    }

    _drawLabel(canvas, 'START', Offset(startX + 6, content.top + 6));
    _drawLabel(canvas, 'END', Offset(endX - 38, content.top + 6));
  }

  double _xFor(double seconds, Rect rect) {
    if (durationSeconds <= 0) return rect.left;
    return rect.left + (seconds / durationSeconds).clamp(0.0, 1.0) * rect.width;
  }

  void _drawLabel(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _WaveformRangePainter oldDelegate) {
    return oldDelegate.waveform != waveform ||
        oldDelegate.startSeconds != startSeconds ||
        oldDelegate.endSeconds != endSeconds ||
        oldDelegate.durationSeconds != durationSeconds ||
        oldDelegate.playheadSeconds != playheadSeconds;
  }
}

class _WaveformSplitEditor extends StatelessWidget {
  final WaveformData? waveform;
  final bool isLoading;
  final List<double> cutPointsSeconds;
  final double durationSeconds;
  final double playheadSeconds;
  final ValueChanged<double> onSeek;

  const _WaveformSplitEditor({
    required this.waveform,
    required this.isLoading,
    required this.cutPointsSeconds,
    required this.durationSeconds,
    required this.playheadSeconds,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            if (width <= 0) return;
            final seconds = (details.localPosition.dx / width * durationSeconds)
                .clamp(0.0, durationSeconds)
                .toDouble();
            onSeek(seconds);
          },
          child: SizedBox(
            height: 132,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _WaveformSplitPainter(
                    waveform: waveform,
                    cutPointsSeconds: cutPointsSeconds,
                    durationSeconds: durationSeconds,
                    playheadSeconds: playheadSeconds,
                  ),
                ),
                if (isLoading)
                  const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WaveformSplitPainter extends CustomPainter {
  final WaveformData? waveform;
  final List<double> cutPointsSeconds;
  final double durationSeconds;
  final double playheadSeconds;

  const _WaveformSplitPainter({
    required this.waveform,
    required this.cutPointsSeconds,
    required this.durationSeconds,
    required this.playheadSeconds,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()..color = AppColors.background;
    final border = Paint()
      ..color = AppColors.cardBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final radius = BorderRadius.circular(10).toRRect(rect);
    canvas.drawRRect(radius, bg);
    canvas.drawRRect(radius, border);

    final content = rect.deflate(12);
    final midY = content.center.dy;
    final samples = waveform?.getDownsampledSamples(size.width.round());
    if (samples == null || samples.isEmpty) {
      final line = Paint()
        ..color = AppColors.surfaceLighter
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(content.left, midY),
        Offset(content.right, midY),
        line,
      );
    } else {
      final wavePaint = Paint()
        ..color = AppColors.textTertiary.withValues(alpha: 0.75)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      final xStep = content.width / samples.length;
      for (var i = 0; i < samples.length; i++) {
        final x = content.left + i * xStep;
        final amp = samples[i].clamp(0.03, 1.0) * content.height * 0.42;
        canvas.drawLine(
          Offset(x, midY - amp),
          Offset(x, midY + amp),
          wavePaint,
        );
      }
    }

    final cutPaint = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final point in cutPointsSeconds) {
      final x = _xFor(point, content);
      canvas.drawLine(
        Offset(x, content.top),
        Offset(x, content.bottom),
        cutPaint,
      );
      _drawLabel(canvas, 'CUT', Offset(x + 5, content.top + 6));
    }

    final playPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = 1.5;
    final playX = _xFor(playheadSeconds, content);
    canvas.drawLine(
      Offset(playX, content.top),
      Offset(playX, content.bottom),
      playPaint,
    );
  }

  double _xFor(double seconds, Rect rect) {
    if (durationSeconds <= 0) return rect.left;
    return rect.left + (seconds / durationSeconds).clamp(0.0, 1.0) * rect.width;
  }

  void _drawLabel(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _WaveformSplitPainter oldDelegate) {
    return oldDelegate.waveform != waveform ||
        oldDelegate.cutPointsSeconds != cutPointsSeconds ||
        oldDelegate.durationSeconds != durationSeconds ||
        oldDelegate.playheadSeconds != playheadSeconds;
  }
}
