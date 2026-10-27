import '../../../../core/utils/result.dart';
import '../entities/waveform_data.dart';

abstract class AudioProcessorRepository {
  Future<Result<String>> extractAudio(String videoPath);
  Future<Result<WaveformData>> analyzeWaveform(String audioPath);
}
