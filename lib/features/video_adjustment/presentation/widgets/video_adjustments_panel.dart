import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../providers/adjustment_provider.dart';
import 'adjustment_slider.dart';

class VideoAdjustmentsPanel extends ConsumerWidget {
  final VoidCallback onChanged;
  final VoidCallback onPreviewChanged;

  const VideoAdjustmentsPanel({super.key, required this.onChanged, required this.onPreviewChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(adjustmentProvider);
    final notifier = ref.read(adjustmentProvider.notifier);
    final v = settings.video;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          AdjustmentSlider(label: 'Rotate', icon: Icons.rotate_right, value: v.rotate, min: 0, max: 270, divisions: 3, displayValue: '${v.rotate.toStringAsFixed(0)}°', isModified: v.rotate != 0, onChanged: (val) { notifier.updateRotate(val); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateRotate(0); onPreviewChanged(); }),
          _buildFlipButton(context, 'Flip Horizontal', Icons.flip, v.flipHorizontal == 1, () { notifier.updateFlipHorizontal(v.flipHorizontal == 1 ? 0 : 1); onPreviewChanged(); }),
          _buildFlipButton(context, 'Flip Vertical', Icons.flip_to_front, v.flipVertical == 1, () { notifier.updateFlipVertical(v.flipVertical == 1 ? 0 : 1); onPreviewChanged(); }),
          if (v.cropWidth < 1.0 || v.cropHeight < 1.0 || v.cropX != 0 || v.cropY != 0)
            _buildResetCropButton(context, () { notifier.updateCrop(0, 0, 1, 1); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Crop Width', icon: Icons.crop_square, value: v.cropWidth, min: 0.1, max: 1.0, divisions: 90, displayValue: '${(v.cropWidth * 100).toStringAsFixed(0)}%', isModified: v.cropWidth != 1.0, onChanged: (val) { notifier.updateCrop(v.cropX, v.cropY, val, v.cropHeight); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateCrop(v.cropX, v.cropY, 1.0, v.cropHeight); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Crop Height', icon: Icons.crop_square, value: v.cropHeight, min: 0.1, max: 1.0, divisions: 90, displayValue: '${(v.cropHeight * 100).toStringAsFixed(0)}%', isModified: v.cropHeight != 1.0, onChanged: (val) { notifier.updateCrop(v.cropX, v.cropY, v.cropWidth, val); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateCrop(v.cropX, v.cropY, v.cropWidth, 1.0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Scale Width', icon: Icons.photo_size_select_large, value: v.scaleWidth, min: 0.1, max: 2.0, divisions: 190, displayValue: '${(v.scaleWidth * 100).toStringAsFixed(0)}%', isModified: v.scaleWidth != 1.0, onChanged: (v2) { notifier.updateScale(v2, v.scaleHeight); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateScale(1.0, v.scaleHeight); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Scale Height', icon: Icons.photo_size_select_small, value: v.scaleHeight, min: 0.1, max: 2.0, divisions: 190, displayValue: '${(v.scaleHeight * 100).toStringAsFixed(0)}%', isModified: v.scaleHeight != 1.0, onChanged: (v2) { notifier.updateScale(v.scaleWidth, v2); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateScale(v.scaleWidth, 1.0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Speed', icon: Icons.speed, value: v.speed, min: 0.25, max: 4.0, divisions: 75, displayValue: '${v.speed.toStringAsFixed(2)}x', isModified: v.speed != 1.0, onChanged: (val) { notifier.updateSpeed(val); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateSpeed(1.0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Fade In', icon: Icons.video_library, value: v.fadeIn, min: 0, max: 5.0, divisions: 50, displayValue: '${v.fadeIn.toStringAsFixed(1)}s', isModified: v.fadeIn != 0, onChanged: (val) { notifier.updateFadeIn(val); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateFadeIn(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Fade Out', icon: Icons.video_settings, value: v.fadeOut, min: 0, max: 5.0, divisions: 50, displayValue: '${v.fadeOut.toStringAsFixed(1)}s', isModified: v.fadeOut != 0, onChanged: (val) { notifier.updateFadeOut(val); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateFadeOut(0); onPreviewChanged(); }),
          SwitchListTile(title: const Text('Reverse', style: TextStyle(color: AppColors.textPrimary, fontSize: 14)), value: v.reverse, activeTrackColor: AppColors.primary, onChanged: (val) { notifier.updateReverse(val); onPreviewChanged(); }),
        ],
      ),
    );
  }

  Widget _buildFlipButton(BuildContext context, String label, IconData icon, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: onTap, borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: active ? AppColors.primary.withValues(alpha: 0.15) : AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(12),
            border: active ? Border.all(color: AppColors.primary.withValues(alpha: 0.4)) : null,
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: active ? AppColors.primary : AppColors.textSecondary),
              const SizedBox(width: 12),
              Text(label, style: TextStyle(color: active ? AppColors.textPrimary : AppColors.textSecondary, fontSize: 14)),
              const Spacer(),
              Icon(active ? Icons.check_circle : Icons.circle_outlined, size: 20, color: active ? AppColors.primary : AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResetCropButton(BuildContext context, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: onTap, borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
          ),
          child: const Row(
            children: [Icon(Icons.crop, size: 18, color: AppColors.warning), SizedBox(width: 12), Text('Crop active - Tap to reset', style: TextStyle(color: AppColors.warning, fontSize: 14))],
          ),
        ),
      ),
    );
  }
}
