import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../../../../core/utils/logger.dart';

class AutoNoiseDetector {
  /// Estimates noise floor (dB) by running [volumedetect] on the first 30s.
  /// Returns the 10th-percentile level as an integer dB value (e.g. -42).
  static Future<int> detectNoiseFloor(String audioPath) async {
    final path = audioPath.replaceAll('\\', '/');
    final probeCmd = '-t 30 -i "$path" -af "volumedetect" -f null - -y';

    final session = await FFmpegKit.execute(probeCmd);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      AppLogger().w('volumedetect failed, using default noise floor');
      return -42;
    }

    final logs = await session.getAllLogsAsString() ?? '';
    final histMatches = RegExp(
      r'histogram_\S+:\s*(-?\d+):\s*(\d+)',
    ).allMatches(logs);

    if (histMatches.isEmpty) {
      final mean = RegExp(r'mean_volume:\s*([-\d.]+)').firstMatch(logs);
      if (mean == null) return -42;
      final mv = double.tryParse(mean.group(1)!) ?? -42;
      return (mv - 10).round().clamp(-60, -20);
    }

    final histogram = <int, int>{};
    for (final m in histMatches) {
      final db = int.tryParse(m.group(1)!) ?? 0;
      final count = int.tryParse(m.group(2)!) ?? 0;
      histogram[db] = count;
    }

    if (histogram.isEmpty) return -42;

    final total = histogram.values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return -42;

    final sorted = histogram.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    int cumulative = 0;
    for (final entry in sorted) {
      cumulative += entry.value;
      if (cumulative >= total * 0.1) return (entry.key + 3).clamp(-60, -20);
    }

    return -42;
  }
}
