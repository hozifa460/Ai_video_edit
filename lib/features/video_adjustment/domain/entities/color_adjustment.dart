import '../../../../core/constants/adjustment_defaults.dart';

class ColorAdjustment {
  final double temperature;
  final double tint;
  final double redBalance;
  final double greenBalance;
  final double blueBalance;
  final double vibrance;
  final double fade;

  const ColorAdjustment({
    this.temperature = AdjustmentDefaults.temperature,
    this.tint = AdjustmentDefaults.tint,
    this.redBalance = AdjustmentDefaults.colorBalanceRed,
    this.greenBalance = AdjustmentDefaults.colorBalanceGreen,
    this.blueBalance = AdjustmentDefaults.colorBalanceBlue,
    this.vibrance = AdjustmentDefaults.vibrance,
    this.fade = AdjustmentDefaults.fade,
  });

  bool get hasAdjustment =>
      temperature != AdjustmentDefaults.temperature ||
      tint != AdjustmentDefaults.tint ||
      redBalance != AdjustmentDefaults.colorBalanceRed ||
      greenBalance != AdjustmentDefaults.colorBalanceGreen ||
      blueBalance != AdjustmentDefaults.colorBalanceBlue ||
      vibrance != AdjustmentDefaults.vibrance ||
      fade != AdjustmentDefaults.fade;

  ColorAdjustment copyWith({
    double? temperature,
    double? tint,
    double? redBalance,
    double? greenBalance,
    double? blueBalance,
    double? vibrance,
    double? fade,
  }) {
    return ColorAdjustment(
      temperature: temperature ?? this.temperature,
      tint: tint ?? this.tint,
      redBalance: redBalance ?? this.redBalance,
      greenBalance: greenBalance ?? this.greenBalance,
      blueBalance: blueBalance ?? this.blueBalance,
      vibrance: vibrance ?? this.vibrance,
      fade: fade ?? this.fade,
    );
  }

  static const ColorAdjustment defaults = ColorAdjustment();
}
