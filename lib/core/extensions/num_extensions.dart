extension DoubleExtensions on double {
  double clampTo(double min, double max) {
    if (this < min) return min;
    if (this > max) return max;
    return this;
  }

  String toPercentage() => '${(this * 100).toStringAsFixed(1)}%';

  String toDbString() => '${toStringAsFixed(1)} dB';
}

extension IntExtensions on int {
  String toMsString() => '$this ms';
}
