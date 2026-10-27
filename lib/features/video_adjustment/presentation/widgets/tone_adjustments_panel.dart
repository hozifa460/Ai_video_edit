import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/adjustment_provider.dart';
import 'adjustment_slider.dart';

class ToneAdjustmentsPanel extends ConsumerWidget {
  final VoidCallback onChanged;
  final VoidCallback onPreviewChanged;

  const ToneAdjustmentsPanel({super.key, required this.onChanged, required this.onPreviewChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(adjustmentProvider);
    final notifier = ref.read(adjustmentProvider.notifier);
    final t = settings.tone;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          AdjustmentSlider(label: 'Highlights', icon: Icons.brightness_high, value: t.highlights, min: -1.0, max: 1.0, displayValue: t.highlights.toStringAsFixed(2), isModified: t.highlights != 0, onChanged: (v) { notifier.updateHighlights(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateHighlights(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Shadows', icon: Icons.brightness_low, value: t.shadows, min: -1.0, max: 1.0, displayValue: t.shadows.toStringAsFixed(2), isModified: t.shadows != 0, onChanged: (v) { notifier.updateShadows(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateShadows(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Whites', icon: Icons.light, value: t.whites, min: -1.0, max: 1.0, displayValue: t.whites.toStringAsFixed(2), isModified: t.whites != 0, onChanged: (v) { notifier.updateWhites(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateWhites(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Blacks', icon: Icons.dark_mode, value: t.blacks, min: -1.0, max: 1.0, displayValue: t.blacks.toStringAsFixed(2), isModified: t.blacks != 0, onChanged: (v) { notifier.updateBlacks(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateBlacks(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Midtones', icon: Icons.equalizer, value: t.midtones, min: -1.0, max: 1.0, displayValue: t.midtones.toStringAsFixed(2), isModified: t.midtones != 0, onChanged: (v) { notifier.updateMidtones(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateMidtones(0); onPreviewChanged(); }),
        ],
      ),
    );
  }
}
