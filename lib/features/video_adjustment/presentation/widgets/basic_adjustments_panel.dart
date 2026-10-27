import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/adjustment_provider.dart';
import 'adjustment_slider.dart';

class BasicAdjustmentsPanel extends ConsumerWidget {
  final VoidCallback onChanged;
  final VoidCallback onPreviewChanged;

  const BasicAdjustmentsPanel({super.key, required this.onChanged, required this.onPreviewChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(adjustmentProvider);
    final notifier = ref.read(adjustmentProvider.notifier);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          AdjustmentSlider(
            label: 'Brightness', icon: Icons.brightness_6,
            value: settings.brightness, min: -1.0, max: 1.0,
            displayValue: settings.brightness.toStringAsFixed(2),
            isModified: settings.brightness != 0,
            onChanged: (v) { notifier.updateBrightness(v); onChanged(); },
            onChangeEnd: (_) => onPreviewChanged(),
            onReset: () { notifier.updateBrightness(0); onPreviewChanged(); },
          ),
          AdjustmentSlider(
            label: 'Contrast', icon: Icons.contrast,
            value: settings.contrast, min: 0.0, max: 3.0,
            displayValue: '${settings.contrast.toStringAsFixed(2)}x',
            isModified: settings.contrast != 1.0,
            onChanged: (v) { notifier.updateContrast(v); onChanged(); },
            onChangeEnd: (_) => onPreviewChanged(),
            onReset: () { notifier.updateContrast(1.0); onPreviewChanged(); },
          ),
          AdjustmentSlider(
            label: 'Saturation', icon: Icons.color_lens,
            value: settings.saturation, min: 0.0, max: 3.0,
            displayValue: '${settings.saturation.toStringAsFixed(2)}x',
            isModified: settings.saturation != 1.0,
            onChanged: (v) { notifier.updateSaturation(v); onChanged(); },
            onChangeEnd: (_) => onPreviewChanged(),
            onReset: () { notifier.updateSaturation(1.0); onPreviewChanged(); },
          ),
          AdjustmentSlider(
            label: 'Exposure', icon: Icons.exposure,
            value: settings.exposure, min: -2.0, max: 2.0,
            displayValue: settings.exposure.toStringAsFixed(2),
            isModified: settings.exposure != 0,
            onChanged: (v) { notifier.updateExposure(v); onChanged(); },
            onChangeEnd: (_) => onPreviewChanged(),
            onReset: () { notifier.updateExposure(0); onPreviewChanged(); },
          ),
          AdjustmentSlider(
            label: 'Gamma', icon: Icons.tonality,
            value: settings.gamma, min: 0.1, max: 3.0,
            displayValue: settings.gamma.toStringAsFixed(2),
            isModified: settings.gamma != 1.0,
            onChanged: (v) { notifier.updateGamma(v); onChanged(); },
            onChangeEnd: (_) => onPreviewChanged(),
            onReset: () { notifier.updateGamma(1.0); onPreviewChanged(); },
          ),
          AdjustmentSlider(
            label: 'Hue', icon: Icons.colorize,
            value: settings.hue, min: -180, max: 180,
            displayValue: '${settings.hue.toStringAsFixed(0)}°',
            isModified: settings.hue != 0,
            onChanged: (v) { notifier.updateHue(v); onChanged(); },
            onChangeEnd: (_) => onPreviewChanged(),
            onReset: () { notifier.updateHue(0); onPreviewChanged(); },
          ),
          AdjustmentSlider(
            label: 'Sharpness', icon: Icons.blur_on,
            value: settings.sharpness, min: 0.0, max: 5.0,
            displayValue: settings.sharpness.toStringAsFixed(1),
            isModified: settings.sharpness != 0,
            onChanged: (v) { notifier.updateSharpness(v); onChanged(); },
            onChangeEnd: (_) => onPreviewChanged(),
            onReset: () { notifier.updateSharpness(0); onPreviewChanged(); },
          ),
          AdjustmentSlider(
            label: 'Blur', icon: Icons.blur_circular,
            value: settings.blur, min: 0.0, max: 10.0,
            displayValue: settings.blur.toStringAsFixed(1),
            isModified: settings.blur != 0,
            onChanged: (v) { notifier.updateBlur(v); onChanged(); },
            onChangeEnd: (_) => onPreviewChanged(),
            onReset: () { notifier.updateBlur(0); onPreviewChanged(); },
          ),
        ],
      ),
    );
  }
}
