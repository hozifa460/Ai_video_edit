import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/adjustment_provider.dart';
import 'adjustment_slider.dart';

class EffectsPanel extends ConsumerWidget {
  final VoidCallback onChanged;
  final VoidCallback onPreviewChanged;

  const EffectsPanel({super.key, required this.onChanged, required this.onPreviewChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(adjustmentProvider);
    final notifier = ref.read(adjustmentProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 16, bottom: 8),
          child: Text('Effects', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF9E9EB0))),
        ),
        AdjustmentSlider(label: 'Vignette', icon: Icons.vignette, value: settings.vignette, min: 0, max: 1.0, divisions: 100, displayValue: settings.vignette.toStringAsFixed(2), isModified: settings.vignette != 0, onChanged: (v) { notifier.updateVignette(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateVignette(0); onPreviewChanged(); }),
        AdjustmentSlider(label: 'Noise/Grain', icon: Icons.grain, value: settings.noise, min: 0, max: 1.0, divisions: 100, displayValue: settings.noise.toStringAsFixed(2), isModified: settings.noise != 0, onChanged: (v) { notifier.updateNoise(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateNoise(0); onPreviewChanged(); }),
        AdjustmentSlider(label: 'Denoise', icon: Icons.noise_control_off, value: settings.denoise, min: 0, max: 1.0, divisions: 100, displayValue: settings.denoise.toStringAsFixed(2), isModified: settings.denoise != 0, onChanged: (v) { notifier.updateDenoise(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateDenoise(0); onPreviewChanged(); }),
        AdjustmentSlider(label: 'Lens Distortion', icon: Icons.blur_circular, value: settings.lensDistortion, min: -1.0, max: 1.0, divisions: 100, displayValue: settings.lensDistortion.toStringAsFixed(2), isModified: settings.lensDistortion != 0, onChanged: (v) { notifier.updateLensDistortion(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateLensDistortion(0); onPreviewChanged(); }),
      ],
    );
  }
}
