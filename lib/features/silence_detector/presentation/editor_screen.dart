import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'controllers/editor_detection_controller.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../../../core/enums/export_quality.dart';
import '../../../core/enums/processing_state.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/video_download_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../../audio_processing/data/repositories/audio_processor_repository_impl.dart';
import '../../audio_processing/domain/entities/waveform_data.dart';
import '../../silence_detector/data/datasources/media_probe_datasource.dart';

import '../../silence_detector/domain/providers/silence_detection_provider.dart';
import '../../silence_detector/domain/entities/media_timeline.dart';
import '../../silence_detector/domain/entities/silence_detection_blocker.dart';
import '../../silence_detector/domain/entities/silence_removal_plan.dart';
import '../../video_processing/domain/providers/processing_provider.dart';
import 'widgets/detection_settings_panel.dart';
import 'widgets/silence_timeline.dart';
import 'widgets/waveform_viewer.dart';

class EditorScreen extends ConsumerStatefulWidget {
  final String videoPath;

  const EditorScreen({super.key, required this.videoPath});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();

  /// The message this screen shows when [timeline] cannot be analysed, or `null`
  /// when detection may proceed.
  ///
  /// Exposed on the widget so the visible path is the same entry point the screen
  /// itself calls, and so it can be asserted without a video platform: the whole
  /// `EditorScreen` tree needs `VideoPlayerPlatform`, which is out of reach of
  /// `flutter test` without adding a dependency.
  static String? detectionBlockedMessage(MediaTimeline timeline) {
    final blocker = SilenceDetectionGate.blockerFor(timeline);
    return blocker == null ? null : SilenceDetectionGate.messageFor(blocker);
  }
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _isInitialized = false;
  bool _isDetecting = false;
  String? _audioPath;
  WaveformData? _waveform;
  double _waveformZoom = 1.0;

  /// Owns the identity, params-version and staleness state for this file so a
  /// plan from a previous file or an obsolete settings snapshot can never be
  /// reused (SR-04 / SR-07).
  EditorDetectionController? _controller;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  void _syncFromController() {
    final c = _controller;
    if (c == null || !mounted) return;
    // Keep the Riverpod projections the widgets read in sync with the
    // session-owned state, so identity/staleness live in one place.
    ref.read(mediaTimelineProvider.notifier).setTimeline(c.timeline);
    if (c.plan != null) {
      ref.read(silenceRemovalPlanProvider.notifier).setPlan(c.plan!);
    } else {
      ref.read(silenceRemovalPlanProvider.notifier).clear();
    }
    // Mirror params so the settings panel (which still reads the provider)
    // stays consistent with the controller's versioned params.
    ref.read(detectionParamsProvider.notifier).load(c.params);
    setState(() {});
  }

