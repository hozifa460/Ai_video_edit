import 'dart:io';
import 'dart:typed_data';

import 'package:ai_video_editing/features/silence_detector/data/services/vad_service.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:flutter_test/flutter_test.dart';

const _params = DetectionParams(
  silenceThreshold: -40,
  minSilenceDuration: 0.25,
  paddingBefore: 0,
  paddingAfter: 0,
  useVad: true,
  useBreathingProtection: false,
);

/// Builds a canonical PCM16/mono WAV whose [sampleRate] is written into the
/// header, so a hard-coded analysis rate is observable in the boundary times.
Uint8List _wav({required int sampleRate, required List<int> samples}) {
  final dataBytes = samples.length * 2;
  final bytes = Uint8List(44 + dataBytes);
  final data = ByteData.sublistView(bytes);

  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, dataBytes, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return bytes;
}

List<int> _pattern({
  required int sampleRate,
  required double durationSeconds,
  required List<(double, double)> speech,
}) {
  final total = (sampleRate * durationSeconds).round();
  final samples = List<int>.filled(total, 0);
  for (final (start, end) in speech) {
    final first = (start * sampleRate).round();
    final last = (end * sampleRate).round();
    for (var i = first; i < last && i < total; i++) {
      samples[i] = 16000;
    }
  }
  return samples;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vad_service_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeWav({
    required int sampleRate,
    required double durationSeconds,
    required List<(double, double)> speech,
  }) async {
    final file = File('${tempDir.path}/speech_$sampleRate.wav');
    await file.writeAsBytes(
      _wav(
        sampleRate: sampleRate,
        samples: _pattern(
          sampleRate: sampleRate,
          durationSeconds: durationSeconds,
          speech: speech,
        ),
      ),
    );
    return file;
  }

  group('VAD uses the WAV sample rate instead of a hard-coded 16kHz', () {
    for (final sampleRate in [16000, 44100]) {
      test('$sampleRate Hz burst times survive in the split', () async {
        final file = await writeWav(
          sampleRate: sampleRate,
          durationSeconds: 4,
          speech: const [(1.0, 1.4), (2.8, 3.2)],
        );

        final result = await VadService().refineSilence(file.path, const [
          SilenceSegment(startSeconds: 0, endSeconds: 4),
        ], _params);

        expect(result.length, 3);
        expect(result[0].startSeconds, closeTo(0, 1e-9));
        expect(result[0].endSeconds, closeTo(1.0, 1e-9));
        expect(result[1].startSeconds, closeTo(1.4, 1e-9));
        expect(result[1].endSeconds, closeTo(2.8, 1e-9));
        expect(result[2].startSeconds, closeTo(3.2, 1e-9));
        expect(result[2].endSeconds, closeTo(4.0, 1e-9));
      });
    }

    test('a fractional 20ms frame keeps sample-accurate times', () async {
      // 11025 Hz gives 221 samples per 20ms frame, i.e. 20.045ms. Treating
      // every frame as exactly 20ms would drift by ~2.3s over an hour.
      const sampleRate = 11025;
      final frameSamples = (sampleRate * 0.02).round();
      final frameSeconds = frameSamples / sampleRate;
      final speechStart = 1000 * frameSeconds;
      final speechEnd = 1500 * frameSeconds;
      final totalSeconds = 2000 * frameSeconds;

      final file = await writeWav(
        sampleRate: sampleRate,
        durationSeconds: totalSeconds,
        speech: [(speechStart, speechEnd)],
      );

      final result = await VadService().refineSilence(file.path, [
        SilenceSegment(startSeconds: 0, endSeconds: totalSeconds),
      ], _params);

      expect(result.length, 2);
      expect(result[0].startSeconds, closeTo(0, 1e-9));
      expect(result[0].endSeconds, closeTo(speechStart, 1e-9));
      expect(result[1].startSeconds, closeTo(speechEnd, 1e-9));
      expect(result[1].endSeconds, closeTo(totalSeconds, 1e-9));
    });
  });

  group('VAD subtracts speech instead of discarding the whole silence', () {
    test('silent parts before and after a burst are kept', () async {
      final file = await writeWav(
        sampleRate: 44100,
        durationSeconds: 3,
        speech: const [(1.0, 1.4)],
      );

      final result = await VadService().refineSilence(file.path, const [
        SilenceSegment(startSeconds: 0, endSeconds: 3),
      ], _params);

      expect(result.length, 2);
      expect(result[0].endSeconds, closeTo(1.0, 1e-9));
      expect(result[1].startSeconds, closeTo(1.4, 1e-9));
      expect(result[1].endSeconds, closeTo(3.0, 1e-9));
    });

    test('a remaining fragment below minSilenceDuration is dropped', () async {
      final file = await writeWav(
        sampleRate: 44100,
        durationSeconds: 3,
        speech: const [(1.0, 1.4), (1.5, 1.9)],
      );

      final result = await VadService().refineSilence(file.path, const [
        SilenceSegment(startSeconds: 0, endSeconds: 3),
      ], _params);

      // [1.4,1.5] is only 100ms, under the configured 250ms minimum.
      expect(result.length, 2);
      expect(result[0].endSeconds, closeTo(1.0, 1e-9));
      expect(result[1].startSeconds, closeTo(1.9, 1e-9));
    });

    test('a missing file returns the input unchanged', () async {
      const input = [SilenceSegment(startSeconds: 1, endSeconds: 2)];
      final result = await VadService().refineSilence(
        '${tempDir.path}/does_not_exist.wav',
        input,
        _params,
      );

      expect(result, input);
    });
  });
}
