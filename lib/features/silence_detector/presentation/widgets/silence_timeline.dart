import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/file_utils.dart';
import '../../domain/entities/silence_segment.dart';
import '../../domain/providers/silence_detection_provider.dart';

import '../controllers/editor_detection_controller.dart';

class SilenceTimeline extends ConsumerWidget {
  final double totalDuration;
  final EditorDetectionController? controller;

  const SilenceTimeline({
    super.key,
    required this.totalDuration,
    this.controller,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(silenceRemovalPlanProvider);
    // controller is passed in for identity-aware 'keep this range' (SR-04/SR-07);
    // unused when null (falls back to the provider).
    final segments = plan?.removals ?? const <SilenceSegment>[];

    if (segments.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(
              'No silence segments detected. Adjust settings and run detection.',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // Read the normalized plan instead of summing the list: overlapping or
    // duplicated intervals can no longer over-report the removed share
    // (SR-03).
    final silencePercent = plan!.removedPercent;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Detected Silences',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${segments.length} segments | ${silencePercent.toStringAsFixed(1)}% removed',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...segments.asMap().entries.map(
              (entry) => _SegmentItem(
                index: entry.key,
                segment: entry.value,
                totalDuration: totalDuration,
                controller: controller,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentItem extends ConsumerWidget {
  final int index;
  final SilenceSegment segment;
  final double totalDuration;
  final EditorDetectionController? controller;

  const _SegmentItem({
    required this.index,
    required this.segment,
    required this.totalDuration,
    this.controller,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.error,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Segment ${index + 1}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                  ),
                ),
                Text(
                  '${FileUtils.formatDurationMs((segment.startSeconds * 1000).round())} - '
                  '${FileUtils.formatDurationMs((segment.endSeconds * 1000).round())} '
                  '(${segment.durationSeconds.toStringAsFixed(1)}s)',
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Keep this range in the output (exclude from removal)',
            icon: const Icon(
              Icons.delete_outline,
              size: 18,
              color: AppColors.error,
            ),
            onPressed: () {
              if (controller != null) {
                controller!.keepInterval(index);
              } else {
                ref
                    .read(silenceRemovalPlanProvider.notifier)
                    .keepInterval(index);
              }
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}
