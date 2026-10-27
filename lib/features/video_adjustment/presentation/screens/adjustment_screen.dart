import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/services/video_download_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/adjustment_settings.dart';
import '../providers/adjustment_provider.dart';
import '../providers/preview_provider.dart';
import '../providers/export_provider.dart';
import '../providers/undo_redo_provider.dart';
import '../widgets/video_preview_widget.dart';
import '../widgets/basic_adjustments_panel.dart';
import '../widgets/color_adjustments_panel.dart';
import '../widgets/tone_adjustments_panel.dart';
import '../widgets/video_adjustments_panel.dart';
import '../widgets/audio_adjustments_panel.dart';
import '../widgets/effects_panel.dart';
import '../widgets/lut_panel.dart';
import '../widgets/presets_row.dart';
import '../widgets/before_after_toggle.dart';
import '../widgets/undo_redo_bar.dart';

class AdjustmentScreen extends ConsumerStatefulWidget {
  final String videoPath;

  const AdjustmentScreen({super.key, required this.videoPath});

  @override
  ConsumerState<AdjustmentScreen> createState() => _AdjustmentScreenState();
}

class _AdjustmentScreenState extends ConsumerState<AdjustmentScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  VideoPlayerController? _videoController;
  String _selectedExportQuality = 'high';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _tabController.addListener(_onTabChanged);
    _initVideoPlayer();
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _initVideoPlayer() async {
    if (VideoDownloadService.isUrl(widget.videoPath)) {
      _videoController = VideoPlayerController.networkUrl(Uri.parse(widget.videoPath));
    } else {
      final file = File(widget.videoPath);
      if (!await file.exists()) return;
      _videoController = VideoPlayerController.file(file);
    }
    await _videoController!.initialize();
    if (!mounted) return;
    _videoController!.play();
    _videoController!.setLooping(true);
    setState(() {});
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      _extractPreviewFrame();
    }
  }

  void _extractPreviewFrame() {
    if (VideoDownloadService.isUrl(widget.videoPath)) return;
    ref.read(previewProvider.notifier).updatePreview(widget.videoPath);
  }

  @override
  Widget build(BuildContext context) {
    final previewState = ref.watch(previewProvider);
    final undoRedo = ref.watch(undoRedoProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Video Adjustments'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download),
            onPressed: _showExportDialog,
            tooltip: 'Export',
          ),
        ],
      ),
      body: Column(
        children: [
          VideoPreviewWidget(
            controller: _videoController,
            previewPath: previewState.previewPath,
            isLoading: previewState.isLoading,
            showOriginal: previewState.showOriginal,
            videoPath: widget.videoPath,
          ),
          BeforeAfterToggle(
            showOriginal: previewState.showOriginal,
            onPeekStart: () => ref.read(previewProvider.notifier).toggleOriginal(true),
            onPeekEnd: () => ref.read(previewProvider.notifier).toggleOriginal(false),
          ),
          UndoRedoBar(
            canUndo: undoRedo.canUndo,
            canRedo: undoRedo.canRedo,
            onUndo: () {
              final s = ref.read(undoRedoProvider.notifier).undo();
              if (s != null) {
                ref.read(adjustmentProvider.notifier).applyUndoState(s as AdjustmentSettings);
                _extractPreviewFrame();
              }
            },
            onRedo: () {
              final s = ref.read(undoRedoProvider.notifier).redo();
              if (s != null) {
                ref.read(adjustmentProvider.notifier).applyUndoState(s as AdjustmentSettings);
                _extractPreviewFrame();
              }
            },
            onReset: () {
              ref.read(adjustmentProvider.notifier).resetAll();
              _extractPreviewFrame();
            },
          ),
          TabBar(
            controller: _tabController,
            isScrollable: true,
            indicatorColor: AppColors.primary,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textSecondary,
            tabs: const [
              Tab(text: 'Basic', icon: Icon(Icons.tune, size: 18)),
              Tab(text: 'Color', icon: Icon(Icons.palette, size: 18)),
              Tab(text: 'Tone', icon: Icon(Icons.gradient, size: 18)),
              Tab(text: 'Video', icon: Icon(Icons.videocam, size: 18)),
              Tab(text: 'Audio', icon: Icon(Icons.volume_up, size: 18)),
              Tab(text: 'FX', icon: Icon(Icons.auto_fix_high, size: 18)),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                BasicAdjustmentsPanel(onChanged: () {}, onPreviewChanged: _extractPreviewFrame),
                ColorAdjustmentsPanel(onChanged: () {}, onPreviewChanged: _extractPreviewFrame),
                ToneAdjustmentsPanel(onChanged: () {}, onPreviewChanged: _extractPreviewFrame),
                VideoAdjustmentsPanel(onChanged: () {}, onPreviewChanged: _extractPreviewFrame),
                AudioAdjustmentsPanel(onChanged: () {}, onPreviewChanged: _extractPreviewFrame),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      EffectsPanel(onChanged: () {}, onPreviewChanged: _extractPreviewFrame),
                      const SizedBox(height: 24),
                      LutPanel(onChanged: _extractPreviewFrame),
                      const SizedBox(height: 24),
                      PresetsRow(onChanged: _extractPreviewFrame),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showExportDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Export Video'),
        content: ExportQualitySelector(
          onChanged: (quality) => _selectedExportQuality = quality,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startExport();
            },
            child: const Text('Export'),
          ),
        ],
      ),
    );
  }

  Future<void> _startExport() async {
    final outputDir = await _getExportDirectory();
    final outputPath = '${outputDir.path}/adjusted_${DateTime.now().millisecondsSinceEpoch}.mp4';

    ref.read(exportProvider.notifier).exportVideo(
      inputPath: widget.videoPath,
      outputPath: outputPath,
      quality: _selectedExportQuality,
    );

    _showExportProgress();
  }

  void _showExportProgress() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return Consumer(
          builder: (context, ref, _) {
            final exportState = ref.watch(exportProvider);
            return AlertDialog(
              backgroundColor: AppColors.surface,
              title: const Text('Exporting...'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: exportState.progress > 0 ? exportState.progress : null,
                    backgroundColor: AppColors.surfaceLighter,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    exportState.isCompleted
                        ? 'Completed!'
                        : exportState.error != null
                            ? 'Error: ${exportState.error}'
                            : '${(exportState.progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
              actions: [
                if (exportState.isCompleted || exportState.error != null)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      if (exportState.isCompleted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Export completed!')),
                        );
                      }
                    },
                    child: const Text('OK'),
                  )
                else
                  TextButton(
                    onPressed: () {
                      ref.read(exportProvider.notifier).cancelExport();
                      Navigator.pop(ctx);
                    },
                    child: const Text('Cancel'),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Future<Directory> _getExportDirectory() async {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download/Ai_video_editing');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final dir = await getApplicationDocumentsDirectory();
    return dir;
  }
}

class ExportQualitySelector extends StatefulWidget {
  const ExportQualitySelector({super.key, this.onChanged});

  final ValueChanged<String>? onChanged;

  @override
  State<ExportQualitySelector> createState() => _ExportQualitySelectorState();
}

class _ExportQualitySelectorState extends State<ExportQualitySelector> {
  String _selected = 'high';

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _qualityOption('Original', 'original', 'Same quality as source'),
        const SizedBox(height: 8),
        _qualityOption('High', 'high', 'CRF 18 - Best quality'),
        const SizedBox(height: 8),
        _qualityOption('Medium', 'medium', 'CRF 23 - Balanced'),
        const SizedBox(height: 8),
        _qualityOption('Compressed', 'compressed', 'CRF 28 - Smaller file'),
      ],
    );
  }

  Widget _qualityOption(String label, String value, String subtitle) {
    final selected = _selected == value;
    return InkWell(
      onTap: () {
        setState(() => _selected = value);
        widget.onChanged?.call(value);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary.withValues(alpha: 0.4) : AppColors.cardBorder,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.primary : AppColors.textTertiary,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
                Text(subtitle, style: const TextStyle(color: AppColors.textTertiary, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
