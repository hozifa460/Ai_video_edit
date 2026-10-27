import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/adjustment_provider.dart';
import 'adjustment_slider.dart';

class AudioAdjustmentsPanel extends ConsumerWidget {
  final VoidCallback onChanged;
  final VoidCallback onPreviewChanged;

  const AudioAdjustmentsPanel({super.key, required this.onChanged, required this.onPreviewChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(adjustmentProvider);
    final notifier = ref.read(adjustmentProvider.notifier);
    final a = settings.audio;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          AdjustmentSlider(label: 'Volume', icon: Icons.volume_up, value: a.volume, min: 0, max: 5.0, divisions: 100, displayValue: '${(a.volume * 100).toStringAsFixed(0)}%', isModified: a.volume != 1.0, onChanged: (v) { notifier.updateVolume(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateVolume(1.0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Noise Reduction', icon: Icons.noise_control_off, value: a.noiseReduction, min: 0, max: 1.0, divisions: 100, displayValue: '${(a.noiseReduction * 100).toStringAsFixed(0)}%', isModified: a.noiseReduction != 0, onChanged: (v) { notifier.updateNoiseReduction(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateNoiseReduction(0); onPreviewChanged(); }),
          SwitchListTile(title: const Text('Normalize Audio', style: TextStyle(fontSize: 14)), value: a.normalize, activeTrackColor: const Color(0xFF6C63FF), onChanged: (v) { notifier.updateNormalize(v); onPreviewChanged(); }),
          SwitchListTile(title: const Text('Mute', style: TextStyle(fontSize: 14)), value: a.mute, activeTrackColor: const Color(0xFF6C63FF), onChanged: (v) { notifier.updateMute(v); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Bass Boost', icon: Icons.music_note, value: a.bassBoost, min: 0, max: 1.0, divisions: 100, displayValue: a.bassBoost.toStringAsFixed(2), isModified: a.bassBoost != 0, onChanged: (v) { notifier.updateBassBoost(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateBassBoost(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Treble', icon: Icons.tram, value: a.treble, min: 0, max: 1.0, divisions: 100, displayValue: a.treble.toStringAsFixed(2), isModified: a.treble != 0, onChanged: (v) { notifier.updateTreble(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateTreble(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Compressor', icon: Icons.compress, value: a.compressor, min: 0, max: 1.0, divisions: 100, displayValue: a.compressor.toStringAsFixed(2), isModified: a.compressor != 0, onChanged: (v) { notifier.updateCompressor(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateCompressor(0); onPreviewChanged(); }),
          AdjustmentSlider(label: 'Pitch Shift', icon: Icons.music_note, value: a.pitchShift, min: 0.5, max: 2.0, divisions: 150, displayValue: '${a.pitchShift.toStringAsFixed(2)}x', isModified: a.pitchShift != 1.0, onChanged: (v) { notifier.updatePitchShift(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updatePitchShift(1.0); onPreviewChanged(); }),
          if (a.fadeIn > 0 || a.fadeOut > 0) ...[
            AdjustmentSlider(label: 'Audio Fade In', icon: Icons.volume_up, value: a.fadeIn, min: 0, max: 5.0, displayValue: '${a.fadeIn.toStringAsFixed(1)}s', isModified: a.fadeIn != 0, onChanged: (v) { notifier.updateAudioFadeIn(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateAudioFadeIn(0); onPreviewChanged(); }),
            AdjustmentSlider(label: 'Audio Fade Out', icon: Icons.volume_down, value: a.fadeOut, min: 0, max: 5.0, displayValue: '${a.fadeOut.toStringAsFixed(1)}s', isModified: a.fadeOut != 0, onChanged: (v) { notifier.updateAudioFadeOut(v); onChanged(); }, onChangeEnd: (_) => onPreviewChanged(), onReset: () { notifier.updateAudioFadeOut(0); onPreviewChanged(); }),
          ],
        ],
      ),
    );
  }
}
