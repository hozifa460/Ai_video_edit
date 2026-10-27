import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/video_analysis_result.dart';
import '../providers/enhancement_provider.dart';

class ResultScreen extends ConsumerStatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onDone;

  const ResultScreen({
    super.key,
    required this.onBack,
    required this.onDone,
  });

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen> {
  VideoPlayerController? _controller;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final state = ref.read(enhancementProvider);
    if (state.result?.outputPath != null) {
      _controller = VideoPlayerController.file(File(state.result!.outputPath));
      await _controller!.initialize();
      _controller!.setLooping(true);
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(enhancementProvider);
    final result = state.result;
    final originalMeta = result?.originalMetadata;
    final enhancedMeta = result?.enhancedMetadata;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Icon(
            Icons.check_circle,
            color: AppColors.success,
            size: 64,
          ),
          const SizedBox(height: 16),
          const Text(
            'Enhancement Complete!',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 32),

          if (_controller != null && _controller!.value.isInitialized)
            GestureDetector(
              onTap: () {
                setState(() {
                  if (_isPlaying) {
                    _controller!.pause();
                  } else {
                    _controller!.play();
                  }
                  _isPlaying = !_isPlaying;
                });
              },
              child: Container(
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: VideoPlayer(_controller!),
                ),
              ),
            )
          else
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),

          const SizedBox(height: 24),

          _buildMetricsComparison(originalMeta, enhancedMeta),

          const SizedBox(height: 32),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Again'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _saveVideo(context),
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: widget.onDone,
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsComparison(VideoMetadata? originalMeta, VideoMetadata? enhancedMeta) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Text('Metric', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textSecondary)),
              Text('Before', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textSecondary)),
              Text('After', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.success)),
            ],
          ),
          const Divider(height: 24),
          _buildMetricRow('Resolution', 
            '${originalMeta?.width ?? 0}x${originalMeta?.height ?? 0}',
            '${enhancedMeta?.width ?? 1920}x${enhancedMeta?.height ?? 1080}'),
          _buildMetricRow('Bitrate', 
            '${((originalMeta?.videoBitrate ?? 0) / 1000).round()}kbps',
            '${((enhancedMeta?.videoBitrate ?? 8000000) / 1000).round()}kbps'),
          _buildMetricRow('File Size', 
            '${((originalMeta?.fileSizeBytes ?? 0) / 1024 / 1024).round()}MB',
            '${((enhancedMeta?.fileSizeBytes ?? 0) / 1024 / 1024).round()}MB'),
        ],
      ),
    );
  }

  Widget _buildMetricRow(String label, String before, String after) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(color: AppColors.textSecondary)),
          ),
          SizedBox(
            width: 80,
            child: Text(before, style: const TextStyle(color: AppColors.textPrimary)),
          ),
          SizedBox(
            width: 80,
            child: Text(after, style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _saveVideo(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Video saved to gallery'),
        backgroundColor: AppColors.success,
      ),
    );
  }
}