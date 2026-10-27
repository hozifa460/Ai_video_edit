import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/result.dart';
import '../../data/repositories/shorts_repository_impl.dart';
import '../providers/shorts_provider.dart';

class ShortsExportScreen extends ConsumerWidget {
  const ShortsExportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(shortsUiProvider);
    final progress = ui.exportProgress;
    final stage = ui.exportStage;
    final isExporting = ui.isExporting;
    final paths = ui.exportPaths;

    if (paths.isNotEmpty) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('Export Complete')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_circle, color: AppColors.success, size: 64),
                const SizedBox(height: 16),
                Text('${paths.length} Clips Exported!', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                const SizedBox(height: 8),
                Text('${paths.length} files saved', style: const TextStyle(color: AppColors.textTertiary)),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity, height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Exporting...')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 120, height: 120,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: progress, strokeWidth: 6,
                      backgroundColor: AppColors.surfaceLighter,
                      valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                    ),
                    Text('${(progress * 100).round()}%', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(stage.isNotEmpty ? stage : 'Starting...', style: const TextStyle(color: AppColors.textSecondary, fontSize: 16)),
              const SizedBox(height: 8),
              const Text('Please do not close the app', style: TextStyle(color: AppColors.textTertiary, fontSize: 12)),
              if (!isExporting && progress == 0) ...[
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity, height: 48,
                  child: ElevatedButton.icon(
                    onPressed: () => _startExport(context, ref),
                    icon: const Icon(Icons.download),
                    label: const Text('Start Export'),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startExport(BuildContext context, WidgetRef ref) async {
    final ui = ref.read(shortsUiProvider);
    final project = ui.project;
    final selected = ui.selectedClips;
    if (project == null || selected.isEmpty) return;

    final notifier = ref.read(shortsUiProvider.notifier);
    notifier.setExporting(true);

    final repo = ShortsRepositoryImpl();
    final result = await repo.exportClips(
      project: project,
      selectedClips: selected,
      onProgress: (overall, stage) {
        notifier.setProgress(overall);
        notifier.setStage(stage);
      },
    );

    notifier.setExporting(false);

    if (result is Success<List<String>>) {
      notifier.setPaths(result.value);
    } else if (result is AppError<List<String>>) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error.message), backgroundColor: AppColors.error));
      }
    }
  }
}
