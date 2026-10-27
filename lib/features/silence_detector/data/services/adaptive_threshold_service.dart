import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import '../../../../core/utils/logger.dart';
import '../../domain/entities/detection_params.dart';
import 'wav_pcm_header.dart';

/// Estimates a silence threshold from the first 30 seconds of the analysis WAV.
///
/// The WAV is read and measured in a background isolate: a 30-second PCM window
/// is roughly 1–3 MB, and the nested per-sample loops blocked the UI isolate
/// while "Auto" was running. The actual declared sample rate is parsed from the
/// file header so the analysis window is 30 real seconds even when extraction
/// used a different rate than the application's default.
class AdaptiveThresholdService {
  Future<DetectionParams> analyze({
    required String audioPath,
    required DetectionParams currentParams,
  }) async {
    final file = File(audioPath);
    if (!await file.exists()) return currentParams;

    final estimate = await Isolate.run(() => _analyzeFile(audioPath));
    if (estimate == null) return currentParams;

    final newThreshold = estimate.optimalThreshold;

    AppLogger().i(
      'Adaptive threshold: noiseFloor=${estimate.noiseFloor.toStringAsFixed(1)}, '
      'speechCeiling=${estimate.speechCeiling.toStringAsFixed(1)}, '
      'threshold=${newThreshold.toStringAsFixed(1)}',
    );

    return currentParams.copyWith(
      silenceThreshold: double.parse(newThreshold.toStringAsFixed(1)),
      minSilenceDuration: currentParams.minSilenceDuration > 0.15
          ? currentParams.minSilenceDuration
          : 0.15,
    );
  }
}

class _ThresholdEstimate {
  final double noiseFloor;
  final double speechCeiling;
  final double optimalThreshold;

  const _ThresholdEstimate({
    required this.noiseFloor,
    required this.speechCeiling,
    required this.optimalThreshold,
  });
}

/// Isolate entry point. Returns `null` for any file that cannot be analysed as
/// PCM16, so the caller keeps the user's current parameters.
_ThresholdEstimate? _analyzeFile(String audioPath) {
  final file = File(audioPath);
  final fileLength = file.lengthSync();
  if (fileLength <= 0) return null;

  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    final headerBytes = raf.readSync(65536);
    if (headerBytes.length < 44) return null;

    final header = parseWavPcmHeader(headerBytes);
    if (!header.isPcm16 || header.dataOffset >= fileLength) return null;

    final available = header.dataLength > 0
        ? min(header.dataLength, fileLength - header.dataOffset)
        : fileLength - header.dataOffset;
    if (available < 4) return null;

    final bytesPerSecond = header.sampleRate * header.blockAlign;
    if (bytesPerSecond <= 0) return null;

    const analysisSeconds = 30;
    final readLength = min(analysisSeconds * bytesPerSecond, available);
    if (readLength < 4) return null;

    raf.setPositionSync(header.dataOffset);
    final pcmBytes = raf.readSync(readLength);
    if (pcmBytes.length < 4) return null;

    const frameSamples = 2048;
    final frameBytes = frameSamples * header.blockAlign;
    if (frameBytes <= 0) return null;

    final rmsDbValues = <double>[];
    var offset = 0;
    while (offset + frameBytes <= pcmBytes.length) {
      var sumSq = 0.0;
      var sampleCount = 0;
      for (var frame = 0; frame < frameSamples; frame++) {
        final sampleBase = offset + frame * header.blockAlign;
        for (var channel = 0; channel < header.channels; channel++) {
          final idx = sampleBase + channel * 2;
          if (idx + 1 >= pcmBytes.length) break;
          final sample = (pcmBytes[idx] | (pcmBytes[idx + 1] << 8)).toSigned(
            16,
          );
          final normalized = sample / 32768.0;
          sumSq += normalized * normalized;
          sampleCount++;
        }
      }
      if (sampleCount == 0) break;
      final rms = sqrt(sumSq / sampleCount);
      final db = rms > 0 ? 20 * log(rms) / ln10 : -100.0;
      rmsDbValues.add(db);
      offset += frameBytes;
    }

    if (rmsDbValues.length < 5) return null;

    final sorted = List<double>.from(rmsDbValues)..sort();
    final noiseFloor = sorted[(sorted.length * 0.3).round()];
    final speechCeiling = sorted[(sorted.length * 0.9).round()];
    final dynamicRange = speechCeiling - noiseFloor;

    if (dynamicRange < 5) return null;

    final optimalThreshold = noiseFloor + dynamicRange * 0.3;
    return _ThresholdEstimate(
      noiseFloor: noiseFloor,
      speechCeiling: speechCeiling,
      optimalThreshold: optimalThreshold.clamp(-60.0, -20.0),
    );
  } finally {
    raf?.closeSync();
  }
}
