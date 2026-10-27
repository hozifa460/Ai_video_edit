import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';

import 'logger.dart';
import 'filter_chain_builder.dart';
import '../../features/video_adjustment/domain/entities/adjustment_settings.dart';

class FrameExtractor {
  static Future<String?> extractPreviewFrame({
    required String videoPath,
    AdjustmentSettings settings = const AdjustmentSettings(),
  }) async {
    try {
      final dir = await getApplicationCacheDirectory();
      final outputPath = '${dir.path}/preview_frame_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final filterBuilder = FilterChainBuilder(settings);
      final vf = filterBuilder.buildPreview();

      final args = StringBuffer()
        ..write('-i "$videoPath"')
        ..write(' -ss 5')
        ..write(' -vframes 1')
        ..write(' -q:v 2');

      if (vf != null && vf.isNotEmpty) {
        args.write(' -vf "$vf"');
      }

      args.write(' -y "$outputPath"');

      AppLogger().i('FrameExtractor: ${args.toString()}');

      final session = await FFmpegKit.execute(args.toString());
      final rc = await session.getReturnCode();

      if (ReturnCode.isSuccess(rc) && File(outputPath).existsSync()) {
        return outputPath;
      }
      return null;
    } catch (e) {
      AppLogger().e('FrameExtractor error', e);
      return null;
    }
  }
}
