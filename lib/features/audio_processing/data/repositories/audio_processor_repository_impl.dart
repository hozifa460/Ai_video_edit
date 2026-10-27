import 'dart:io';
import 'dart:isolate';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/waveform_data.dart';
import '../../domain/repositories/audio_processor_repository.dart';

class AudioProcessorRepositoryImpl implements AudioProcessorRepository {
  @override
  Future<Result<String>> extractAudio(String videoPath) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final audioPath =
          '${tempDir.path}/extracted_audio_${DateTime.now().millisecondsSinceEpoch}.wav';

      final command =
          '-i "$videoPath" -vn -acodec pcm_s16le -ar ${AppConstants.audioSampleRate} -ac ${AppConstants.audioChannels} -y "$audioPath"';

      AppLogger().i('Extracting audio: $command');

      final session = await FFmpegKit.execute(command);

      if (!ReturnCode.isSuccess(await session.getReturnCode())) {
        final logs = await session.getAllLogsAsString();
        AppLogger().e('Audio extraction failed: $logs');
        return AppError(AudioExtractionFailure(message: 'FFmpeg error: $logs'));
      }

      final file = File(audioPath);
      if (!await file.exists()) {
        return AppError(
          AudioExtractionFailure(message: 'Output file not created'),
        );
      }

      return Success(audioPath);
    } catch (e, stack) {
      AppLogger().e('Audio extraction failed', e, stack);
      return AppError(AudioExtractionFailure(message: e.toString()));
    }
  }

  @override
  Future<Result<WaveformData>> analyzeWaveform(String audioPath) async {
    try {
      final waveform = await Isolate.run(() => _analyzeWaveformFile(audioPath));
      if (waveform == null) {
        return AppError(
          AudioExtractionFailure(message: 'Waveform analysis failed'),
        );
      }
      return Success(waveform);
    } catch (e, stack) {
      AppLogger().e('Waveform analysis failed', e, stack);
      return AppError(AudioExtractionFailure(message: e.toString()));
    }
  }
}

WaveformData? _analyzeWaveformFile(String audioPath) {
  final file = File(audioPath);
  if (!file.existsSync()) return null;

  final bytes = file.readAsBytesSync();
  if (bytes.length < 44) return null;

  // Read sample rate from WAV header bytes 24..27 (little-endian uint32).
  final sampleRate = bytes[24] |
      (bytes[25] << 8) |
      (bytes[26] << 16) |
      (bytes[27] << 24);
  final sr = sampleRate > 0 ? sampleRate : AppConstants.audioSampleRate;

  const sampleCount = 2000;

  // PCM data starts after the 44-byte WAV header.
  final pcmBytes = bytes.sublist(44);
  final totalSamples = pcmBytes.length ~/ 2;
  if (totalSamples == 0) return null;

  final durationSeconds = totalSamples / sr;
  final step = (totalSamples / sampleCount).ceil();
  if (step <= 0) return null;

  final samples = <double>[];
  var maxAbs = 0.0;
  var windowSum = 0.0;
  var windowCount = 0;

  void accumulate(int raw) {
    final value = raw.toSigned(16);
    windowSum += (value / 32768.0).abs();
    windowCount++;
    if (windowCount >= step) {
      final avg = windowSum / windowCount;
      samples.add(avg);
      if (avg > maxAbs) maxAbs = avg;
      windowSum = 0;
      windowCount = 0;
    }
  }

  for (var i = 0; i + 1 < pcmBytes.length; i += 2) {
    accumulate(pcmBytes[i] | (pcmBytes[i + 1] << 8));
    if (samples.length >= sampleCount) break;
  }

  if (windowCount > 0 && samples.length < sampleCount) {
    final avg = windowSum / windowCount;
    samples.add(avg);
    if (avg > maxAbs) maxAbs = avg;
  }

  if (maxAbs > 0) {
    for (var i = 0; i < samples.length; i++) {
      samples[i] = samples[i] / maxAbs;
    }
  }

  return WaveformData(
    samples: samples,
    sampleRate: sr.toDouble(),
    durationSeconds: durationSeconds,
  );
}