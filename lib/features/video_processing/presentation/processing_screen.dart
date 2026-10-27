import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/enums/processing_state.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/providers/processing_provider.dart';

class ProcessingScreen extends ConsumerWidget {
  const ProcessingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final processingState = ref.watch(processingStateProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Processing'),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIcon(processingState.state),
              const SizedBox(height: 24),
              Text(
                _getStatusText(processingState),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                processingState.statusMessage,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (processingState.state == ProcessingState.processing) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: processingState.progress,
                    minHeight: 6,
                    backgroundColor: AppColors.surfaceLighter,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${(processingState.progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 24),
                TextButton.icon(
                  onPressed: () {
                    ref.read(processingStateProvider.notifier).cancel();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.cancel, color: AppColors.error),
                  label: const Text(
                    'Cancel',
                    style: TextStyle(color: AppColors.error),
                  ),
                ),
              ],
              if (processingState.state == ProcessingState.completed) ...[
                const Icon(
                  Icons.check_circle,
                  color: AppColors.success,
                  size: 72,
                ).animate().scale().fadeIn(),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
              if (processingState.state == ProcessingState.failed) ...[
                const Icon(Icons.error, color: AppColors.error, size: 72),
                const SizedBox(height: 16),
                Text(
                  processingState.error?.message ?? 'Unknown error',
                  style: const TextStyle(color: AppColors.error, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIcon(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
      case ProcessingState.extractingAudio:
      case ProcessingState.detectingSilence:
      case ProcessingState.processing:
        return const SizedBox(
          width: 72,
          height: 72,
          child: CircularProgressIndicator(strokeWidth: 4),
        ).animate().shimmer(
          duration: 1500.ms,
          color: AppColors.primaryLight.withValues(alpha: 0.3),
        );
      case ProcessingState.completed:
        return const Icon(
          Icons.check_circle,
          color: AppColors.success,
          size: 72,
        );
      case ProcessingState.cancelled:
        return const Icon(Icons.cancel, color: AppColors.warning, size: 72);
      case ProcessingState.failed:
        return const Icon(Icons.error, color: AppColors.error, size: 72);
    }
  }

  String _getStatusText(ProcessingStateModel processingState) {
    switch (processingState.state) {
      case ProcessingState.idle:
        return 'Ready';
      case ProcessingState.extractingAudio:
        return 'Extracting Audio...';
      case ProcessingState.detectingSilence:
        return 'Detecting Silence...';
      case ProcessingState.processing:
        return 'Processing Video...';
      case ProcessingState.completed:
        return 'Processing Complete!';
      case ProcessingState.cancelled:
        return 'Processing Cancelled';
      case ProcessingState.failed:
        return 'Processing Failed';
    }
  }
}
