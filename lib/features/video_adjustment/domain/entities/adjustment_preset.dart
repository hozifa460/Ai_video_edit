import 'adjustment_settings.dart';
import 'color_adjustment.dart';
import 'tone_adjustment.dart';

class AdjustmentPreset {
  final String name;
  final String iconAsset;
  final AdjustmentSettings settings;

  const AdjustmentPreset({
    required this.name,
    this.iconAsset = '',
    required this.settings,
  });

  static final List<AdjustmentPreset> builtinPresets = [
    AdjustmentPreset(
      name: 'Normal',
      settings: const AdjustmentSettings(),
    ),
    AdjustmentPreset(
      name: 'Black & White',
      settings: const AdjustmentSettings(saturation: 0.0, presetName: 'Black & White'),
    ),
    AdjustmentPreset(
      name: 'Sepia',
      settings: AdjustmentSettings(
        saturation: 0.6,
        color: const ColorAdjustment(temperature: 25.0, fade: 0.3),
        presetName: 'Sepia',
      ),
    ),
    AdjustmentPreset(
      name: 'Vintage',
      settings: AdjustmentSettings(
        contrast: 0.85,
        saturation: 0.5,
        vignette: 0.3,
        tone: const ToneAdjustment(highlights: -0.2, shadows: 0.15),
        presetName: 'Vintage',
      ),
    ),
    AdjustmentPreset(
      name: 'Cinematic',
      settings: AdjustmentSettings(
        contrast: 1.3,
        saturation: 0.7,
        gamma: 0.9,
        tone: const ToneAdjustment(highlights: -0.15, shadows: 0.2, blacks: 0.1),
        color: const ColorAdjustment(temperature: -5.0, tint: 3.0),
        presetName: 'Cinematic',
      ),
    ),
    AdjustmentPreset(
      name: 'Faded Film',
      settings: AdjustmentSettings(
        contrast: 0.8,
        saturation: 0.5,
        color: const ColorAdjustment(fade: 0.25, temperature: 5.0),
        presetName: 'Faded Film',
      ),
    ),
    AdjustmentPreset(
      name: 'Cool Tone',
      settings: AdjustmentSettings(
        color: const ColorAdjustment(temperature: -20.0, blueBalance: 0.1, redBalance: -0.05),
        presetName: 'Cool Tone',
      ),
    ),
    AdjustmentPreset(
      name: 'Warm Tone',
      settings: AdjustmentSettings(
        color: const ColorAdjustment(temperature: 25.0, redBalance: 0.1, blueBalance: -0.05),
        presetName: 'Warm Tone',
      ),
    ),
    AdjustmentPreset(
      name: 'Dramatic',
      settings: AdjustmentSettings(
        contrast: 1.5,
        saturation: 1.2,
        sharpness: 0.5,
        vignette: 0.4,
        tone: const ToneAdjustment(shadows: -0.1, blacks: 0.05),
        presetName: 'Dramatic',
      ),
    ),
    AdjustmentPreset(
      name: 'Soft',
      settings: AdjustmentSettings(
        contrast: 0.85,
        saturation: 0.85,
        sharpness: -0.3,
        blur: 0.3,
        presetName: 'Soft',
      ),
    ),
    AdjustmentPreset(
      name: 'Vibrant',
      settings: AdjustmentSettings(
        saturation: 1.4,
        contrast: 1.15,
        color: const ColorAdjustment(vibrance: 0.3),
        presetName: 'Vibrant',
      ),
    ),
    AdjustmentPreset(
      name: 'Noir',
      settings: AdjustmentSettings(
        saturation: 0.0,
        contrast: 1.4,
        brightness: -0.05,
        tone: const ToneAdjustment(highlights: -0.1, shadows: 0.2),
        presetName: 'Noir',
      ),
    ),
  ];
}
