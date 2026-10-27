import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/services/draft_service.dart';
import '../../../../core/services/video_download_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/result.dart';
import '../../data/repositories/shorts_repository_impl.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/reframe_settings.dart';
import '../../domain/entities/shorts_project.dart';
import '../providers/shorts_provider.dart';

class ImportModeScreen extends ConsumerStatefulWidget {
  final String videoPath;

  const ImportModeScreen({super.key, required this.videoPath});

  @override
  ConsumerState<ImportModeScreen> createState() => _ImportModeScreenState();
}

class _ImportModeScreenState extends ConsumerState<ImportModeScreen> {
  @override
  void initState() {
    super.initState();
    _tryRestoreDraft();
  }

  Future<void> _tryRestoreDraft() async {
    final draft = await DraftService.load(widget.videoPath);
    if (draft == null || !mounted) return;

    if (!VideoDownloadService.isUrl(widget.videoPath) && !File(widget.videoPath).existsSync()) {
      await DraftService.delete(widget.videoPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Saved video file not found, draft removed'),
          backgroundColor: AppColors.error,
        ));
      }
      return;
    }

    if (draft.scenes.isNotEmpty && draft.clips.isNotEmpty) {
      final project = draft.restoreProject();
      if (project != null && mounted) {
        final notifier = ref.read(shortsUiProvider.notifier);
        notifier.setProject(project);
        notifier.setSelectedClips(List.from(project.suggestions));
        ref.read(exportSettingsProvider.notifier).restore(project.exportSettings);
        Navigator.of(context).pushNamed(AppRouter.shortsSuggestions);
        return;
      }
    }

    try {
      final decoded = jsonDecode(draft.exportSettingsJson) as Map<String, dynamic>;
      final settings = ExportSettings(
        platform: PlatformTarget.values.firstWhere((e) => e.name == decoded['platform']),
        maxDuration: ClipDuration.values.firstWhere((e) => e.name == decoded['maxDuration']),
        clipCount: decoded['clipCount'] as int,
        cuttingMode: CuttingMode.values.firstWhere((e) => e.name == decoded['cuttingMode']),
        reframeMode: decoded.containsKey('reframeMode') ? ReframeMode.values.firstWhere((e) => e.name == decoded['reframeMode']) : ReframeMode.pillarbox,
        quality: decoded.containsKey('quality') ? ExportQuality.values.firstWhere((e) => e.name == decoded['quality']) : ExportQuality.high,
      );
      ref.read(exportSettingsProvider.notifier).restore(settings);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Draft restored from previous session'),
        backgroundColor: AppColors.primary,
        duration: Duration(seconds: 2),
      ));
    } catch (e) {
      // ignore malformed drafts
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(exportSettingsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Create Shorts')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildVideoInfo(),
            const SizedBox(height: 24),
            const Text('Target Platform', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            _buildPlatformSelector(settings),
            const SizedBox(height: 20),
            const Text('Max Clip Duration', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            _buildDurationSelector(settings),
            const SizedBox(height: 20),
            const Text('Number of Clips', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            _buildClipCountSelector(settings),
            const SizedBox(height: 24),
            const Text('Cutting Mode', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            _buildCuttingModeSelector(settings),
            const SizedBox(height: 24),
            const Text('Video Template', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            _buildTemplateSelector(settings),
            const SizedBox(height: 24),
            const Text('Export Quality', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            _buildQualitySelector(settings),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () => _startAnalysis(settings),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Analyze Video'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoInfo() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.cardBorder)),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.video_file, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.videoPath.split('/').last.split('\\').last,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformSelector(ExportSettings s) {
    final platforms = [
      (PlatformTarget.tiktok, 'TikTok', Icons.music_note),
      (PlatformTarget.reels, 'Reels', Icons.video_library),
      (PlatformTarget.shorts, 'Shorts', Icons.videocam),
    ];
    return Row(
      children: platforms.map((p) {
        final selected = s.platform == p.$1;
        return Expanded(
          child: GestureDetector(
            onTap: () => ref.read(exportSettingsProvider.notifier).setPlatform(p.$1),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: selected ? AppColors.primary.withValues(alpha: 0.15) : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: selected ? AppColors.primary : AppColors.cardBorder),
              ),
              child: Column(
                children: [
                  Icon(p.$3, color: selected ? AppColors.primary : AppColors.textTertiary, size: 22),
                  const SizedBox(height: 4),
                  Text(p.$2, style: TextStyle(fontSize: 11, color: selected ? AppColors.primary : AppColors.textTertiary)),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDurationSelector(ExportSettings s) {
    final durations = [
      (ClipDuration.s15, '15s'),
      (ClipDuration.s30, '30s'),
      (ClipDuration.s60, '60s'),
      (ClipDuration.s90, '90s'),
      (ClipDuration.m3, '3m'),
      (ClipDuration.m5, '5m'),
      (ClipDuration.m10, '10m'),
      (ClipDuration.m15, '15m'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: durations.map((d) {
          final selected = s.maxDuration == d.$1;
          return GestureDetector(
            onTap: () => ref.read(exportSettingsProvider.notifier).setDuration(d.$1),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              decoration: BoxDecoration(
                color: selected ? AppColors.primary.withValues(alpha: 0.15) : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: selected ? AppColors.primary : AppColors.cardBorder),
              ),
              child: Text(d.$2, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: selected ? AppColors.primary : AppColors.textSecondary)),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildClipCountSelector(ExportSettings s) {
    final counts = [5, 10, 15, 20, 25, 30, 50];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: counts.map((count) {
          final selected = s.clipCount == count;
          return GestureDetector(
            onTap: () => ref.read(exportSettingsProvider.notifier).setClipCount(count),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
              decoration: BoxDecoration(
                color: selected ? AppColors.primary.withValues(alpha: 0.15) : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: selected ? AppColors.primary : AppColors.cardBorder),
              ),
              child: Text('$count', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: selected ? AppColors.primary : AppColors.textSecondary)),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCuttingModeSelector(ExportSettings s) {
    final modes = [
      (CuttingMode.interval, 'Interval', Icons.timer, 'Cut every X seconds'),
      (CuttingMode.scene, 'Scene', Icons.movie_creation_outlined, 'Detect scene changes'),
      (CuttingMode.smartAudio, 'Smart Audio', Icons.graphic_eq, 'Full conversation context, no duration limit'),
      (CuttingMode.manual, 'Manual', Icons.content_cut, 'Set in/out points'),
    ];
    return Column(
      children: modes.map((m) {
        final selected = s.cuttingMode == m.$1;
        return GestureDetector(
          onTap: () => ref.read(exportSettingsProvider.notifier).setCuttingMode(m.$1),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected ? AppColors.primary.withValues(alpha: 0.08) : AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? AppColors.primary : AppColors.cardBorder),
            ),
            child: Row(
              children: [
                Icon(m.$3, size: 20, color: selected ? AppColors.primary : AppColors.textSecondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.$2, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: selected ? AppColors.primary : AppColors.textPrimary)),
                      Text(m.$4, style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                if (selected) const Icon(Icons.check, size: 18, color: AppColors.primary),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildTemplateSelector(ExportSettings s) {
    final allModes = ReframeMode.values;
    return Column(
      children: allModes.map((mode) {
        final selected = s.reframeMode == mode;
        return GestureDetector(
          onTap: () => ref.read(exportSettingsProvider.notifier).setReframeMode(mode),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected ? AppColors.primary.withValues(alpha: 0.08) : AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? AppColors.primary : AppColors.cardBorder),
            ),
            child: Row(
              children: [
                Icon(_iconForMode(mode), size: 20, color: selected ? AppColors.primary : AppColors.textSecondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(mode.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: selected ? AppColors.primary : AppColors.textPrimary)),
                      Text(mode.description, style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                if (selected) const Icon(Icons.check, size: 18, color: AppColors.primary),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildQualitySelector(ExportSettings s) {
    final qualities = ExportQuality.values;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: qualities.map((q) {
          final selected = s.quality == q;
          return GestureDetector(
            onTap: () => ref.read(exportSettingsProvider.notifier).setQuality(q),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
              decoration: BoxDecoration(
                color: selected ? AppColors.primary.withValues(alpha: 0.15) : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: selected ? AppColors.primary : AppColors.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(q.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? AppColors.primary : AppColors.textPrimary)),
                  Text(q.description, style: TextStyle(fontSize: 10, color: AppColors.textTertiary)),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  IconData _iconForMode(ReframeMode mode) {
    switch (mode) {
      case ReframeMode.centerCrop: return Icons.crop_square;
      case ReframeMode.pillarbox: return Icons.photo_size_select_large;
      case ReframeMode.faceAware: return Icons.face;
      case ReframeMode.blurBackground: return Icons.blur_on;
      case ReframeMode.cinematicLetterbox: return Icons.movie;
      case ReframeMode.kenBurns: return Icons.zoom_in;
      case ReframeMode.shadowGlow: return Icons.flare;
      case ReframeMode.mirrorSplit: return Icons.flip;
    }
  }

  Future<void> _startAnalysis(ExportSettings settings) async {
    final notifier = ref.read(shortsUiProvider.notifier);

    if (!VideoDownloadService.isUrl(widget.videoPath) && !File(widget.videoPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Video file not found. Please re-import the video.'),
        backgroundColor: AppColors.error,
      ));
      return;
    }

    notifier.setAnalyzing(true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Consumer(builder: (context, ref, _) {
          final ui = ref.watch(shortsUiProvider);
          return AlertDialog(
            backgroundColor: AppColors.surface,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 100, height: 100,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: ui.analysisProgress > 0 ? ui.analysisProgress : null,
                        strokeWidth: 6,
                        backgroundColor: AppColors.surfaceLighter,
                        valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                      ),
                      Text('${(ui.analysisProgress * 100).round()}%',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  ui.analysisStage.isNotEmpty ? ui.analysisStage : 'Analyzing video...',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 8),
                const Text('Please wait', style: TextStyle(color: AppColors.textTertiary, fontSize: 12)),
              ],
            ),
          );
        }),
      ),
    );

    final repo = ShortsRepositoryImpl();
    final result = await repo.analyzeVideo(
      videoPath: widget.videoPath,
      settings: settings,
      onProgress: (progress, stage) {
        notifier.setAnalysisProgress(progress);
        notifier.setAnalysisStage(stage);
      },
    );

    notifier.setAnalyzing(false);

    if (mounted) {
      Navigator.of(context).pop();
    }

    if (result is Success<ShortsProject>) {
      final project = result.value;
      notifier.setProject(project);
      notifier.setSelectedClips(List.from(project.suggestions));
      unawaited(DraftService.saveFullProject(project));
      if (mounted) {
        Navigator.of(context).pushNamed(AppRouter.shortsSuggestions);
      }
    } else if (result is AppError<ShortsProject>) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error.message), backgroundColor: AppColors.error));
      }
    }
  }
}
