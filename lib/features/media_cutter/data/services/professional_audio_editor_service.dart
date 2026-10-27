import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../../../../core/utils/logger.dart';
import '../../../audio_enhancement/data/services/audio_enhancement_filter_builder.dart';
import 'ffmpeg_media_cutter_service.dart';

class AudioSilenceRegion {
  final double startSeconds;
  final double endSeconds;

  const AudioSilenceRegion({
    required this.startSeconds,
    required this.endSeconds,
  });

  double get durationSeconds => endSeconds - startSeconds;
  double get centerSeconds => startSeconds + (durationSeconds / 2);
}

class ProfessionalAudioEditorService {
  const ProfessionalAudioEditorService();

  static const supportedExtensions = {'mp3', 'wav', 'aac', 'm4a'};

  static bool isSupportedAudioPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    return supportedExtensions.contains(ext);
  }

  static String buildTrimCommand({
    required String inputPath,
    required String outputPath,
    required double startSeconds,
    required double endSeconds,
  }) {
    _validateRange(startSeconds, endSeconds);
    return '-ss ${_fmt(startSeconds)} -i ${_q(inputPath)} '
        '-t ${_fmt(endSeconds - startSeconds)} -map 0:a:0 -vn '
        '-c copy -y ${_q(outputPath)}';
  }

  static String buildDeleteRangeCommand({
    required String inputPath,
    required String outputPath,
    required double deleteStartSeconds,
    required double deleteEndSeconds,
    required double totalDurationSeconds,
  }) {
    _validateRange(deleteStartSeconds, deleteEndSeconds);
    if (deleteStartSeconds <= 0 && deleteEndSeconds >= totalDurationSeconds) {
      throw ArgumentError('Cannot delete entire audio file');
    }
    if (deleteStartSeconds <= 0) {
      return buildTrimCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        startSeconds: deleteEndSeconds,
        endSeconds: totalDurationSeconds,
      );
    }
    if (deleteEndSeconds >= totalDurationSeconds) {
      return buildTrimCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        startSeconds: 0,
        endSeconds: deleteStartSeconds,
      );
    }

    final filter =
        '[0:a]atrim=start=0.000:end=${_fmt(deleteStartSeconds)},asetpts=PTS-STARTPTS[a0];'
        '[0:a]atrim=start=${_fmt(deleteEndSeconds)}:end=${_fmt(totalDurationSeconds)},asetpts=PTS-STARTPTS[a1];'
        '[a0][a1]concat=n=2:v=0:a=1[outa]';
    return '-i ${_q(inputPath)} -filter_complex "$filter" -map "[outa]" '
        '-c:a aac -b:a 256k -y ${_q(outputPath)}';
  }

  static List<MediaCutCommand> buildSplitCommands({
    required String inputPath,
    required String outputDirectory,
    required String baseName,
    required List<double> cutPointsSeconds,
    required double totalDurationSeconds,
  }) {
    return FfmpegMediaCutterService.buildSplitAtCutsCommands(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
      baseName: baseName,
      cutPointsSeconds: cutPointsSeconds,
      totalDurationSeconds: totalDurationSeconds,
      mediaType: CutterMediaType.audio,
    );
  }

  static String buildProcessCommand({
    required String inputPath,
    required String outputPath,
    bool noiseReduction = false,
    bool voiceEnhancement = false,
  }) {
    final filter = AudioEnhancementFilterBuilder.build(
      noiseFloor: noiseReduction ? -42 : -55,
      gateAmount: noiseReduction ? 55 : 15,
      deesser: voiceEnhancement ? 35 : 0,
      bass: voiceEnhancement ? 1 : 0,
      mid: voiceEnhancement ? 4 : 0,
      presence: voiceEnhancement ? 5 : 0,
      treble: voiceEnhancement ? 3 : 0,
      volume: 100,
    );

    return '-i ${_q(inputPath)} -map 0:a:0 -vn -af "$filter" '
        '-c:a aac -b:a 256k -y ${_q(outputPath)}';
  }

  static String buildSilenceDetectCommand({
    required String inputPath,
    double noiseDb = -38,
    double minDurationSeconds = 0.25,
  }) {
    return '-i ${_q(inputPath)} -af silencedetect=noise=${noiseDb.toStringAsFixed(0)}dB:'
        'd=${_fmt(minDurationSeconds)} -f null -';
  }

  static List<AudioSilenceRegion> parseSilenceRegions(
    String logs, {
    double? fallbackEnd,
  }) {
    final starts = <double>[];
    final regions = <AudioSilenceRegion>[];
    final startRe = RegExp(r'silence_start:\s*([0-9.]+)');
    final endRe = RegExp(r'silence_end:\s*([0-9.]+)');

    for (final line in logs.split('\n')) {
      final startMatch = startRe.firstMatch(line);
      if (startMatch != null) {
        starts.add(double.parse(startMatch.group(1)!));
        continue;
      }

      final endMatch = endRe.firstMatch(line);
      if (endMatch != null && starts.isNotEmpty) {
        final start = starts.removeAt(0);
        final end = double.parse(endMatch.group(1)!);
        if (end > start) {
          regions.add(AudioSilenceRegion(startSeconds: start, endSeconds: end));
        }
      }
    }

    // Trailing silence: a silence_start never closed by silence_end means the
    // file ends mid-silence — close it at the total duration.
    for (final start in starts) {
      if (fallbackEnd != null && fallbackEnd > start + 0.05) {
        regions.add(
          AudioSilenceRegion(startSeconds: start, endSeconds: fallbackEnd),
        );
      }
    }

    return regions;
  }

  static List<double> smartCutPointsFromSilence(
    List<AudioSilenceRegion> regions, {
    double minGapSeconds = 2,
  }) {
    final points = <double>[];
    for (final region in regions) {
      final point = double.parse(region.centerSeconds.toStringAsFixed(3));
      if (points.isEmpty || point - points.last >= minGapSeconds) {
        points.add(point);
      }
    }
    return points;
  }

  Future<String> trim({
    required String inputPath,
    required String outputPath,
    required double startSeconds,
    required double endSeconds,
  }) async {
    return _run(
      buildTrimCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        startSeconds: startSeconds,
        endSeconds: endSeconds,
      ),
      outputPath,
    );
  }

  Future<String> deleteRange({
    required String inputPath,
    required String outputPath,
    required double deleteStartSeconds,
    required double deleteEndSeconds,
    required double totalDurationSeconds,
  }) async {
    return _run(
      buildDeleteRangeCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        deleteStartSeconds: deleteStartSeconds,
        deleteEndSeconds: deleteEndSeconds,
        totalDurationSeconds: totalDurationSeconds,
      ),
      outputPath,
    );
  }

  Future<List<String>> split({
    required String inputPath,
    required String outputDirectory,
    required String baseName,
    required List<double> cutPointsSeconds,
    required double totalDurationSeconds,
  }) async {
    final commands = buildSplitCommands(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
      baseName: baseName,
      cutPointsSeconds: cutPointsSeconds,
      totalDurationSeconds: totalDurationSeconds,
    );
    final outputs = <String>[];
    for (final item in commands) {
      await _run(item.command, item.outputPath);
      outputs.add(item.outputPath);
    }
    return outputs;
  }

  Future<String> process({
    required String inputPath,
    required String outputPath,
    required bool noiseReduction,
    required bool voiceEnhancement,
  }) async {
    return _run(
      buildProcessCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        noiseReduction: noiseReduction,
        voiceEnhancement: voiceEnhancement,
      ),
      outputPath,
    );
  }

  Future<List<AudioSilenceRegion>> detectSilence(String inputPath) async {
    final command = buildSilenceDetectCommand(inputPath: inputPath);
    AppLogger().i('Audio editor silence detect: $command');
    final session = await FFmpegKit.execute(command);
    final logs = await session.getAllLogsAsString() ?? '';

    // Probe duration so trailing (never-closed) silence can be completed.
    double? fallbackEnd;
    try {
      final probe = await FFprobeKit.getMediaInformation(inputPath);
      final dur = probe.getMediaInformation()?.getDuration();
      fallbackEnd = dur != null ? double.tryParse(dur) : null;
    } catch (_) {}

    return parseSilenceRegions(logs, fallbackEnd: fallbackEnd);
  }

  Future<String> _run(String command, String outputPath) async {
    AppLogger().i('Audio editor command: $command');
    final session = await FFmpegKit.execute(command);
    final rc = await session.getReturnCode();
    if (ReturnCode.isSuccess(rc)) return outputPath;

    final logs = await session.getAllLogsAsString();
    AppLogger().e('Audio editor command failed: $logs');
    throw Exception('Audio edit failed');
  }

  static void _validateRange(double start, double end) {
    if (start < 0 || end <= start) {
      throw ArgumentError('Invalid audio edit range: $start - $end');
    }
  }

  static String _q(String path) => '"${path.replaceAll('\\', '/')}"';

  static String _fmt(double seconds) => seconds.toStringAsFixed(3);
}
