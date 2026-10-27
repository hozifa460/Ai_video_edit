import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/enums/export_quality.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/media_scanner.dart';
import '../../../core/utils/result.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../video_processing/domain/providers/processing_provider.dart';
import '../../video_processing/data/repositories/video_processor_repository_impl.dart';
import '../../video_processing/domain/entities/export_params.dart';

class ExportScreen extends ConsumerStatefulWidget {
  final String? videoPath;

  const ExportScreen({super.key, this.videoPath});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  String _format = 'mp4';
  ExportQuality _quality = ExportQuality.original;
  String? _savePath;
  bool _isExporting = false;
  String? _exportedPath;
  int? _exportedSize;

  @override
  void initState() {
    super.initState();
    _generateSavePath();
  }

  Future<void> _generateSavePath() async {
    try {
      final dir = await FileUtils.getExportDirectory();
      if (!mounted) return;
      final fileName = 'silence_removed_${DateTime.now().millisecondsSinceEpoch}.$_format';
      setState(() => _savePath = '${dir.path}/$fileName');
    } catch (e) {
      AppLogger().e('Failed to generate save path', e);
      if (!mounted) return;
      final fileName = 'silence_removed_${DateTime.now().millisecondsSinceEpoch}.$_format';
      setState(() => _savePath = fileName);
    }
  }

  @override
  Widget build(BuildContext context) {
    final processingState = ref.watch(processingStateProvider);
    final sourcePath = processingState.outputPath ?? widget.videoPath;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Export')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Export Settings',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            _buildSaveLocation(),
            const SizedBox(height: 16),
            _buildFormatSelector(),
            const SizedBox(height: 16),
            _buildQualitySelector(),
            if (_exportedPath != null) ...[
              const SizedBox(height: 16),
              _buildExportResult(),
            ],
            const SizedBox(height: 24),
            _buildExportButton(sourcePath),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveLocation() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.folder, color: AppColors.primary),
        title: Text(
          _savePath ?? 'Generating save path...',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
        subtitle: const Text(
          'Auto-saved to Downloads',
          style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ),
    );
  }

  Widget _buildFormatSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Format',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: ['mp4', 'mov'].map((format) {
                final isSelected = _format == format;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: format == 'mp4' ? 4 : 0,
                      left: format == 'mov' ? 4 : 0,
                    ),
                      child: GestureDetector(
                        onTap: () {
                          setState(() => _format = format);
                          _generateSavePath();
                        },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.surfaceLight,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.cardBorder,
                          ),
                        ),
                        child: Center(
                          child: Text(
                                  format.toUpperCase(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ))
                              .animate()
                              .fadeIn(),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQualitySelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Quality',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            ...ExportQuality.values.map((quality) {
              final isSelected = _quality == quality;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: GestureDetector(
                  onTap: () => setState(() => _quality = quality),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary.withValues(alpha: 0.15)
                          : AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.cardBorder,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _qualityIcon(quality),
                          size: 18,
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.textTertiary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          quality.name[0].toUpperCase() +
                              quality.name.substring(1),
                          style: TextStyle(
                            color: isSelected
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _qualityDesc(quality),
                          style: const TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  IconData _qualityIcon(ExportQuality quality) {
    switch (quality) {
      case ExportQuality.original:
        return Icons.star;
      case ExportQuality.high:
        return Icons.star_half;
      case ExportQuality.medium:
        return Icons.star_border;
    }
  }

  String _qualityDesc(ExportQuality quality) {
    switch (quality) {
      case ExportQuality.original:
        return '192k AAC';
      case ExportQuality.high:
        return '128k AAC';
      case ExportQuality.medium:
        return '96k AAC';
    }
  }

  Widget _buildExportResult() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Row(
              children: [
                Icon(Icons.check_circle, color: AppColors.success, size: 20),
                SizedBox(width: 8),
                Text(
                  'Export Complete',
                  style: TextStyle(
                    color: AppColors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (_exportedSize != null) ...[
              const SizedBox(height: 8),
              Text(
                'File size: ${FileUtils.formatFileSize(_exportedSize!)}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
    ).animate().slideY(begin: 0.5, duration: const Duration(milliseconds: 300)).fadeIn();
  }

  Widget _buildExportButton(String? sourcePath) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: (_isExporting || sourcePath == null)
            ? null
            : () => _exportVideo(sourcePath),
        icon: const Icon(Icons.save_alt),
        label: const Text('Export Video'),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Future<void> _exportVideo(String sourcePath) async {
    if (_savePath == null) return;

    setState(() => _isExporting = true);
    final progressNotifier = ValueNotifier<double>(0);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            margin: const EdgeInsets.all(32),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ValueListenableBuilder<double>(
                valueListenable: progressNotifier,
                builder: (context, progress, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 16),
                    const Text('Exporting video...'),
                    const SizedBox(height: 8),
                    Text(
                      '${(progress * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    try {
      final repo = VideoProcessorRepositoryImpl();
      final result = await repo.exportVideo(
        sourcePath: sourcePath,
        outputPath: _savePath!,
        format: _format,
        quality: _quality,
        onProgress: (progress, _) => progressNotifier.value = progress,
      );

      if (mounted) {
        Navigator.of(context).pop();
      }

      if (result is Success<ExportParams>) {
        final params = result.value;
        MediaScanner.scanFile(params.outputPath);
        final file = File(params.outputPath);
        file.length().then((size) {
          if (mounted) {
            setState(() {
              _exportedPath = params.outputPath;
              _exportedSize = size;
              _isExporting = false;
            });
          }
        });
      } else if (result is AppError<ExportParams>) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Export failed: ${result.error.message}'),
              backgroundColor: AppColors.error,
            ),
          );
          setState(() => _isExporting = false);
        }
      }
    } catch (e) {
      AppLogger().e('Export error', e);
      if (mounted) {
        Navigator.of(context).pop();
        setState(() => _isExporting = false);
      }
    }
  }
}
