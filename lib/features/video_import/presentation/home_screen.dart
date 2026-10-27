import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/draft_service.dart';
import '../../../core/services/video_download_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../data/repositories/video_import_repository_impl.dart';
import '../domain/entities/video_file.dart';
import 'widgets/feature_card.dart';
import 'widgets/import_button.dart';
import 'widgets/video_info_card.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  VideoFile? _videoFile;
  bool _isLoading = false;
  bool _isAudioFile = false;
  List<DraftData> _drafts = [];

  @override
  void initState() {
    super.initState();
    _loadDrafts();
  }

  Future<void> _loadDrafts() async {
    final drafts = await DraftService.allDrafts();
    if (mounted) setState(() => _drafts = drafts);
  }

  Future<void> _importVideo() async {
    setState(() => _isLoading = true);
    try {
      final repository = VideoImportRepositoryImpl();
      final result = await repository.importVideo();
      if (result is Success<VideoFile>) {
        setState(() {
          _videoFile = result.value;
          _isAudioFile = false;
        });
        await _loadDrafts();
      } else if (result is AppError<VideoFile>) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.error.message),
              backgroundColor: AppColors.error,
            ),
          );
        }
      }
    } catch (e) {
      AppLogger().e('Import error', e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _importAudio() async {
    setState(() => _isLoading = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;

      final repository = VideoImportRepositoryImpl();
      final metaResult = await repository.getVideoMetadata(path);
      if (metaResult is Success<VideoFile>) {
        setState(() {
          _videoFile = metaResult.value;
          _isAudioFile = true;
        });
      } else {
        final file = File(path);
        final length = await file.length();
        final name = path.split('/').last.split('\\').last;
        setState(() {
          _videoFile = VideoFile(
            path: path,
            fileName: name,
            fileSize: length,
            duration: Duration.zero,
            width: 0,
            height: 0,
            fps: 0,
            format: name.split('.').last.toLowerCase(),
            hasAudio: true,
          );
          _isAudioFile = true;
        });
      }
      await _loadDrafts();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Audio loaded: ${_videoFile!.fileName}'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      AppLogger().e('Audio import error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to import audio: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showUrlImportDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Import from URL',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'https://example.com/video.mp4 or YouTube link',
            hintStyle: TextStyle(
              color: AppColors.textTertiary.withValues(alpha: 0.7),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            filled: true,
            fillColor: AppColors.surfaceLight,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final url = controller.text.trim();
              if (url.isNotEmpty) {
                Navigator.of(ctx).pop();
                _downloadFromUrl(url);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  Future<void> _showUpdateDialog() async {
    const url =
        'https://github.com/hozifa460/Ai_video_edit/releases/download/latest/ai-video-edit-latest.apk';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download Latest APK'),
        content: SelectableText(url),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () async {
              final uri = Uri.parse(url);
              try {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } catch (_) {}
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadFromUrl(String url) async {
    if (VideoDownloadService.isYoutubeUrl(url)) {
      await _resolveFromYoutube(url);
      return;
    }

    final cancelToken = CancelToken();
    var lastProgress = 0.0;

    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: AppColors.surface,
            content: StatefulBuilder(
              builder: (context, setDialogState) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: AppColors.primary),
                  const SizedBox(height: 16),
                  Text(
                    lastProgress > 0
                        ? '${(lastProgress * 100).round()}%'
                        : 'Downloading...',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                    ),
                  ),
                  if (lastProgress > 0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: lastProgress,
                      backgroundColor: AppColors.surfaceLighter,
                      valueColor: const AlwaysStoppedAnimation(
                        AppColors.primary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () {
                      cancelToken.cancel();
                      Navigator.of(ctx).pop();
                    },
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: AppColors.error),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      final path = await VideoDownloadService.downloadVideo(
        url,
        onProgress: (p) {
          lastProgress = p;
        },
        cancelToken: cancelToken,
      );

      if (mounted) Navigator.of(context).pop();

      final metaResult = await VideoImportRepositoryImpl().getVideoMetadata(
        path,
      );
      if (metaResult is Success<VideoFile>) {
        setState(() {
          _videoFile = metaResult.value;
          _isAudioFile = false;
        });
      } else {
        final file = File(path);
        final length = await file.length();
        final name = path.split('/').last.split('\\').last;
        setState(() {
          _videoFile = VideoFile(
            path: path,
            fileName: name,
            fileSize: length,
            duration: Duration.zero,
            width: 0,
            height: 0,
            fps: 0,
            format: name.split('.').last.toLowerCase(),
            hasAudio: true,
          );
          _isAudioFile = false;
        });
      }
      await _loadDrafts();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Downloaded: ${_videoFile!.fileName}'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } on CancelledDownloadException {
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      AppLogger().e('URL download error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _resolveFromYoutube(String url) async {
    try {
      setState(() => _isLoading = true);

      final options = await VideoDownloadService.getAvailableQualities(url);

      if (options.isEmpty) throw Exception('No available streams');

      YoutubeQualityOption? picked;

      if (options.length == 1) {
        picked = options.first;
      } else if (mounted) {
        picked = await showDialog<YoutubeQualityOption>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text(
              'Choose quality',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: options.map((o) {
                  final info = o.streamInfo;
                  final size = info != null
                      ? _formatSize(info.size.totalBytes)
                      : '';
                  return ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.wifi,
                      size: 20,
                      color: AppColors.primary,
                    ),
                    title: Text(
                      o.label,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      'Stream · $size',
                      style: TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                    onTap: () => Navigator.of(ctx).pop(o),
                  );
                }).toList(),
              ),
            ),
          ),
        );
      }

      if (picked == null) return;
      final pickedOption = picked;

      if (!mounted) return;

      final cancelToken = CancelToken();
      final progressNotifier = ValueNotifier<DownloadProgress>(
        const DownloadProgress(
          progress: 0,
          receivedBytes: 0,
          totalBytes: 0,
          speedBytesPerSec: 0,
          statusText: 'Downloading...',
        ),
      );

      unawaited(
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => PopScope(
            canPop: false,
            child: AlertDialog(
              backgroundColor: AppColors.surface,
              content: ValueListenableBuilder<DownloadProgress>(
                valueListenable: progressNotifier,
                builder: (context, progress, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: progress.progress,
                      backgroundColor: AppColors.surfaceLighter,
                      valueColor: const AlwaysStoppedAnimation(
                        AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      progress.statusText.isNotEmpty
                          ? progress.statusText
                          : '${(progress.progress * 100).round()}%',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () {
                        cancelToken.cancel();
                        Navigator.of(ctx).pop();
                      },
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final localPath = await VideoDownloadService.downloadAndMergeYoutube(
        url,
        pickedOption,
        'youtube',
        onProgress: (p) {
          progressNotifier.value = p;
        },
        cancelToken: cancelToken,
      );

      if (mounted) Navigator.of(context).pop();

      final metaResult = await VideoImportRepositoryImpl().getVideoMetadata(
        localPath,
      );
      if (metaResult is Success<VideoFile>) {
        setState(() {
          _videoFile = metaResult.value;
          _isAudioFile = false;
        });
      } else {
        final file = File(localPath);
        final length = await file.length();
        final name = localPath.split('/').last.split('\\').last;
        setState(() {
          _videoFile = VideoFile(
            path: localPath,
            fileName: name,
            fileSize: length,
            duration: Duration.zero,
            width: 0,
            height: 0,
            fps: 0,
            format: name.split('.').last.toLowerCase(),
            hasAudio: true,
          );
          _isAudioFile = false;
        });
      }

      await _loadDrafts();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('YouTube video loaded: ${_videoFile!.fileName}'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } on CancelledDownloadException {
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      AppLogger().e('YouTube resolve error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('YouTube error: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openSilenceRemover() {
    if (_videoFile == null) return;
    Navigator.of(
      context,
    ).pushNamed(AppRouter.editor, arguments: _videoFile!.path);
  }

  void _openVideoAdjuster() {
    if (_videoFile == null) return;
    Navigator.of(
      context,
    ).pushNamed(AppRouter.adjustments, arguments: _videoFile!.path);
  }

  void _openShortsGenerator() {
    if (_videoFile == null) return;
    Navigator.of(
      context,
    ).pushNamed(AppRouter.shorts, arguments: _videoFile!.path);
  }

  void _openEnhancer() {
    if (_videoFile == null) return;
    Navigator.of(
      context,
    ).pushNamed(AppRouter.enhancement, arguments: _videoFile!.path);
  }

  void _openAudioEnhancer() {
    if (_videoFile == null) return;
    Navigator.of(
      context,
    ).pushNamed(AppRouter.audioEnhance, arguments: _videoFile!.path);
  }

  void _openMediaCutter() {
    if (_videoFile == null) return;
    Navigator.of(context).pushNamed(
      AppRouter.mediaCutter,
      arguments: {
        'mediaPath': _videoFile!.path,
        'isAudio': _isAudioFile,
        'hasAudio': _videoFile!.hasAudio,
        'duration': _videoFile!.duration,
      },
    );
  }

  void _resumeDraft(DraftData draft) {
    Navigator.of(
      context,
    ).pushNamed(AppRouter.shorts, arguments: draft.videoPath);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('AI Video Studio'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Download Latest APK',
            icon: const Icon(Icons.system_update),
            onPressed: _showUpdateDialog,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 24),
            if (_isAudioFile) ...[
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 0.92,
                children: [
                  FeatureCard(
                    icon: Icons.content_cut,
                    title: 'Audio\nEditor',
                    subtitle: 'Trim, split, clean and enhance',
                    gradientColors: const [
                      Color(0xFF00B8D9),
                      Color(0xFF0077B6),
                    ],
                    onTap: _openMediaCutter,
                    disabled: false,
                  ),
                  FeatureCard(
                    icon: Icons.audiotrack,
                    title: 'Audio\nEnhancer',
                    subtitle: 'Denoise, compress & normalize',
                    gradientColors: const [
                      Color(0xFF9B59B6),
                      Color(0xFF8E44AD),
                    ],
                    onTap: _openAudioEnhancer,
                    disabled: false,
                  ),
                  const SizedBox.shrink(),
                ],
              ),
            ] else ...[
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 0.92,
                children: [
                  FeatureCard(
                    icon: Icons.content_cut,
                    title: 'Media\nCutter',
                    subtitle: 'Trim video and audio together',
                    gradientColors: const [
                      Color(0xFF00B8D9),
                      Color(0xFF0077B6),
                    ],
                    onTap: _openMediaCutter,
                    disabled: _videoFile == null,
                  ),
                  FeatureCard(
                    icon: Icons.content_cut,
                    title: 'Silence\nRemover',
                    subtitle: 'Remove pauses with perfect A/V sync',
                    gradientColors: const [
                      Color(0xFF6C63FF),
                      Color(0xFF4A42D4),
                    ],
                    onTap: _openSilenceRemover,
                    disabled: _videoFile == null,
                  ),
                  FeatureCard(
                    icon: Icons.tune,
                    title: 'Video\nAdjuster',
                    subtitle: 'Color grading, filters, audio & more',
                    gradientColors: const [
                      Color(0xFF00D9A6),
                      Color(0xFF00A87F),
                    ],
                    onTap: _openVideoAdjuster,
                    disabled: _videoFile == null,
                  ),
                  FeatureCard(
                    icon: Icons.auto_fix_high,
                    title: 'Enhancer',
                    subtitle: 'Upscale, denoise, stabilize & color',
                    gradientColors: const [
                      Color(0xFFFF6B6B),
                      Color(0xFFEE5A24),
                    ],
                    onTap: _openEnhancer,
                    disabled: _videoFile == null,
                  ),
                  FeatureCard(
                    icon: Icons.content_copy,
                    title: 'Shorts\nCreator',
                    subtitle: 'Convert long videos to TikTok/Reels',
                    gradientColors: const [
                      Color(0xFFF39C12),
                      Color(0xFFE67E22),
                    ],
                    onTap: _openShortsGenerator,
                    disabled: _videoFile == null,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            if (_videoFile != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: VideoInfoCard(video: _videoFile!),
              ),
            Row(
              children: [
                Expanded(
                  child: ImportButton(
                    onPressed: _importVideo,
                    isLoading: _isLoading,
                  ),
                ),
                if (!_isAudioFile) ...[
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _importAudio,
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: AppColors.surface,
                        foregroundColor: AppColors.textPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: AppColors.cardBorder),
                        ),
                      ),
                      child: const Icon(Icons.audiotrack, size: 22),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _showUrlImportDialog,
              icon: const Icon(Icons.link, size: 16),
              label: const Text(
                'Import from URL',
                style: TextStyle(fontSize: 13),
              ),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
              ),
            ),
            if (_drafts.isNotEmpty) ...[
              const SizedBox(height: 24),
              Row(
                children: [
                  const Icon(
                    Icons.history,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Resume Draft (${_drafts.length})',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ..._drafts.map((d) => _buildDraftCard(d)),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 20,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Import a video to unlock video editing features, or import audio for Audio Enhancer. Supports MP4, MOV, MKV, AVI, WebM, MP3, WAV, AAC, FLAC.',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildDraftCard(DraftData draft) {
    final name = draft.videoPath.split('/').last.split('\\').last;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: ListTile(
        dense: true,
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.content_copy,
            size: 18,
            color: AppColors.primary,
          ),
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
        ),
        subtitle: Text(
          '${draft.clips.length} clips · ${draft.totalDuration.toStringAsFixed(0)}s total',
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
        trailing: const Icon(
          Icons.chevron_right,
          size: 18,
          color: AppColors.textTertiary,
        ),
        onTap: () => _resumeDraft(draft),
      ),
    );
  }
}