  Future<void> _initVideo() async {
    try {
      _videoController = VideoDownloadService.isUrl(widget.videoPath)
          ? VideoPlayerController.networkUrl(Uri.parse(widget.videoPath))
          : VideoPlayerController.file(File(widget.videoPath));
      await _videoController!.initialize();

      final timeline = await _probeTimeline();
      if (!mounted) return;

      final audioRepo = AudioProcessorRepositoryImpl();
      final audioResult = await audioRepo.extractAudio(widget.videoPath);
      if (!mounted) return;
      // The extracted WAV is the proof that an audio stream exists. Fold it into
      // the timeline so a probe that could not see streams still yields a
      // detectable timeline (SR-05).
      final resolvedTimeline = timeline.copyWith(
        hasAudio: audioResult is Success<String>,
      );
      ref.read(mediaTimelineProvider.notifier).setTimeline(resolvedTimeline);

      if (audioResult is AppError<String>) {
        AppLogger().e('Audio extraction failed: ${audioResult.error.message}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Audio extraction: ${audioResult.error.message}'),
            ),
          );
        }
      } else if (audioResult is Success<String>) {
        _audioPath = audioResult.value;
        // Waveform is a display-only aid. Its failure is logged and never
        // becomes the timeline: probing already produced the real duration
        // (SR-05).
        final waveformResult = await audioRepo.analyzeWaveform(
          audioResult.value,
        );
        if (!mounted) return;
        if (waveformResult is Success<WaveformData>) {
          _waveform = waveformResult.value;
          AppLogger().i(
            'Waveform: ${waveformResult.value.durationSeconds.toStringAsFixed(3)}s '
            '(display only; timeline is ${resolvedTimeline.videoDurationSeconds}s)',
          );
        } else if (waveformResult is AppError<WaveformData>) {
          AppLogger().e('Waveform failed: ${waveformResult.error.message}');
        }

        // Session-owned state for this file (SR-04 / SR-07).
        _controller = EditorDetectionController(videoPath: widget.videoPath);
        _controller!.addListener(_syncFromController);
        await _controller!.load(
          audioPath: audioResult.value,
          timeline: resolvedTimeline,
        );
        if (_waveform != null) _controller!.setWaveform(_waveform);
        _syncFromController();
      }

      if (!mounted) return;
      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: false,
        looping: false,
        aspectRatio: _videoController!.value.aspectRatio,
        placeholder: Container(color: AppColors.background),
        materialProgressColors: ChewieProgressColors(
          playedColor: AppColors.primary,
          handleColor: AppColors.primary,
          backgroundColor: AppColors.surfaceLighter,
          bufferedColor: AppColors.surfaceLight,
        ),
      );

      setState(() => _isInitialized = true);
      _detectSilence();
    } catch (e, stack) {
      AppLogger().e('Video init failed', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load video: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  /// Establishes the probed video timeline before anything is measured (SR-05).
  ///
  /// FFprobe is authoritative. The player's own duration is the fallback — it
  /// is still a video duration, unlike the waveform, so a failed probe cannot
  /// degrade correct metadata into a zero-length timeline.
  Future<MediaTimeline> _probeTimeline() async {
    final probe = MediaProbeDatasource();
    final result = await probe.probe(widget.videoPath);
    MediaTimeline timeline;
    if (result is Success<MediaTimeline>) {
      timeline = result.value;
    } else {
      AppLogger().e(
        'Media probe failed: ${(result as AppError<MediaTimeline>).error.message}',
      );
      timeline = MediaTimeline.probed(
        videoDurationSeconds: _playerDurationSeconds(),
        hasAudio: false,
      );
    }

    // Keep the probed timing; only fill in what the probe could not resolve.
    if (timeline.videoDurationSeconds <= 0) {
      timeline = timeline.copyWith(
        videoDurationSeconds: _playerDurationSeconds(),
      );
    }

    AppLogger().i(
      'Editor timeline: video=${timeline.videoDurationSeconds}s '
      'audioStart=${timeline.audioStartSeconds}s '
      'audioDuration=${timeline.audioDurationSeconds}s',
    );
    return timeline;
  }

  /// Explicit seconds → milliseconds conversion, used only as a probe fallback.
  double _playerDurationSeconds() {
    final ms = _videoController?.value.duration.inMilliseconds ?? 0;
    return ms > 0 ? ms / 1000 : 0;
  }

  /// Length of the audio window for the waveform ruler.
  ///
  /// The waveform is computed from the extracted WAV, so its own duration is
  /// the measured truth; the probed audio-stream duration is the fallback when
  /// analysis failed (B01-R4).
  double _audioSpanSeconds(MediaTimeline timeline) {
    final measured = _waveform?.durationSeconds ?? 0;
    if (measured.isFinite && measured > 0) return measured;
    return timeline.audioDurationSeconds;
  }

  Future<void> _detectSilence() async {
    final controller = _controller;
    if (controller == null || _audioPath == null) return;

    setState(() => _isDetecting = true);
    try {
      await controller.detect();
      _syncFromController();
      if (!mounted) return;
      if (controller.status == DetectionStatus.ready && controller.plan != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Detected ${controller.plan!.removals.length} silence segments '
              '(${controller.plan!.removedPercent.toStringAsFixed(1)}%)',
            ),
            backgroundColor: AppColors.success,
          ),
        );
      } else if (controller.status == DetectionStatus.failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Detection failed: ${controller.detectionError ?? "unknown"}',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } catch (e) {
      AppLogger().e('Detection error', e);
    } finally {
      if (mounted) setState(() => _isDetecting = false);
    }
  }

  Future<void> _autoDetectThreshold() async {
    final controller = _controller;
    if (controller == null || _audioPath == null) return;

    setState(() => _isDetecting = true);
    try {
      await controller.autoDetectThreshold();
      _syncFromController();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Auto threshold: ${controller.params.silenceThreshold.toStringAsFixed(0)} dB',
            ),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      AppLogger().e('Auto threshold error', e);
    } finally {
      if (mounted) setState(() => _isDetecting = false);
    }
  }

  Future<void> _previewResult() async {
    final controller = _controller;
    final plan = controller?.plan;
    if (controller != null && !controller.canPreview) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Run silence detection first')),
      );
      return;
    }
    AppLogger().i(
      'Preview: using plan with ${plan?.removals.length ?? 0} removal intervals '
      '(${plan?.removedSeconds.toStringAsFixed(3) ?? '0'}s of '
      '${plan?.totalDurationSeconds ?? 0}s)',
    );
    final guard = _requireRemovablePlan(plan);
    if (guard == null) return;

    final params = controller != null
        ? controller.params
        : ref.read(detectionParamsProvider);
    final notifier = ref.read(processingStateProvider.notifier);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            margin: const EdgeInsets.all(32),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Consumer(
                builder: (context, ref, _) {
                  final state = ref.watch(processingStateProvider);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(value: state.progress),
                      const SizedBox(height: 16),
                      Text(state.statusMessage),
                      const SizedBox(height: 8),
                      Text(
                        '${(state.progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    await notifier.startProcessing(
      videoPath: widget.videoPath,
      audioPath: _audioPath!,
      plan: guard,
      quality: ExportQuality.original,
      smartZoom: params.smartZoom,
    );

    if (mounted) {
      Navigator.of(context).pop();
      final processingState = ref.read(processingStateProvider);
      if (processingState.state == ProcessingState.completed &&
          processingState.outputPath != null) {
        _controller?.markRendered(processingState.outputPath!);
        _syncFromController();
        Navigator.of(context).pushNamed(
          AppRouter.preview,
          arguments: {
            'originalPath': widget.videoPath,
            'processedPath': processingState.outputPath,
            // Statistics come from the same plan the cut used (SR-03).
            'removedDuration': guard.removedDuration,
            'originalDuration': guard.totalDuration,
          },
        );
      } else if (processingState.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Processing failed: ${processingState.error!.message}',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _processAndExport() async {
    final controller = _controller;
    final plan = controller?.plan;
    if (controller != null && !controller.canProcess) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Run silence detection first')),
      );
      return;
    }
    AppLogger().i(
      'Export: using plan with ${plan?.removals.length ?? 0} removal intervals '
      '(${plan?.removedSeconds.toStringAsFixed(3) ?? '0'}s of '
      '${plan?.totalDurationSeconds ?? 0}s)',
    );
    final guard = _requireRemovablePlan(plan);
    if (guard == null) return;

    final params = controller != null
        ? controller.params
        : ref.read(detectionParamsProvider);
    final notifier = ref.read(processingStateProvider.notifier);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            margin: const EdgeInsets.all(32),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Consumer(
                builder: (context, ref, _) {
                  final state = ref.watch(processingStateProvider);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(value: state.progress),
                      const SizedBox(height: 16),
                      Text(state.statusMessage),
                      const SizedBox(height: 8),
                      Text(
                        '${(state.progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await notifier.startProcessing(
      videoPath: widget.videoPath,
      audioPath: _audioPath!,
      plan: guard,
      quality: ExportQuality.original,
      smartZoom: params.smartZoom,
    );

    if (mounted) {
      Navigator.of(context).pop();
      final processingState = ref.read(processingStateProvider);
      if (processingState.state == ProcessingState.completed &&
          processingState.outputPath != null) {
        _controller?.markRendered(processingState.outputPath!);
        _syncFromController();
        Navigator.of(context).pushNamed(
          AppRouter.export,
          arguments: {'videoPath': processingState.outputPath ?? widget.videoPath},
        );
      } else if (processingState.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Processing failed: ${processingState.error!.message}',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  /// Returns [plan] when it can actually be cut, otherwise reports why not and
  /// returns `null`.
  ///
  /// Guards the two ways a job could silently come out empty: no detected
  /// intervals, and a plan that would delete the whole timeline (SR-03/SR-21
  /// boundary — the typed "all silence" case is still SR-21's remaining work).
  SilenceRemovalPlan? _requireRemovablePlan(SilenceRemovalPlan? plan) {
    void report(String message) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }

    if (_audioPath == null) {
      report('No extracted audio for this file');
      return null;
    }
    if (plan == null) {
      report('Run silence detection first');
      return null;
    }
    if (!plan.isUsable) {
      report('This file has no usable duration; nothing can be cut');
      return null;
    }
    if (!plan.hasRemovals) {
      report('No silence segments to remove');
      return null;
    }
    if (plan.removesEverything) {
      report('Every second would be removed; adjust settings first');
      return null;
    }
    return plan;
  }

  @override
  void dispose() {
    _controller?.removeListener(_syncFromController);
    _controller?.close();
    _controller?.dispose();
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final processingState = ref.watch(processingStateProvider);
    final hasSegments = ref.watch(hasSilenceSegmentsProvider);
    // The probed video timeline is the ruler for every drawing below, so a
    // failed waveform can never shrink the picture the user is reviewing
    // (SR-05).
    final timeline = ref.watch(mediaTimelineProvider);
    final totalDuration = timeline.videoDurationSeconds;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Editor'),
        actions: [
          if (processingState.state == ProcessingState.processing)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: _isInitialized
          ? SingleChildScrollView(
              child: Column(
                children: [
                  _buildVideoPlayer(),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: _videoController!,
                      builder: (context, value, _) => WaveformViewer(
                        waveform: _waveform,
                        silenceSegments: ref.watch(silenceSegmentsProvider),
                        currentPosition:
                            value.position.inMilliseconds.toDouble() / 1000,
                        totalDuration: totalDuration,
                        // The audio is a window on the ruler, not the ruler
                        // itself: give the painter its real span and signed
                        // origin so a peak keeps its true position (B01-R4).
                        audioDurationSeconds: _audioSpanSeconds(timeline),
                        audioStartSeconds: timeline.audioStartSeconds,
                        waveformZoom: _waveformZoom,
                        onSeek: (seconds) {
                          _videoController?.seekTo(
                            Duration(milliseconds: (seconds * 1000).round()),
                          );
                        },
                      ),
                    ),
                  ),
                  _buildWaveformZoomControl(),
                  const SizedBox(height: 12),
                  _buildActionButtons(hasSegments, processingState),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DetectionSettingsPanel(
                      controller: _controller,
                      onAutoDetect: _autoDetectThreshold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SilenceTimeline(
                       totalDuration: totalDuration,
                       controller: _controller,
                     ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildVideoPlayer() {
    if (_chewieController == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      child: AspectRatio(
        aspectRatio: _videoController!.value.aspectRatio,
        child: Chewie(controller: _chewieController!),
      ),
    );
  }

  Widget _buildWaveformZoomControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.waves, size: 16, color: AppColors.textTertiary),
          const SizedBox(width: 8),
          const Text(
            'Zoom',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: AppColors.primary,
                inactiveTrackColor: AppColors.surfaceLighter,
                thumbColor: AppColors.primary,
                overlayColor: AppColors.primary.withValues(alpha: 0.15),
              ),
              child: Slider(
                value: _waveformZoom,
                min: 1.0,
                max: 20.0,
                divisions: 95,
                onChanged: (v) => setState(() => _waveformZoom = v),
              ),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text(
              '${_waveformZoom.toStringAsFixed(1)}x',
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(bool hasSegments, dynamic processingState) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isDetecting ? null : _detectSilence,
              icon: _isDetecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: Flexible(
                child: Text(
                  _isDetecting ? 'Detecting...' : 'Detect Silence',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
              ),
            ),
          ),
          if (hasSegments) ...[
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _previewResult,
                icon: const Icon(Icons.preview),
                label: const Flexible(
                  child: Text('Preview', overflow: TextOverflow.ellipsis),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentDark,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: processingState.state == ProcessingState.processing
                    ? null
                    : _processAndExport,
                icon: const Icon(Icons.download),
                label: const Flexible(
                  child: Text('Export', overflow: TextOverflow.ellipsis),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryDark,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
