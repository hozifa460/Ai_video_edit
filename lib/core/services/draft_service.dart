import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../utils/logger.dart';
import '../../features/shorts_generator/domain/entities/clip_suggestion.dart';
import '../../features/shorts_generator/domain/entities/export_settings.dart';
import '../../features/shorts_generator/domain/entities/reframe_settings.dart';
import '../../features/shorts_generator/domain/entities/scene_info.dart';
import '../../features/shorts_generator/domain/entities/shorts_project.dart';
import '../../features/shorts_generator/domain/entities/video_segment.dart';

class DraftData {
  final String videoPath;
  final double totalDuration;
  final String exportSettingsJson;
  final List<Map<String, dynamic>> scenes;
  final List<Map<String, dynamic>> clips;

  DraftData({
    required this.videoPath,
    required this.totalDuration,
    required this.exportSettingsJson,
    required this.scenes,
    required this.clips,
  });

  Map<String, dynamic> toJson() => {
    'videoPath': videoPath,
    'totalDuration': totalDuration,
    'exportSettingsJson': exportSettingsJson,
    'scenes': scenes,
    'clips': clips,
  };

  factory DraftData.fromJson(Map<String, dynamic> json) => DraftData(
    videoPath: json['videoPath'] as String,
    totalDuration: (json['totalDuration'] as num?)?.toDouble() ?? 0,
    exportSettingsJson: json['exportSettingsJson'] as String,
    scenes: ((json['scenes'] as List?) ?? []).cast<Map<String, dynamic>>(),
    clips: (json['clips'] as List).cast<Map<String, dynamic>>(),
  );

  ShortsProject? restoreProject() {
    try {
      final settingsJson = jsonDecode(exportSettingsJson) as Map<String, dynamic>;
      final settings = ExportSettings(
        platform: PlatformTarget.values.firstWhere((e) => e.name == settingsJson['platform']),
        maxDuration: ClipDuration.values.firstWhere((e) => e.name == settingsJson['maxDuration']),
        clipCount: settingsJson['clipCount'] as int,
        cuttingMode: CuttingMode.values.firstWhere((e) => e.name == settingsJson['cuttingMode']),
        reframeMode: settingsJson.containsKey('reframeMode')
            ? ReframeMode.values.firstWhere((e) => e.name == settingsJson['reframeMode'])
            : ReframeMode.pillarbox,
      );

      final sceneList = scenes.map((s) => SceneInfo(
        index: s['index'] as int,
        startSeconds: (s['startSeconds'] as num).toDouble(),
        endSeconds: (s['endSeconds'] as num).toDouble(),
        thumbnailPath: (s['thumbnailPath'] as String?) ?? '',
      )).toList();

      final clipList = clips.map((c) => ClipSuggestion(
        segment: VideoSegment(
          startSeconds: (c['startSeconds'] as num).toDouble(),
          endSeconds: (c['endSeconds'] as num).toDouble(),
        ),
        score: (c['score'] as num?)?.toDouble() ?? 0.5,
        label: (c['label'] as String?) ?? '',
        selected: (c['selected'] as bool?) ?? true,
        reframeMode: c['reframeMode'] != null
            ? ReframeMode.values.firstWhere((e) => e.name == c['reframeMode'])
            : null,
      )).toList();

      return ShortsProject(
        videoPath: videoPath,
        totalDuration: totalDuration,
        exportSettings: settings,
        scenes: sceneList,
        suggestions: clipList,
      );
    } catch (e) {
      AppLogger().e('Failed to restore project from draft', e);
      return null;
    }
  }
}

class DraftService {
  static Directory? _draftsDir;

  static Future<Directory> get _dir async {
    if (_draftsDir != null) return _draftsDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _draftsDir = Directory('${appDir.path}/drafts');
    if (!await _draftsDir!.exists()) {
      await _draftsDir!.create(recursive: true);
    }
    return _draftsDir!;
  }

  static String _fileName(String videoPath) {
    final hash = videoPath.codeUnits.fold<int>(0, (h, c) => h * 31 + c);
    return 'draft_${hash.abs()}.json';
  }

  static Future<void> saveFullProject(ShortsProject project) async {
    try {
      final dir = await _dir;
      final file = File('${dir.path}/${_fileName(project.videoPath)}');

      final scenes = project.scenes.map((s) => {
        'index': s.index,
        'startSeconds': s.startSeconds,
        'endSeconds': s.endSeconds,
        'thumbnailPath': s.thumbnailPath,
      }).toList();

      final clips = project.suggestions.map((c) => {
        'startSeconds': c.startSeconds,
        'endSeconds': c.endSeconds,
        'score': c.score,
        'label': c.label,
        'selected': c.selected,
        'reframeMode': c.reframeMode?.name,
      }).toList();

      final data = DraftData(
        videoPath: project.videoPath,
        totalDuration: project.totalDuration,
        exportSettingsJson: jsonEncode({
          'platform': project.exportSettings.platform.name,
          'maxDuration': project.exportSettings.maxDuration.name,
          'clipCount': project.exportSettings.clipCount,
          'cuttingMode': project.exportSettings.cuttingMode.name,
          'reframeMode': project.exportSettings.reframeMode.name,
          'quality': project.exportSettings.quality.name,
        }),
        scenes: scenes,
        clips: clips,
      );

      await file.writeAsString(jsonEncode(data.toJson()));
      AppLogger().i('Full project draft saved: ${file.path}');
    } catch (e) {
      AppLogger().e('Failed to save full draft', e);
    }
  }

  static Future<DraftData?> load(String videoPath) async {
    try {
      final dir = await _dir;
      final file = File('${dir.path}/${_fileName(videoPath)}');
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final data = DraftData.fromJson(json);
      AppLogger().i('Draft loaded: ${file.path}');
      return data;
    } catch (e) {
      AppLogger().e('Failed to load draft', e);
      return null;
    }
  }

  static Future<void> delete(String videoPath) async {
    try {
      final dir = await _dir;
      final file = File('${dir.path}/${_fileName(videoPath)}');
      if (await file.exists()) {
        await file.delete();
        AppLogger().i('Draft deleted: ${file.path}');
      }
    } catch (e) {
      AppLogger().e('Failed to delete draft', e);
    }
  }

  static Future<List<DraftData>> allDrafts() async {
    try {
      final dir = await _dir;
      if (!await dir.exists()) return [];
      final files = await dir.list().toList();
      final drafts = <DraftData>[];
      for (final f in files.whereType<File>()) {
        try {
          final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          drafts.add(DraftData.fromJson(json));
        } catch (_) {}
      }
      return drafts;
    } catch (e) {
      return [];
    }
  }
}