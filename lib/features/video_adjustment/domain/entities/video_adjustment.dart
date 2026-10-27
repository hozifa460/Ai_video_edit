import '../../../../core/constants/adjustment_defaults.dart';

class VideoAdjustment {
  final double rotate;
  final int flipHorizontal;
  final int flipVertical;
  final double cropX;
  final double cropY;
  final double cropWidth;
  final double cropHeight;
  final double scaleWidth;
  final double scaleHeight;
  final double speed;
  final double fadeIn;
  final double fadeOut;
  final bool reverse;

  const VideoAdjustment({
    this.rotate = AdjustmentDefaults.rotate,
    this.flipHorizontal = AdjustmentDefaults.flipHorizontal,
    this.flipVertical = AdjustmentDefaults.flipVertical,
    this.cropX = AdjustmentDefaults.cropX,
    this.cropY = AdjustmentDefaults.cropY,
    this.cropWidth = AdjustmentDefaults.cropWidth,
    this.cropHeight = AdjustmentDefaults.cropHeight,
    this.scaleWidth = AdjustmentDefaults.scaleWidth,
    this.scaleHeight = AdjustmentDefaults.scaleHeight,
    this.speed = AdjustmentDefaults.speed,
    this.fadeIn = AdjustmentDefaults.fadeIn,
    this.fadeOut = AdjustmentDefaults.fadeOut,
    this.reverse = false,
  });

  bool get hasAdjustment =>
      rotate != AdjustmentDefaults.rotate ||
      flipHorizontal != AdjustmentDefaults.flipHorizontal ||
      flipVertical != AdjustmentDefaults.flipVertical ||
      cropWidth != AdjustmentDefaults.cropWidth ||
      cropHeight != AdjustmentDefaults.cropHeight ||
      scaleWidth != AdjustmentDefaults.scaleWidth ||
      scaleHeight != AdjustmentDefaults.scaleHeight ||
      speed != AdjustmentDefaults.speed ||
      fadeIn != AdjustmentDefaults.fadeIn ||
      fadeOut != AdjustmentDefaults.fadeOut ||
      reverse;

  VideoAdjustment copyWith({
    double? rotate,
    int? flipHorizontal,
    int? flipVertical,
    double? cropX,
    double? cropY,
    double? cropWidth,
    double? cropHeight,
    double? scaleWidth,
    double? scaleHeight,
    double? speed,
    double? fadeIn,
    double? fadeOut,
    bool? reverse,
  }) {
    return VideoAdjustment(
      rotate: rotate ?? this.rotate,
      flipHorizontal: flipHorizontal ?? this.flipHorizontal,
      flipVertical: flipVertical ?? this.flipVertical,
      cropX: cropX ?? this.cropX,
      cropY: cropY ?? this.cropY,
      cropWidth: cropWidth ?? this.cropWidth,
      cropHeight: cropHeight ?? this.cropHeight,
      scaleWidth: scaleWidth ?? this.scaleWidth,
      scaleHeight: scaleHeight ?? this.scaleHeight,
      speed: speed ?? this.speed,
      fadeIn: fadeIn ?? this.fadeIn,
      fadeOut: fadeOut ?? this.fadeOut,
      reverse: reverse ?? this.reverse,
    );
  }

  static const VideoAdjustment defaults = VideoAdjustment();
}
