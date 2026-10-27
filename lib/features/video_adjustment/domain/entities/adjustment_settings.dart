import '../../../../core/constants/adjustment_defaults.dart';
import 'color_adjustment.dart';
import 'tone_adjustment.dart';
import 'video_adjustment.dart';
import 'audio_adjustment.dart';

class AdjustmentSettings {
  final double brightness;
  final double contrast;
  final double saturation;
  final double exposure;
  final double gamma;
  final double hue;
  final double sharpness;
  final double blur;

  final ToneAdjustment tone;
  final ColorAdjustment color;
  final VideoAdjustment video;
  final AudioAdjustment audio;

  final double vignette;
  final double noise;
  final double denoise;
  final double lensDistortion;

  final String? lutPath;
  final String? presetName;

  const AdjustmentSettings({
    this.brightness = AdjustmentDefaults.brightness,
    this.contrast = AdjustmentDefaults.contrast,
    this.saturation = AdjustmentDefaults.saturation,
    this.exposure = AdjustmentDefaults.exposure,
    this.gamma = AdjustmentDefaults.gamma,
    this.hue = AdjustmentDefaults.hue,
    this.sharpness = AdjustmentDefaults.sharpness,
    this.blur = AdjustmentDefaults.blur,
    this.tone = const ToneAdjustment(),
    this.color = const ColorAdjustment(),
    this.video = const VideoAdjustment(),
    this.audio = const AudioAdjustment(),
    this.vignette = AdjustmentDefaults.vignette,
    this.noise = AdjustmentDefaults.noise,
    this.denoise = AdjustmentDefaults.denoise,
    this.lensDistortion = AdjustmentDefaults.lensDistortion,
    this.lutPath,
    this.presetName,
  });

  bool get hasAnyAdjustment =>
      brightness != AdjustmentDefaults.brightness ||
      contrast != AdjustmentDefaults.contrast ||
      saturation != AdjustmentDefaults.saturation ||
      exposure != AdjustmentDefaults.exposure ||
      gamma != AdjustmentDefaults.gamma ||
      hue != AdjustmentDefaults.hue ||
      sharpness != AdjustmentDefaults.sharpness ||
      blur != AdjustmentDefaults.blur ||
      vignette != AdjustmentDefaults.vignette ||
      noise != AdjustmentDefaults.noise ||
      denoise != AdjustmentDefaults.denoise ||
      lensDistortion != AdjustmentDefaults.lensDistortion ||
      tone.hasAdjustment ||
      color.hasAdjustment ||
      video.hasAdjustment ||
      audio.hasAdjustment ||
      lutPath != null;

  AdjustmentSettings copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? exposure,
    double? gamma,
    double? hue,
    double? sharpness,
    double? blur,
    ToneAdjustment? tone,
    ColorAdjustment? color,
    VideoAdjustment? video,
    AudioAdjustment? audio,
    double? vignette,
    double? noise,
    double? denoise,
    double? lensDistortion,
    String? lutPath,
    String? presetName,
    bool clearLut = false,
  }) {
    return AdjustmentSettings(
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      exposure: exposure ?? this.exposure,
      gamma: gamma ?? this.gamma,
      hue: hue ?? this.hue,
      sharpness: sharpness ?? this.sharpness,
      blur: blur ?? this.blur,
      tone: tone ?? this.tone,
      color: color ?? this.color,
      video: video ?? this.video,
      audio: audio ?? this.audio,
      vignette: vignette ?? this.vignette,
      noise: noise ?? this.noise,
      denoise: denoise ?? this.denoise,
      lensDistortion: lensDistortion ?? this.lensDistortion,
      lutPath: clearLut ? null : (lutPath ?? this.lutPath),
      presetName: presetName ?? this.presetName,
    );
  }

  static const AdjustmentSettings defaults = AdjustmentSettings();
}
