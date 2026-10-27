import 'package:flutter/material.dart';

/// Output aspect ratio presets supported by Auto Reframe.
enum AspectRatioPreset { tiktok9x16, youtube16x9, square1x1, instagram4x5, custom }

extension AspectRatioPresetX on AspectRatioPreset {
  String get label {
    switch (this) {
      case AspectRatioPreset.tiktok9x16:
        return '9:16 TikTok / Reels';
      case AspectRatioPreset.youtube16x9:
        return '16:9 YouTube';
      case AspectRatioPreset.square1x1:
        return '1:1 Square';
      case AspectRatioPreset.instagram4x5:
        return '4:5 Instagram';
      case AspectRatioPreset.custom:
        return 'Custom Ratio';
    }
  }

  String get shortLabel {
    switch (this) {
      case AspectRatioPreset.tiktok9x16:
        return '9:16';
      case AspectRatioPreset.youtube16x9:
        return '16:9';
      case AspectRatioPreset.square1x1:
        return '1:1';
      case AspectRatioPreset.instagram4x5:
        return '4:5';
      case AspectRatioPreset.custom:
        return 'Custom';
    }
  }

  IconData get icon {
    switch (this) {
      case AspectRatioPreset.tiktok9x16:
        return Icons.stay_current_portrait;
      case AspectRatioPreset.youtube16x9:
        return Icons.stay_current_landscape;
      case AspectRatioPreset.square1x1:
        return Icons.crop_square;
      case AspectRatioPreset.instagram4x5:
        return Icons.crop_portrait;
      case AspectRatioPreset.custom:
        return Icons.aspect_ratio;
    }
  }

  /// `width / height` of the preset (custom ratios are resolved on the config).
  double get ratio {
    switch (this) {
      case AspectRatioPreset.tiktok9x16:
        return 9 / 16;
      case AspectRatioPreset.youtube16x9:
        return 16 / 9;
      case AspectRatioPreset.square1x1:
        return 1.0;
      case AspectRatioPreset.instagram4x5:
        return 4 / 5;
      case AspectRatioPreset.custom:
        return 3 / 4;
    }
  }

  /// Default output resolution `(width, height)` around 1080p.
  (int, int) get defaultOutputSize {
    switch (this) {
      case AspectRatioPreset.tiktok9x16:
        return (1080, 1920);
      case AspectRatioPreset.youtube16x9:
        return (1920, 1080);
      case AspectRatioPreset.square1x1:
        return (1080, 1080);
      case AspectRatioPreset.instagram4x5:
        return (1080, 1350);
      case AspectRatioPreset.custom:
        return (1080, 1440);
    }
  }
}

/// How the reframed frame is composed.
enum AutoReframeStyle { smartFaceCrop, blurBackgroundFrame, staticCenterCrop }

extension AutoReframeStyleX on AutoReframeStyle {
  String get label {
    switch (this) {
      case AutoReframeStyle.smartFaceCrop:
        return 'Smart Face Track';
      case AutoReframeStyle.blurBackgroundFrame:
        return 'Blur Background';
      case AutoReframeStyle.staticCenterCrop:
        return 'Center Crop';
    }
  }

  String get description {
    switch (this) {
      case AutoReframeStyle.smartFaceCrop:
        return 'Follows the speaker in 2D (X and Y)';
      case AutoReframeStyle.blurBackgroundFrame:
        return 'Blurred backdrop with the full frame on top';
      case AutoReframeStyle.staticCenterCrop:
        return 'Fixed center crop, no camera motion';
    }
  }
}

/// Camera motion feel, mapped onto the dead-zone radius and EMA smoothness.
enum CameraMotionPreset { steady, balanced, dynamic }

extension CameraMotionPresetX on CameraMotionPreset {
  String get label {
    switch (this) {
      case CameraMotionPreset.steady:
        return 'Steady (No Jitter)';
      case CameraMotionPreset.balanced:
        return 'Balanced';
      case CameraMotionPreset.dynamic:
        return 'Dynamic';
    }
  }

  double get deadZone {
    switch (this) {
      case CameraMotionPreset.steady:
        return 0.08;
      case CameraMotionPreset.balanced:
        return 0.045;
      case CameraMotionPreset.dynamic:
        return 0.02;
    }
  }

  double get smoothness {
    switch (this) {
      case CameraMotionPreset.steady:
        return 0.16;
      case CameraMotionPreset.balanced:
        return 0.28;
      case CameraMotionPreset.dynamic:
        return 0.45;
    }
  }
}

/// Immutable configuration of one Auto Reframe render.
class ReframeConfig {
  final AspectRatioPreset preset;
  final double customWidthRatio;
  final double customHeightRatio;
  final AutoReframeStyle style;
  final CameraMotionPreset motion;

  const ReframeConfig({
    this.preset = AspectRatioPreset.tiktok9x16,
    this.customWidthRatio = 3,
    this.customHeightRatio = 4,
    this.style = AutoReframeStyle.smartFaceCrop,
    this.motion = CameraMotionPreset.balanced,
  });

  ReframeConfig copyWith({
    AspectRatioPreset? preset,
    double? customWidthRatio,
    double? customHeightRatio,
    AutoReframeStyle? style,
    CameraMotionPreset? motion,
  }) {
    return ReframeConfig(
      preset: preset ?? this.preset,
      customWidthRatio: customWidthRatio ?? this.customWidthRatio,
      customHeightRatio: customHeightRatio ?? this.customHeightRatio,
      style: style ?? this.style,
      motion: motion ?? this.motion,
    );
  }

  double get aspectRatio {
    if (preset == AspectRatioPreset.custom) {
      final w = customWidthRatio > 0 ? customWidthRatio : 3.0;
      final h = customHeightRatio > 0 ? customHeightRatio : 4.0;
      return w / h;
    }
    return preset.ratio;
  }

  /// Output resolution in pixels. Custom ratios are scaled around 1080p and
  /// rounded to multiples of 4 so every encoder (including mpeg4) accepts them.
  (int, int) get outputSize {
    if (preset != AspectRatioPreset.custom) return preset.defaultOutputSize;
    return customOutputSize(aspectRatio);
  }

  static (int, int) customOutputSize(double aspectRatio) {
    final aspect = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1.0;
    int width;
    int height;
    if (aspect >= 1) {
      height = 1080;
      width = (height * aspect).round();
    } else {
      width = 1080;
      height = (width / aspect).round();
    }
    return (_roundTo4(width), _roundTo4(height));
  }

  static int _roundTo4(int value) {
    final rounded = (value / 4).round() * 4;
    return rounded < 16 ? 16 : rounded;
  }
}
