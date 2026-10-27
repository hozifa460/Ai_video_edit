import '../../../../core/utils/result.dart';
import '../entities/clip_suggestion.dart';
import '../entities/export_settings.dart';
import '../entities/shorts_project.dart';

abstract class ShortsRepository {
  Future<Result<ShortsProject>> analyzeVideo({
    required String videoPath,
    required ExportSettings settings,
    void Function(double progress, String stage)? onProgress,
  });

  Future<Result<List<String>>> exportClips({
    required ShortsProject project,
    required List<ClipSuggestion> selectedClips,
    void Function(double overall, String stage)? onProgress,
  });
}
