import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/services/video_download_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/clip_suggestion.dart';
import '../../domain/entities/reframe_settings.dart';
import '../providers/shorts_provider.dart';

class SuggestionsScreen extends ConsumerWidget {
  const SuggestionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uiState = ref.watch(shortsUiProvider);
    final project = uiState.project;
    final suggestions = uiState.selectedClips;

    if (project == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('No project')));
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Suggested Clips')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: project.suggestions.length,
              itemBuilder: (_, i) {
                final clip = project.suggestions[i];
                final isSelected = suggestions.contains(clip);
                return _ClipCard(
                  clip: clip,
                  selected: isSelected,
                  index: i,
                  videoPath: project.videoPath,
                  totalVideoDuration: project.totalDuration,
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: suggestions.isEmpty ? null : () {
                  final notifier = ref.read(shortsUiProvider.notifier);
                  notifier.setPaths([]);
                  notifier.setProgress(0);
                  notifier.setStage('');
                  Navigator.of(context).pushNamed(AppRouter.shortsExport);
                },
                icon: const Icon(Icons.download),
                label: Text('Export ${suggestions.length} Clips'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClipCard extends ConsumerWidget {
  final ClipSuggestion clip;
  final bool selected;
  final int index;
  final String videoPath;
  final double totalVideoDuration;

  const _ClipCard({
    required this.clip,
    required this.selected,
    required this.index,
    required this.videoPath,
    required this.totalVideoDuration,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => ref.read(shortsUiProvider.notifier).toggleClip(clip),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.08) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppColors.primary : AppColors.cardBorder, width: selected ? 1.5 : 1),
        ),
        child: Row(
          children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text('${(clip.score * 100).round()}%', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.primary)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(clip.label, style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 4),
                  Text(
                    '${_fmt(clip.startSeconds)} - ${_fmt(clip.endSeconds)}  (${clip.durationSeconds.round()}s)',
                    style: const TextStyle(color: AppColors.textTertiary, fontSize: 12),
                  ),
                ],
              ),
            ),
              IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              color: AppColors.textTertiary,
              tooltip: 'Edit time',
              onPressed: () => _showEditDialog(context, ref),
            ),
            _TemplateBadge(clip: clip, ref: ref),
            const SizedBox(width: 2),
            IconButton(
              icon: const Icon(Icons.play_circle_outline, size: 22),
              color: AppColors.primary,
              tooltip: 'Preview clip',
              onPressed: () => _showPreview(context),
            ),
            const SizedBox(width: 4),
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? AppColors.primary : AppColors.textTertiary,
              size: 24,
            ),
          ],
        ),
      ),
    );
  }

  void _showPreview(BuildContext context) {
    final videoFile = File(videoPath);
    if (!VideoDownloadService.isUrl(videoPath) && !videoFile.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Video file not found'), backgroundColor: AppColors.error));
      return;
    }

    Navigator.of(context).push(_PreviewRoute(
      videoPath: videoPath,
      start: clip.startSeconds,
      end: clip.endSeconds,
    ));
  }

  void _showEditDialog(BuildContext context, WidgetRef ref) {
    Navigator.of(context).push(_EditClipDialogRoute(
      videoPath: videoPath,
      totalVideoDuration: totalVideoDuration,
      clip: clip,
      ref: ref,
    ));
  }

  String _fmt(double s) {
    final m = (s / 60).floor();
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

class _TemplateBadge extends ConsumerWidget {
  final ClipSuggestion clip;
  final WidgetRef ref;

  const _TemplateBadge({required this.clip, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = clip.reframeMode;
    final label = mode?.label ?? 'Default';
    return GestureDetector(
      onTap: () => _showTemplateSheet(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_iconForMode(mode), size: 12, color: AppColors.primary),
            const SizedBox(width: 3),
            Text(label, style: const TextStyle(color: AppColors.primary, fontSize: 10, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  IconData _iconForMode(ReframeMode? mode) {
    switch (mode) {
      case ReframeMode.centerCrop: return Icons.crop;
      case ReframeMode.pillarbox: return Icons.photo_size_select_large;
      case ReframeMode.faceAware: return Icons.face;
      case ReframeMode.blurBackground: return Icons.blur_on;
      case ReframeMode.cinematicLetterbox: return Icons.straighten;
      case ReframeMode.kenBurns: return Icons.zoom_in;
      case ReframeMode.shadowGlow: return Icons.flare;
      case ReframeMode.mirrorSplit: return Icons.flip;
      default: return Icons.style;
    }
  }

  void _showTemplateSheet(BuildContext context, WidgetRef ref) {
    final allModes = ReframeMode.values;
    final current = clip.reframeMode;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Reframe Template', style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('Default: ${_getGlobalMode(ref).label}',
                style: const TextStyle(color: AppColors.textTertiary, fontSize: 12)),
              const SizedBox(height: 12),
              SizedBox(
                height: 340,
                child: ListView(
                  children: allModes.map((mode) {
                    final isSelected = current == mode;
                    final isDefault = current == null && mode == _getGlobalMode(ref);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: GestureDetector(
                        onTap: () {
                          ref.read(shortsUiProvider.notifier).updateClipReframe(clip, mode);
                          Navigator.of(ctx).pop();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected ? AppColors.primary.withValues(alpha: 0.1) : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(_iconForMode(mode), size: 18, color: isSelected ? AppColors.primary : AppColors.textSecondary),
                              const SizedBox(width: 10),
                              Expanded(child: Text(mode.label, style: TextStyle(color: isSelected ? AppColors.primary : AppColors.textPrimary, fontSize: 13))),
                              if (isDefault)
                                const Text('default', style: TextStyle(color: AppColors.textTertiary, fontSize: 10)),
                              if (isSelected)
                                const Icon(Icons.check, size: 16, color: AppColors.primary),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  ReframeMode _getGlobalMode(WidgetRef ref) {
    return ref.read(exportSettingsProvider).reframeMode;
  }
}

class _EditClipDialogRoute extends PageRouteBuilder<void> {
  final String videoPath;
  final double totalVideoDuration;
  final ClipSuggestion clip;
  final WidgetRef ref;

  _EditClipDialogRoute({
    required this.videoPath,
    required this.totalVideoDuration,
    required this.clip,
    required this.ref,
  }) : super(
          opaque: false,
          barrierDismissible: true,
          barrierColor: Colors.black54,
          pageBuilder: (context, animation, secondaryAnimation) => _EditClipScreen(
            videoPath: videoPath,
            totalVideoDuration: totalVideoDuration,
            clip: clip,
            ref: ref,
          ),
        );
}

class _EditClipScreen extends StatefulWidget {
  final String videoPath;
  final double totalVideoDuration;
  final ClipSuggestion clip;
  final WidgetRef ref;

  const _EditClipScreen({required this.videoPath, required this.totalVideoDuration, required this.clip, required this.ref});

  @override
  State<_EditClipScreen> createState() => _EditClipScreenState();
}

class _EditClipScreenState extends State<_EditClipScreen> {
  late double _startSec;
  late double _endSec;
  VideoPlayerController? _controller;
  bool _initialized = false;
  double _playheadSec = 0;

  @override
  void initState() {
    super.initState();
    _startSec = widget.clip.startSeconds;
    _endSec = widget.clip.endSeconds;
    _playheadSec = _startSec;
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final ctrl = VideoDownloadService.isUrl(widget.videoPath)
        ? VideoPlayerController.networkUrl(Uri.parse(widget.videoPath))
        : VideoPlayerController.file(File(widget.videoPath));
    await ctrl.initialize();
    await ctrl.seekTo(Duration(milliseconds: (_startSec * 1000).round()));
    ctrl.addListener(_onPositionChange);
    ctrl.play();
    _controller = ctrl;
    setState(() => _initialized = true);
  }

  void _onPositionChange() {
    if (_controller == null) return;
    final pos = _controller!.value.position.inMilliseconds / 1000.0;
    setState(() => _playheadSec = pos);
  }

  void _onStartChanged(double v) {
    setState(() {
      _startSec = v;
      _playheadSec = v;
      if (_startSec + 1 > _endSec) _endSec = _startSec + 1;
    });
    _controller?.seekTo(Duration(milliseconds: (_startSec * 1000).round()));
  }

  void _onEndChanged(double v) {
    setState(() {
      _endSec = v;
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_onPositionChange);
    _controller?.pause();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final endMax = widget.totalVideoDuration;
    final minClip = 1.0;
    final startMax = (_endSec - minClip).clamp(minClip, endMax);
    final endMin = (_startSec + minClip).clamp(0.0, endMax);
    final startDiv = ((startMax) * 20).round().clamp(1, 2000);
    final endDiv = ((endMax - endMin) * 20).round().clamp(1, 2000);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Edit Clip Time', style: TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () {
                    if (_controller == null) return;
                    if (_controller!.value.isPlaying) {
                      _controller!.pause();
                    } else {
                      _controller!.seekTo(Duration(milliseconds: (_startSec * 1000).round()));
                      _controller!.play();
                    }
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _initialized && _controller != null
                        ? AspectRatio(
                            aspectRatio: _controller!.value.aspectRatio,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                VideoPlayer(_controller!),
                                Center(
                                  child: _controller!.value.isPlaying
                                      ? const SizedBox()
                                      : Container(
                                          width: 48, height: 48,
                                          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black54),
                                          child: const Icon(Icons.play_arrow, color: Colors.white, size: 28),
                                        ),
                                ),
                              ],
                            ),
                          )
                        : Container(
                            height: 200,
                            color: Colors.black,
                            child: const Center(child: CircularProgressIndicator(color: Colors.white)),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${_fmt(_startSec)} - ${_fmt(_endSec)} (${(_endSec - _startSec).round()}s)',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    Text('▶ ${_fmt(_playheadSec)}',
                      style: const TextStyle(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.maxWidth;
                    final origStart = widget.clip.startSeconds;
                    final origEnd = widget.clip.endSeconds;
                    final origStartRatio = (origStart / endMax).clamp(0.0, 1.0);
                    final origEndRatio = (origEnd / endMax).clamp(0.0, 1.0);
                    final curStartRatio = (_startSec / endMax).clamp(0.0, 1.0);
                    final curEndRatio = (_endSec / endMax).clamp(0.0, 1.0);
                    final playRatio = (_playheadSec / endMax).clamp(0.0, 1.0);
                    return Column(
                      children: [
                        SizedBox(
                          height: 28,
                          child: Stack(
                            children: [
                              Container(height: 28, decoration: BoxDecoration(color: AppColors.surfaceLighter, borderRadius: BorderRadius.circular(4))),
                              Positioned(
                                left: w * origStartRatio, width: w * (origEndRatio - origStartRatio),
                                child: Container(height: 28, decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4))),
                              ),
                              Positioned(
                                left: w * curStartRatio, width: w * (curEndRatio - curStartRatio),
                                child: Container(height: 28, decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(4))),
                              ),
                              Positioned(
                                left: w * curStartRatio,
                                top: 0,
                                child: Container(width: 3, height: 28, decoration: BoxDecoration(color: Colors.white70, borderRadius: BorderRadius.circular(1))),
                              ),
                              Positioned(
                                left: w * curEndRatio - 3,
                                top: 0,
                                child: Container(width: 3, height: 28, decoration: BoxDecoration(color: Colors.white70, borderRadius: BorderRadius.circular(1))),
                              ),
                              if (playRatio > 0 && playRatio < 1)
                                Positioned(
                                  left: (w * playRatio - 5).clamp(0.0, w - 10),
                                  top: 2,
                                  child: Container(
                                    width: 10, height: 24,
                                    decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(2)),
                                    child: Center(child: Container(width: 4, height: 4, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle))),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_fmt(0), style: const TextStyle(color: AppColors.textTertiary, fontSize: 9)),
                            Text(_fmt(endMax), style: const TextStyle(color: AppColors.textTertiary, fontSize: 9)),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text('Start', style: const TextStyle(color: AppColors.textTertiary, fontSize: 11)),
                Slider(
                  value: _startSec.clamp(0, startMax),
                  min: 0, max: startMax,
                  divisions: startDiv,
                  activeColor: AppColors.primary,
                  onChanged: _onStartChanged,
                ),
                Text('End', style: const TextStyle(color: AppColors.textTertiary, fontSize: 11)),
                Slider(
                  value: _endSec.clamp(endMin, endMax),
                  min: endMin, max: endMax,
                  divisions: endDiv,
                  activeColor: AppColors.primary,
                  onChanged: _onEndChanged,
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        widget.ref.read(shortsUiProvider.notifier).updateClipSegment(widget.clip, _startSec, _endSec);
                        Navigator.of(context).pop();
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmt(double s) {
    final m = (s / 60).floor();
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

class _PreviewRoute extends PageRouteBuilder<void> {
  final String videoPath;
  final double start;
  final double end;

  _PreviewRoute({
    required this.videoPath,
    required this.start,
    required this.end,
  }) : super(
          opaque: false,
          barrierDismissible: true,
          barrierColor: Colors.black87,
          pageBuilder: (context, animation, secondaryAnimation) => _PreviewScreen(
            videoPath: videoPath,
            start: start,
            end: end,
          ),
        );
}

class _PreviewScreen extends StatefulWidget {
  final String videoPath;
  final double start;
  final double end;

  const _PreviewScreen({required this.videoPath, required this.start, required this.end});

  @override
  State<_PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<_PreviewScreen> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _isPlaying = false;
  double _positionSec = 0;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final ctrl = VideoDownloadService.isUrl(widget.videoPath)
        ? VideoPlayerController.networkUrl(Uri.parse(widget.videoPath))
        : VideoPlayerController.file(File(widget.videoPath));
    await ctrl.initialize();
    await ctrl.seekTo(Duration(milliseconds: (widget.start * 1000).round()));
    ctrl.addListener(_onPositionChange);
    _controller = ctrl;
    setState(() => _initialized = true);
  }

  void _onPositionChange() {
    if (_controller == null) return;
    final pos = _controller!.value.position.inMilliseconds / 1000.0;
    setState(() => _positionSec = pos);
    if (pos >= widget.end) {
      _controller!.pause();
      _controller!.seekTo(Duration(milliseconds: (widget.start * 1000).round()));
      setState(() => _isPlaying = false);
    }
  }

  void _togglePlay() {
    if (_controller == null) return;
    if (_isPlaying) {
      _controller!.pause();
      setState(() => _isPlaying = false);
    } else {
      final pos = _controller!.value.position.inMilliseconds / 1000.0;
      if (pos >= widget.end) {
        _controller!.seekTo(Duration(milliseconds: (widget.start * 1000).round()));
      }
      _controller!.play();
      setState(() => _isPlaying = true);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onPositionChange);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dur = widget.end - widget.start;
    final clipPos = (_positionSec - widget.start).clamp(0.0, dur);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _togglePlay,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _initialized && _controller != null
                    ? AspectRatio(
                        aspectRatio: _controller!.value.aspectRatio,
                        child: VideoPlayer(_controller!),
                      )
                    : Container(
                        width: 300,
                        height: 500,
                        color: Colors.black,
                        child: const Center(child: CircularProgressIndicator(color: Colors.white)),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            if (_initialized)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final totalW = constraints.maxWidth;
                    final startRatio = (widget.start / _controller!.value.duration.inMilliseconds * 1000).clamp(0.0, 1.0);
                    final clipRatio = (dur / (_controller!.value.duration.inMilliseconds / 1000.0)).clamp(0.0, 1.0);
                    return Column(
                      children: [
                        SizedBox(
                          height: 6,
                          child: Stack(
                            children: [
                              Container(height: 6, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3))),
                              Positioned(
                                left: totalW * startRatio,
                                width: totalW * clipRatio,
                                child: Container(height: 6, decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(3))),
                              ),
                              if (clipPos > 0)
                                Positioned(
                                  left: totalW * (startRatio + clipRatio * (clipPos / dur)),
                                  child: Container(width: 3, height: 6, color: Colors.white),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_fmt(widget.start), style: const TextStyle(color: Colors.white54, fontSize: 11)),
                            Text(_fmt(widget.end), style: const TextStyle(color: Colors.white54, fontSize: 11)),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '${_fmt(widget.start)} - ${_fmt(widget.end)} (${dur.round()}s)',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filled(
                  onPressed: _togglePlay,
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  style: IconButton.styleFrom(backgroundColor: AppColors.primary),
                ),
                const SizedBox(width: 12),
                IconButton.filled(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  style: IconButton.styleFrom(backgroundColor: Colors.white24),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(double s) {
    final m = (s / 60).floor();
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}
