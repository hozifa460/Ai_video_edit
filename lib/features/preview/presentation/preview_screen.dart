import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/file_utils.dart';

class PreviewScreen extends ConsumerStatefulWidget {
  final String originalPath;
  final String processedPath;
  final Duration removedDuration;
  final Duration originalDuration;

  const PreviewScreen({
    super.key,
    required this.originalPath,
    required this.processedPath,
    required this.removedDuration,
    required this.originalDuration,
  });

  @override
  ConsumerState<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends ConsumerState<PreviewScreen> {
  VideoPlayerController? _originalController;
  VideoPlayerController? _processedController;
  ChewieController? _originalChewie;
  ChewieController? _processedChewie;
  bool _showProcessed = false;

  @override
  void initState() {
    super.initState();
    _initPlayers();
  }

  Future<void> _initPlayers() async {
    try {
      _originalController = VideoPlayerController.file(
        File(widget.originalPath),
      );
      await _originalController!.initialize();

      _originalChewie = ChewieController(
        videoPlayerController: _originalController!,
        autoPlay: false,
        aspectRatio: _originalController!.value.aspectRatio,
        materialProgressColors: ChewieProgressColors(
          playedColor: AppColors.primary,
          handleColor: AppColors.primary,
          backgroundColor: AppColors.surfaceLighter,
        ),
      );

      if (widget.originalPath != widget.processedPath) {
        final processedFile = File(widget.processedPath);
        if (await processedFile.exists()) {
          _processedController = VideoPlayerController.file(processedFile);
          await _processedController!.initialize();

          _processedChewie = ChewieController(
            videoPlayerController: _processedController!,
            autoPlay: false,
            aspectRatio: _processedController!.value.aspectRatio,
            materialProgressColors: ChewieProgressColors(
              playedColor: AppColors.accent,
              handleColor: AppColors.accent,
              backgroundColor: AppColors.surfaceLighter,
            ),
          );
        }
      }

      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load preview: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _originalController?.dispose();
    _processedController?.dispose();
    _originalChewie?.dispose();
    _processedChewie?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final processedDuration = widget.originalDuration - widget.removedDuration;
    final removedPercent = widget.originalDuration.inMilliseconds > 0
        ? (widget.removedDuration.inMilliseconds /
                widget.originalDuration.inMilliseconds *
                100)
            .toStringAsFixed(1)
        : '0';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Preview'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed(
              AppRouter.export,
              arguments: {'videoPath': widget.processedPath},
            ),
            child: const Text('Export'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 16),
            _buildComparisonToggle(),
            const SizedBox(height: 12),
            _buildPlayer(),
            const SizedBox(height: 16),
            _buildStats(processedDuration, removedPercent),
            const SizedBox(height: 16),
            _buildActionButtons(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _showProcessed = false),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: !_showProcessed
                      ? AppColors.primary
                      : AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Text(
                    'Original',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _showProcessed = true),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _showProcessed
                      ? AppColors.accent
                      : AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Text(
                    'Processed',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer() {
    final controller = _showProcessed ? _processedChewie : _originalChewie;
    if (controller == null) {
      if (_showProcessed) {
        return const Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Processed video not available yet',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        );
      }
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AspectRatio(
        aspectRatio: controller.videoPlayerController.value.aspectRatio,
        child: Chewie(controller: controller),
      ),
    ).animate().fadeIn(duration: 300.ms);
  }

  Widget _buildStats(Duration processedDuration, String removedPercent) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'Comparison',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            _statRow('Original', FileUtils.formatDuration(widget.originalDuration), Icons.movie),
            const SizedBox(height: 6),
            _statRow('Processed', FileUtils.formatDuration(processedDuration), Icons.content_cut),
            const SizedBox(height: 6),
            _statRow('Removed', FileUtils.formatDuration(widget.removedDuration), Icons.delete),
            const Divider(height: 16),
            _statRow('Removed %', '$removedPercent%', Icons.analytics),
          ],
        ),
      ),
    );
  }

  Widget _statRow(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.textTertiary),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to Editor'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => Navigator.of(context).pushNamed(
                AppRouter.export,
                arguments: {'videoPath': widget.processedPath},
              ),
              icon: const Icon(Icons.save),
              label: const Text('Export Video'),
            ),
          ),
        ],
      ),
    );
  }
}
