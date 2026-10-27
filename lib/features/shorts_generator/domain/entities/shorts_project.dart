import 'clip_suggestion.dart';
import 'export_settings.dart';
import 'scene_info.dart';

class ShortsProject {
  final String videoPath;
  final double totalDuration;
  final ExportSettings exportSettings;
  final List<SceneInfo> scenes;
  final List<ClipSuggestion> suggestions;

  const ShortsProject({
    required this.videoPath,
    required this.totalDuration,
    this.exportSettings = const ExportSettings(),
    this.scenes = const [],
    this.suggestions = const [],
  });
}
