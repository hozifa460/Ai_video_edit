import '../../../../core/constants/adjustment_defaults.dart';

class AudioAdjustment {
  final double volume;
  final double noiseReduction;
  final bool normalize;
  final double fadeIn;
  final double fadeOut;
  final double bassBoost;
  final double treble;
  final double compressor;
  final bool mute;
  final double pitchShift;

  const AudioAdjustment({
    this.volume = AdjustmentDefaults.volume,
    this.noiseReduction = AdjustmentDefaults.noiseReduction,
    this.normalize = false,
    this.fadeIn = AdjustmentDefaults.fadeIn,
    this.fadeOut = AdjustmentDefaults.fadeOut,
    this.bassBoost = AdjustmentDefaults.bassBoost,
    this.treble = AdjustmentDefaults.treble,
    this.compressor = AdjustmentDefaults.compressor,
    this.mute = AdjustmentDefaults.mute,
    this.pitchShift = AdjustmentDefaults.pitchShift,
  });

  bool get hasAdjustment =>
      volume != AdjustmentDefaults.volume ||
      noiseReduction != AdjustmentDefaults.noiseReduction ||
      normalize ||
      fadeIn != AdjustmentDefaults.fadeIn ||
      fadeOut != AdjustmentDefaults.fadeOut ||
      bassBoost != AdjustmentDefaults.bassBoost ||
      treble != AdjustmentDefaults.treble ||
      compressor != AdjustmentDefaults.compressor ||
      mute != AdjustmentDefaults.mute ||
      pitchShift != AdjustmentDefaults.pitchShift;

  AudioAdjustment copyWith({
    double? volume,
    double? noiseReduction,
    bool? normalize,
    double? fadeIn,
    double? fadeOut,
    double? bassBoost,
    double? treble,
    double? compressor,
    bool? mute,
    double? pitchShift,
  }) {
    return AudioAdjustment(
      volume: volume ?? this.volume,
      noiseReduction: noiseReduction ?? this.noiseReduction,
      normalize: normalize ?? this.normalize,
      fadeIn: fadeIn ?? this.fadeIn,
      fadeOut: fadeOut ?? this.fadeOut,
      bassBoost: bassBoost ?? this.bassBoost,
      treble: treble ?? this.treble,
      compressor: compressor ?? this.compressor,
      mute: mute ?? this.mute,
      pitchShift: pitchShift ?? this.pitchShift,
    );
  }

  static const AudioAdjustment defaults = AudioAdjustment();
}
