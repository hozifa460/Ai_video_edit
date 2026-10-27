import '../../../../core/constants/adjustment_defaults.dart';

class ToneAdjustment {
  final double highlights;
  final double shadows;
  final double whites;
  final double blacks;
  final double midtones;

  const ToneAdjustment({
    this.highlights = AdjustmentDefaults.highlights,
    this.shadows = AdjustmentDefaults.shadows,
    this.whites = AdjustmentDefaults.whites,
    this.blacks = AdjustmentDefaults.blacks,
    this.midtones = AdjustmentDefaults.midtones,
  });

  bool get hasAdjustment =>
      highlights != AdjustmentDefaults.highlights ||
      shadows != AdjustmentDefaults.shadows ||
      whites != AdjustmentDefaults.whites ||
      blacks != AdjustmentDefaults.blacks ||
      midtones != AdjustmentDefaults.midtones;

  ToneAdjustment copyWith({
    double? highlights,
    double? shadows,
    double? whites,
    double? blacks,
    double? midtones,
  }) {
    return ToneAdjustment(
      highlights: highlights ?? this.highlights,
      shadows: shadows ?? this.shadows,
      whites: whites ?? this.whites,
      blacks: blacks ?? this.blacks,
      midtones: midtones ?? this.midtones,
    );
  }

  static const ToneAdjustment defaults = ToneAdjustment();
}
