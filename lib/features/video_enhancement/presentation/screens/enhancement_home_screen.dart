import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/enhancement_provider.dart';
import 'import_screen.dart';
import 'analysis_screen.dart';
import 'plan_screen.dart';
import 'preview_screen.dart';
import 'processing_screen.dart';
import 'result_screen.dart';

class EnhancementHomeScreen extends ConsumerStatefulWidget {
  final String videoPath;

  const EnhancementHomeScreen({super.key, required this.videoPath});

  @override
  ConsumerState<EnhancementHomeScreen> createState() => _EnhancementHomeScreenState();
}

class _EnhancementHomeScreenState extends ConsumerState<EnhancementHomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(enhancementProvider.notifier).setVideoPath(widget.videoPath);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(enhancementProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Video Enhancement'),
        backgroundColor: AppColors.surface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _buildScreen(state.currentScreen, state),
    );
  }

  Widget _buildScreen(EnhancementScreen screen, EnhancementState state) {
    switch (screen) {
      case EnhancementScreen.import:
        return ImportScreen(
          onVideoSelected: (path) {
            ref.read(enhancementProvider.notifier).setVideoPath(path);
          },
        );
      case EnhancementScreen.analysis:
        return AnalysisScreen(
          onAnalyze: () => ref.read(enhancementProvider.notifier).analyzeVideo(),
          isAnalyzing: state.isProcessing,
          error: state.error,
        );
      case EnhancementScreen.plan:
        return PlanScreen(
          onPreview: () => ref.read(enhancementProvider.notifier).generatePreview(),
          onEnhance: () => ref.read(enhancementProvider.notifier).startEnhancement(),
        );
      case EnhancementScreen.preview:
        return PreviewScreen(
          onBack: () => ref.read(enhancementProvider.notifier).goToPlan(),
          onEnhance: () => ref.read(enhancementProvider.notifier).startEnhancement(),
        );
      case EnhancementScreen.processing:
        return ProcessingScreen(
          onCancel: () => ref.read(enhancementProvider.notifier).cancelEnhancement(),
        );
      case EnhancementScreen.result:
        return ResultScreen(
          onBack: () => ref.read(enhancementProvider.notifier).goToPlan(),
          onDone: () => Navigator.of(context).pop(),
        );
    }
  }
}