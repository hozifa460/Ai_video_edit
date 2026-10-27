import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../../../../core/utils/logger.dart';
import '../../domain/entities/detection_params.dart';
import '../../domain/entities/silence_segment.dart';
import 'wav_pcm_header.dart';

/// Energy-based voice activity detector for the extracted analysis WAV.
///
/// This is not a learned VAD: it computes short-frame RMS energy, derives a
/// threshold from the recording's own histogram, and treats frames above it as
/// speech. The important safety rule is that a speech burst **subtracts** from
/// a detected silence instead of deleting the whole silence around it, so the
/// silent portions before and after a breath/word burst are still removed when
/// they are long enough.
class VadService {
  static const int _frameMs = 20;

  /// Refines [silenceSegments] using speech activity in [audioPath].
  ///
  /// All file reading, WAV parsing, PCM decoding and energy computation happen
  /// in a background isolate. Doing that work on the UI isolate blocked frames
  /// on multi-minute recordings. If the file is missing or cannot be read as
  /// PCM16, the input is returned unchanged.
  Future<List<SilenceSegment>> refineSilence(
    String audioPath,
    List<SilenceSegment> silenceSegments,
    DetectionParams params,
  ) async {
    if (silenceSegments.isEmpty) return silenceSegments;

    final file = File(audioPath);
    if (!await file.exists()) return silenceSegments;

    final minimum =
        params.minSilenceDuration.isFinite && params.minSilenceDuration > 0
        ? params.minSilenceDuration
        : 0.0;

    final refined = await Isolate.run(
      () => _refineInIsolate(audioPath, silenceSegments, minimum),
    );

    AppLogger().i(
      'VAD: ${silenceSegments.length} segments refined to '
      '${refined.length} after speech splitting',
    );
    return refined;
  }
}

/// Isolate entry point: reads the WAV, classifies speech frames and splits the
/// silence intervals around every overlapping speech burst.
List<SilenceSegment> _refineInIsolate(
  String audioPath,
  List<SilenceSegment> silenceSegments,
  double minSilenceDuration,
) {
  final bytes = File(audioPath).readAsBytesSync();
  if (bytes.length < 44) return silenceSegments;

  final header = parseWavPcmHeader(bytes);
  if (!header.isPcm16 || header.dataOffset >= bytes.length) {
    return silenceSegments;
  }

  final dataEnd = min(bytes.length, header.dataOffset + header.dataLength);
  if (dataEnd - header.dataOffset < 4) return silenceSegments;

  final pcmBytes = Uint8List.sublistView(bytes, header.dataOffset, dataEnd);
  final sampleRate = header.sampleRate;
  final frameSamples = (sampleRate * VadService._frameMs / 1000).round();
  final frameBytes = frameSamples * header.blockAlign;
  if (frameSamples <= 0 || frameBytes <= 0) return silenceSegments;

  // Frame boundaries are sample counts, so their real duration is
  // `frameSamples / sampleRate`, not always exactly 20ms. Rates that do not
  // divide 50Hz (e.g. 11025) would otherwise drift by seconds on a long file.
  final frameSeconds = frameSamples / sampleRate;

  final totalFrames = pcmBytes.length ~/ frameBytes;
  if (totalFrames == 0) return silenceSegments;

  final energies = List.filled(totalFrames, 0.0);
  for (var i = 0; i < totalFrames; i++) {
    var sumSq = 0.0;
    var sampleCount = 0;
    final frameBase = i * frameBytes;
    for (var frame = 0; frame < frameSamples; frame++) {
      final sampleBase = frameBase + frame * header.blockAlign;
      for (var channel = 0; channel < header.channels; channel++) {
        final idx = sampleBase + channel * 2;
        if (idx + 1 >= pcmBytes.length) break;
        final sample = (pcmBytes[idx] | (pcmBytes[idx + 1] << 8)).toSigned(16);
        final normalized = sample / 32768.0;
        sumSq += normalized * normalized;
        sampleCount++;
      }
    }
    energies[i] = sampleCount == 0 ? 0.0 : sumSq / sampleCount;
  }

  // The quantile policy is kept as it was (SR-08 is a separate open finding);
  // this refactor only changes where the computation runs and how overlaps are
  // applied.
  final sorted = List<double>.from(energies)..sort();
  final noiseFloor = sorted[(sorted.length * 0.25).round()];
  final speechCeiling = sorted[(sorted.length * 0.90).round()];
  final threshold = noiseFloor + (speechCeiling - noiseFloor) * 0.25;

  final isSpeech = energies.map((e) => e > threshold).toList();

  final speechSegments = <SilenceSegment>[];
  var startIdx = -1;
  for (var i = 0; i < totalFrames; i++) {
    if (isSpeech[i] && startIdx == -1) {
      startIdx = i;
    } else if (!isSpeech[i] && startIdx != -1) {
      final startSec = startIdx * frameSeconds;
      final endSec = i * frameSeconds;
      if (endSec - startSec >= 0.05) {
        speechSegments.add(
          SilenceSegment(startSeconds: startSec, endSeconds: endSec),
        );
      }
      startIdx = -1;
    }
  }
  if (startIdx != -1) {
    speechSegments.add(
      SilenceSegment(
        startSeconds: startIdx * frameSeconds,
        endSeconds: totalFrames * frameSeconds,
      ),
    );
  }

  return _splitAroundSpeech(
    silenceSegments,
    speechSegments,
    minSilenceDuration,
  );
}

/// Subtracts every [speech] burst from [silences].
///
/// A burst inside a long silence yields up to two remaining silence intervals,
/// one before and one after it. Only pieces at least [minSilenceDuration] long
/// are kept; a shorter leftover is a fragment of a real pause, not a useful
/// cut.
List<SilenceSegment> _splitAroundSpeech(
  List<SilenceSegment> silences,
  List<SilenceSegment> speech,
  double minSilenceDuration,
) {
  final bursts = speech.where((s) => s.isValid).toList()
    ..sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
  if (bursts.isEmpty) return silences;

  final minimum = minSilenceDuration.isFinite && minSilenceDuration > 0
      ? minSilenceDuration
      : 0.0;
  final refined = <SilenceSegment>[];

  for (final silence in silences) {
    if (!silence.isValid) continue;
    var cursor = silence.startSeconds;

    for (final burst in bursts) {
      if (burst.endSeconds <= cursor) continue;
      if (burst.startSeconds >= silence.endSeconds) break;

      final overlapStart = burst.startSeconds > cursor
          ? burst.startSeconds
          : cursor;
      if (overlapStart > cursor) {
        _addIfLongEnough(refined, cursor, overlapStart, minimum);
      }

      final overlapEnd = burst.endSeconds < silence.endSeconds
          ? burst.endSeconds
          : silence.endSeconds;
      if (overlapEnd > cursor) cursor = overlapEnd;
      if (cursor >= silence.endSeconds) break;
    }

    if (cursor < silence.endSeconds) {
      _addIfLongEnough(refined, cursor, silence.endSeconds, minimum);
    }
  }

  return refined;
}

void _addIfLongEnough(
  List<SilenceSegment> target,
  double start,
  double end,
  double minimum,
) {
  if (!start.isFinite || !end.isFinite || end <= start) return;
  if (end - start < minimum) return;
  target.add(SilenceSegment(startSeconds: start, endSeconds: end));
}
