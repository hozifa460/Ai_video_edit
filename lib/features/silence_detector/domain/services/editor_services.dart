import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/audio_processing/domain/entities/waveform_data.dart';

/// Light service seams so the editor's detection flow can be exercised on host
/// without FFmpeg, a video platform or a device. Production wires the real
/// repositories; tests inject fakes whose completion is controllable.
abstract class MediaProbeService {
  Future<Result<MediaTimeline>> probe(String videoPath);
}

abstract class AudioExtractionService {
  Future<Result<String>> extractAudio(String videoPath);
  Future<Result<WaveformData>> analyzeWaveform(String audioPath);
}

abstract class SilenceDetectionService {
  Future<Result<SilenceRemovalPlan>> detect({
    required String audioPath,
    required DetectionParams params,
    required MediaTimeline timeline,
  });
}

abstract class ProcessingService {
  Future<Result<String>> process({
    required String videoPath,
    required String audioPath,
    required SilenceRemovalPlan plan,
    required DetectionParams params,
  });
}
