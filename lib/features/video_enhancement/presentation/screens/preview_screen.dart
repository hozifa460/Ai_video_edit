import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/enhancement_provider.dart';
import '../widgets/split_comparison_widget.dart';

class PreviewScreen extends ConsumerWidget {
  final VoidCallback onBack;
  final VoidCallback onEnhance;

  const PreviewScreen({
    super.key,
    required this.onBack,
    required this.onEnhance,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(enhancementProvider);

    if (state.isProcessing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppColors.primary),
            SizedBox(height: 16),
            Text(
              'Generating preview...',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    if (state.previewFrames.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_library, size: 64, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            const Text(
              'No preview frames available',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onEnhance,
              child: const Text('Skip Preview & Enhance'),
            ),
          ],
        ),
      );
    }

    final currentFrame = state.previewFrames[state.selectedPreviewIndex];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const Expanded(
                child: Text(
                  'Before / After Preview',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
        ),
        
        Expanded(
          child: currentFrame.enhancedPath != null
            ? SplitComparisonWidget(
                originalPath: currentFrame.originalPath,
                enhancedPath: currentFrame.enhancedPath!,
              )
            : const Center(
                child: Text('Loading preview...'),
              ),
        ),
        
        if (state.previewFrames.length > 1)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(state.previewFrames.length, (index) {
                return GestureDetector(
                  onTap: () => ref.read(enhancementProvider.notifier).selectPreviewFrame(index),
                  child: Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: index == state.selectedPreviewIndex
                        ? AppColors.primary
                        : AppColors.textSecondary.withValues(alpha: 0.3),
                    ),
                  ),
                );
              }),
            ),
          ),
        
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onBack,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Adjust Settings'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: onEnhance,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Enhance Now',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
