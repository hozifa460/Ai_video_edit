import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/services/draft_service.dart';
import '../../domain/entities/clip_suggestion.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/reframe_settings.dart';
import '../../domain/entities/shorts_project.dart';

final exportSettingsProvider = NotifierProvider<ExportSettingsNotifier, ExportSettings>(() {
  return ExportSettingsNotifier();
});

class ExportSettingsNotifier extends Notifier<ExportSettings> {
  @override
  ExportSettings build() => const ExportSettings();

  void setPlatform(PlatformTarget v) => state = ExportSettings(platform: v, maxDuration: state.maxDuration, clipCount: state.clipCount, cuttingMode: state.cuttingMode, reframeMode: state.reframeMode, quality: state.quality);
  void setDuration(ClipDuration v) => state = ExportSettings(platform: state.platform, maxDuration: v, clipCount: state.clipCount, cuttingMode: state.cuttingMode, reframeMode: state.reframeMode, quality: state.quality);
  void setClipCount(int v) => state = ExportSettings(platform: state.platform, maxDuration: state.maxDuration, clipCount: v, cuttingMode: state.cuttingMode, reframeMode: state.reframeMode, quality: state.quality);
  void setCuttingMode(CuttingMode v) => state = ExportSettings(platform: state.platform, maxDuration: state.maxDuration, clipCount: state.clipCount, cuttingMode: v, reframeMode: state.reframeMode, quality: state.quality);
  void setReframeMode(ReframeMode v) => state = ExportSettings(platform: state.platform, maxDuration: state.maxDuration, clipCount: state.clipCount, cuttingMode: state.cuttingMode, reframeMode: v, quality: state.quality);
  void setQuality(ExportQuality v) => state = ExportSettings(platform: state.platform, maxDuration: state.maxDuration, clipCount: state.clipCount, cuttingMode: state.cuttingMode, reframeMode: state.reframeMode, quality: v);
  void restore(ExportSettings v) => state = v;
}

class ShortsUiState {
  final ShortsProject? project;
  final List<ClipSuggestion> selectedClips;
  final bool isAnalyzing;
  final double analysisProgress;
  final String analysisStage;
  final bool isExporting;
  final double exportProgress;
  final String exportStage;
  final List<String> exportPaths;

  const ShortsUiState({
    this.project,
    this.selectedClips = const [],
    this.isAnalyzing = false,
    this.analysisProgress = 0,
    this.analysisStage = '',
    this.isExporting = false,
    this.exportProgress = 0,
    this.exportStage = '',
    this.exportPaths = const [],
  });

  ShortsUiState copyWith({
    ShortsProject? project,
    List<ClipSuggestion>? selectedClips,
    bool? isAnalyzing,
    double? analysisProgress,
    String? analysisStage,
    bool? isExporting,
    double? exportProgress,
    String? exportStage,
    List<String>? exportPaths,
  }) {
    return ShortsUiState(
      project: project ?? this.project,
      selectedClips: selectedClips ?? this.selectedClips,
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      analysisProgress: analysisProgress ?? this.analysisProgress,
      analysisStage: analysisStage ?? this.analysisStage,
      isExporting: isExporting ?? this.isExporting,
      exportProgress: exportProgress ?? this.exportProgress,
      exportStage: exportStage ?? this.exportStage,
      exportPaths: exportPaths ?? this.exportPaths,
    );
  }
}

final shortsUiProvider = NotifierProvider<ShortsUiNotifier, ShortsUiState>(() {
  return ShortsUiNotifier();
});

class ShortsUiNotifier extends Notifier<ShortsUiState> {
  @override
  ShortsUiState build() => const ShortsUiState();

  void _autoSaveDraft() {
    final project = state.project;
    if (project != null) {
      DraftService.saveFullProject(project);
    }
  }

  void setProject(ShortsProject v) => state = state.copyWith(project: v);
  void setAnalyzing(bool v) => state = state.copyWith(isAnalyzing: v, analysisProgress: v ? state.analysisProgress : 0);
  void setAnalysisProgress(double v) => state = state.copyWith(analysisProgress: v);
  void setAnalysisStage(String v) => state = state.copyWith(analysisStage: v);
  void setExporting(bool v) => state = state.copyWith(isExporting: v);
  void setProgress(double v) => state = state.copyWith(exportProgress: v);
  void setStage(String v) => state = state.copyWith(exportStage: v);
  void setPaths(List<String> v) => state = state.copyWith(exportPaths: v);

  void toggleClip(ClipSuggestion clip) {
    final current = List<ClipSuggestion>.from(state.selectedClips);
    if (current.contains(clip)) {
      clip.selected = false;
      current.remove(clip);
    } else {
      clip.selected = true;
      current.add(clip);
    }
    state = state.copyWith(selectedClips: current);
    _autoSaveDraft();
  }

  void setSelectedClips(List<ClipSuggestion> clips) {
    state = state.copyWith(selectedClips: clips);
    _autoSaveDraft();
  }

  void updateClipSegment(ClipSuggestion clip, double start, double end) {
    clip.segment.startSeconds = start;
    clip.segment.endSeconds = end;
    final updated = List<ClipSuggestion>.from(state.selectedClips);
    final idx = updated.indexOf(clip);
    if (idx >= 0) {
      updated[idx] = clip;
    }
    state = state.copyWith(selectedClips: updated);
    _autoSaveDraft();
  }

  void updateClipReframe(ClipSuggestion clip, ReframeMode mode) {
    clip.reframeMode = mode;
    final updated = List<ClipSuggestion>.from(state.selectedClips);
    final idx = updated.indexOf(clip);
    if (idx >= 0) {
      updated[idx] = clip;
    }
    state = state.copyWith(selectedClips: updated);
    _autoSaveDraft();
  }
}
