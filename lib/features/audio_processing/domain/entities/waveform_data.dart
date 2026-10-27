import 'package:equatable/equatable.dart';

class WaveformData extends Equatable {
  final List<double> samples;
  final double sampleRate;
  final double durationSeconds;

  const WaveformData({
    required this.samples,
    required this.sampleRate,
    required this.durationSeconds,
  });

  int get totalSamples => samples.length;

  List<double> getDownsampledSamples(int targetCount) {
    if (samples.isEmpty) return [];
    if (targetCount >= samples.length) return samples;

    final result = <double>[];
    final step = samples.length / targetCount;

    for (var i = 0; i < targetCount; i++) {
      final startIdx = (i * step).floor();
      final endIdx = ((i + 1) * step).floor();
      final end = endIdx > samples.length ? samples.length : endIdx;
      final slice = samples.sublist(startIdx, end);
      if (slice.isNotEmpty) {
        result.add(slice.reduce((a, b) => a + b) / slice.length);
      }
    }

    return result;
  }

  double getSampleAtTime(double seconds) {
    if (seconds >= durationSeconds || seconds < 0) return 0;
    final index = ((seconds / durationSeconds) * samples.length).floor();
    if (index >= samples.length) return 0;
    return samples[index];
  }

  @override
  List<Object?> get props => [samples, sampleRate, durationSeconds];
}
