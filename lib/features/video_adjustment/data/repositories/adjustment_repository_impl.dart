import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';

import '../../../../core/utils/filter_chain_builder.dart';
import '../../domain/entities/adjustment_settings.dart';
import '../../domain/repositories/adjustment_repository.dart';
import '../datasources/ffmpeg_adjustment_datasource.dart';

class AdjustmentRepositoryImpl implements AdjustmentRepository {
  final FfmpegAdjustmentDatasource _datasource;

  AdjustmentRepositoryImpl(this._datasource);

  /// Probes the input for an audio stream so exports of silent videos do not
  /// hard-fail on a [0:a] filter mapping. Defaults to true on probe failure.
  Future<bool> _hasAudioStream(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return true;
      return info.getStreams().any((s) => s.getType() == 'audio');
    } catch (_) {
      return true;
    }
  }

  @override
  Future<String> buildFilterChain(AdjustmentSettings settings) {
    final builder = FilterChainBuilder(settings);
    final result = builder.build();
    return Future.value(result ?? '');
  }

  @override
  Future<void> applyAdjustments({
    required String inputPath,
    required String outputPath,
    required AdjustmentSettings settings,
    required void Function(double) onProgress,
    bool isPreview = false,
  }) async {
    final hasAudio = await _hasAudioStream(inputPath);
    final builder = FilterChainBuilder(settings);
    final filterString = builder.build(hasAudio: hasAudio) ?? '';

    if (filterString.isEmpty) {
      await _datasource.applyAdjustments(
        inputPath: inputPath,
        outputPath: outputPath,
        filterString: '-c:v copy -c:a copy',
        onProgress: onProgress,
        isPreview: isPreview,
      );
      return;
    }

    await _datasource.applyAdjustments(
      inputPath: inputPath,
      outputPath: outputPath,
      filterString: filterString,
      onProgress: onProgress,
      isPreview: isPreview,
    );
  }

  @override
  Future<String> extractPreviewFrame({
    required String inputPath,
    required AdjustmentSettings settings,
  }) async {
    final builder = FilterChainBuilder(settings);
    final vf = builder.buildPreview();
    return _datasource.extractPreviewFrame(inputPath, vf);
  }

  @override
  Future<void> exportVideo({
    required String inputPath,
    required String outputPath,
    required AdjustmentSettings settings,
    required String quality,
    required void Function(double) onProgress,
  }) async {
    final hasAudio = await _hasAudioStream(inputPath);
    final builder = FilterChainBuilder(settings);
    final filterString = builder.build(hasAudio: hasAudio) ?? '';
    await _datasource.exportVideo(
      inputPath: inputPath,
      outputPath: outputPath,
      filterString: filterString,
      quality: quality,
      onProgress: onProgress,
    );
  }

  @override
  Future<void> cancelProcessing() async {
    _datasource.cancel();
  }
}
