// Characterization evidence for issues that are STILL OPEN.
//
// These examples pass *because* the reviewed bugs still exist. They are the
// audit record for the issues that were NOT part of OpenCode batch 01, and they
// deliberately live outside `test/` so the ordinary product suite never adopts
// broken behavior as a success criterion.
// Run explicitly:
//   flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart
//
// Converted to correctness regressions in `test/` (batch 01):
//   SR-01 gap filling deleted speech   -> test/silence_interval_algebra_test.dart
//   SR-02 padding expanded deletion    -> test/silence_interval_algebra_test.dart
//   SR-03 overlap inflated statistics  -> test/silence_removal_plan_test.dart
//   SR-05 waveform was the duration     -> test/silence_removal_plan_test.dart
//   SR-19 merge shrank contained ranges -> test/silence_interval_algebra_test.dart
// plus end-to-end pipeline coverage in test/silence_detection_pipeline_test.dart.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ai_video_editing/core/enums/export_quality.dart';
import 'package:ai_video_editing/core/enums/processing_state.dart';
import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/data/services/vad_service.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/features/video_processing/domain/entities/export_params.dart';
import 'package:ai_video_editing/features/video_processing/domain/providers/processing_provider.dart';
import 'package:ai_video_editing/features/video_processing/domain/repositories/video_processor_repository.dart';

void main() {
  test('SR-08 (open, batch C): valid 100ms WAV crashes VAD percentile indexing',
      () async {
    final dir = await Directory.systemTemp.createTemp('silence_audit_');
    try {
      final wav = File('${dir.path}/short.wav');
      // Real RIFF PCM16 mono 16kHz file: 5 frames of 20ms each.
      final data = ByteData(44 + 1600 * 2);
      final bytes = data.buffer.asUint8List();
      void tag(int offset, String value) =>
          bytes.setRange(offset, offset + 4, value.codeUnits);
      tag(0, 'RIFF');
      data.setUint32(4, bytes.length - 8, Endian.little);
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      data.setUint32(16, 16, Endian.little);
      data.setUint16(20, 1, Endian.little);
      data.setUint16(22, 1, Endian.little);
      data.setUint32(24, 16000, Endian.little);
      data.setUint32(28, 32000, Endian.little);
      data.setUint16(32, 2, Endian.little);
      data.setUint16(34, 16, Endian.little);
      tag(36, 'data');
      data.setUint32(40, 3200, Endian.little);
      await wav.writeAsBytes(bytes);
      await expectLater(
        VadService().refineSilence(wav.path, [
          const SilenceSegment(startSeconds: 0, endSeconds: 0.1),
        ], const DetectionParams.defaults()),
        throwsRangeError,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('SR-12 (open, batch B): cancellation is overwritten by late completion',
      () async {
    final fake = _PendingRepository();
    final container = ProviderContainer(
      overrides: [videoProcessorRepositoryProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(processingStateProvider.notifier);
    final pending = notifier.startProcessing(
      videoPath: 'input.mp4',
      audioPath: 'audio.wav',
      plan: SilenceRemovalPlan.build(
        totalDurationSeconds: 10,
        removals: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      ),
      quality: ExportQuality.original,
    );
    notifier.cancel();
    expect(
      container.read(processingStateProvider).state,
      ProcessingState.cancelled,
    );
    fake.completer.complete(const Success<String>('late-output.mp4'));
    await pending;
    expect(
      container.read(processingStateProvider).state,
      ProcessingState.completed,
    );
  });
}

class _PendingRepository implements VideoProcessorRepository {
  final completer = Completer<Result<String>>();
  @override
  Future<Result<String>> processVideo({
    required String videoPath,
    required String audioPath,
    required SilenceRemovalPlan plan,
    required ExportQuality quality,
    SmartZoomConfig? smartZoom,
    required ProcessingProgressCallback onProgress,
  }) => completer.future;

  @override
  Future<Result<ExportParams>> exportVideo({
    required String sourcePath,
    required String outputPath,
    required String format,
    required ExportQuality quality,
    ProcessingProgressCallback? onProgress,
  }) => throw UnimplementedError();
}