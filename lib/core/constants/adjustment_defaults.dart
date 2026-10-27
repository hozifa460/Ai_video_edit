import '../utils/logger.dart';

class AdjustmentDefaults {
  AdjustmentDefaults._();

  static const double brightness = 0.0;
  static const double contrast = 1.0;
  static const double saturation = 1.0;
  static const double exposure = 0.0;
  static const double gamma = 1.0;
  static const double hue = 0.0;
  static const double sharpness = 0.0;
  static const double blur = 0.0;

  static const double highlights = 0.0;
  static const double shadows = 0.0;
  static const double whites = 0.0;
  static const double blacks = 0.0;
  static const double midtones = 0.0;

  static const double temperature = 0.0;
  static const double tint = 0.0;
  static const double colorBalanceRed = 0.0;
  static const double colorBalanceGreen = 0.0;
  static const double colorBalanceBlue = 0.0;
  static const double vibrance = 0.0;
  static const double fade = 0.0;

  static const double vignette = 0.0;
  static const double noise = 0.0;
  static const double denoise = 0.0;
  static const double lensDistortion = 0.0;

  static const double rotate = 0.0;
  static const int flipHorizontal = 0;
  static const int flipVertical = 0;
  static const double cropX = 0.0;
  static const double cropY = 0.0;
  static const double cropWidth = 1.0;
  static const double cropHeight = 1.0;
  static const double scaleWidth = 1.0;
  static const double scaleHeight = 1.0;
  static const double speed = 1.0;
  static const double fadeIn = 0.0;
  static const double fadeOut = 0.0;

  static const double volume = 1.0;
  static const double noiseReduction = 0.0;
  static const double bassBoost = 0.0;
  static const double treble = 0.0;
  static const double compressor = 0.0;
  static const double pitchShift = 1.0;
  static const bool mute = false;

  static bool isDefault(String key, double value) {
    final map = {
      'brightness': brightness,
      'contrast': contrast,
      'saturation': saturation,
      'exposure': exposure,
      'gamma': gamma,
      'hue': hue,
      'sharpness': sharpness,
      'blur': blur,
      'highlights': highlights,
      'shadows': shadows,
      'whites': whites,
      'blacks': blacks,
      'midtones': midtones,
      'temperature': temperature,
      'tint': tint,
      'colorBalanceRed': colorBalanceRed,
      'colorBalanceGreen': colorBalanceGreen,
      'colorBalanceBlue': colorBalanceBlue,
      'vibrance': vibrance,
      'fade': fade,
      'vignette': vignette,
      'noise': noise,
      'denoise': denoise,
      'lensDistortion': lensDistortion,
      'rotate': rotate,
      'speed': speed,
      'volume': volume,
      'noiseReduction': noiseReduction,
      'bassBoost': bassBoost,
      'treble': treble,
      'compressor': compressor,
      'pitchShift': pitchShift,
    };
    if (key == 'flipHorizontal' || key == 'flipVertical') return value == 0;
    if (key == 'mute') return value == 0;
    return map[key]?.compareTo(value) == 0;
  }

  static void logDefaults() {
    AppLogger().d('AdjustmentDefaults loaded');
  }
}
