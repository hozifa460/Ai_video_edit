import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/adjustment_provider.dart';
import 'adjustment_slider.dart';

class ColorAdjustmentsPanel extends ConsumerWidget {
  final VoidCallback onChanged;
  final VoidCallback onPreviewChanged;

  const ColorAdjustmentsPanel({super.key, required this.onChanged, required this.onPreviewChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(adjustmentProvider);
    final notifier = ref.read(adjustmentProvider.notifier);
    final c = settings.color;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          AdjustmentSlider(label: 'Temperature', icon: Icons.wb_sunny, value: c.temperature, min: -100, max: 100, displayValue: '${c.temperature.toStringAsFixed(0)}K', isModified: c.temperature != 0, onChanged: (v) { notifier.updateTemperature(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateTemperature(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Tint', icon: Icons.invert_colors, value: c.tint, min: -100, max: 100, displayValue: c.tint.toStringAsFixed(0), isModified: c.tint != 0, onChanged: (v) { notifier.updateTint(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateTint(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Red Balance', icon: Icons.lens, value: c.redBalance, min: -1.0, max: 1.0, displayValue: c.redBalance.toStringAsFixed(2), isModified: c.redBalance != 0, onChanged: (v) { notifier.updateRedBalance(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateRedBalance(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Green Balance', icon: Icons.lens, value: c.greenBalance, min: -1.0, max: 1.0, displayValue: c.greenBalance.toStringAsFixed(2), isModified: c.greenBalance != 0, onChanged: (v) { notifier.updateGreenBalance(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateGreenBalance(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Blue Balance', icon: Icons.lens, value: c.blueBalance, min: -1.0, max: 1.0, displayValue: c.blueBalance.toStringAsFixed(2), isModified: c.blueBalance != 0, onChanged: (v) { notifier.updateBlueBalance(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateBlueBalance(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Vibrance', icon: Icons.flare, value: c.vibrance, min: -1.0, max: 1.0, displayValue: c.vibrance.toStringAsFixed(2), isModified: c.vibrance != 0, onChanged: (v) { notifier.updateVibrance(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateVibrance(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Fade', icon: Icons.blur_linear, value: c.fade, min: 0.0, max: 1.0, displayValue: c.fade.toStringAsFixed(2), isModified: c.fade != 0, onChanged: (v) { notifier.updateFade(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateFade(0); onPreviewChanged(); }),
        ],
      ),
    );
  }
}
