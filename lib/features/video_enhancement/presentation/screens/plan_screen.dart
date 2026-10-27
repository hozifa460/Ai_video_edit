import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/enhancement_plan.dart';
import '../providers/enhancement_provider.dart';

class PlanScreen extends ConsumerWidget {
  final VoidCallback onPreview;
  final VoidCallback onEnhance;

  const PlanScreen({
    super.key,
    required this.onPreview,
    required this.onEnhance,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(enhancementProvider);
    final plan = state.plan;
    final settings = state.settings;

    if (plan == null) {
      return const Center(child: Text('No plan available'));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enhancement Plan',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 24),
          
          _buildSectionTitle('What will be fixed'),
          const SizedBox(height: 12),
          ...plan.actions.map((action) => _buildActionItem(
            action.name,
            action.description,
            Icons.check_circle,
            AppColors.success,
          )),

          const SizedBox(height: 24),
          _buildSectionTitle('Enhancement Level'),
          const SizedBox(height: 12),
          _buildLevelSelector(context, ref, plan.level),

          const SizedBox(height: 24),
          _buildSectionTitle('Options'),
          const SizedBox(height: 12),
          _buildToggle('Denoise', 'Remove noise and grain', settings.denoiseEnabled, 
            (v) => ref.read(enhancementProvider.notifier).toggleDenoise(v)),
          _buildToggle('Sharpen', 'Enhance edge definition', settings.sharpenEnabled,
            (v) => ref.read(enhancementProvider.notifier).toggleSharpen(v)),
          _buildToggle('Upscale', 'Increase resolution', settings.upscaleEnabled,
            (v) => ref.read(enhancementProvider.notifier).toggleUpscale(v)),
          _buildToggle('Color Grade', 'Professional color correction', settings.colorGradeEnabled,
            (v) => ref.read(enhancementProvider.notifier).toggleColorGrade(v)),
          _buildToggle('Audio Enhancement', 'Improve audio quality', settings.audioEnhanceEnabled,
            (v) => ref.read(enhancementProvider.notifier).toggleAudioEnhance(v)),

          const SizedBox(height: 24),
          _buildSectionTitle('Estimated Output'),
          const SizedBox(height: 12),
          _buildEstimateCard(plan),

          const SizedBox(height: 32),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: state.isProcessing ? null : onPreview,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: const BorderSide(color: AppColors.primary),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Preview First'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: state.isProcessing ? null : onEnhance,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: state.isProcessing 
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Enhance Now',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary,
      ),
    );
  }

  Widget _buildActionItem(String title, String subtitle, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelSelector(BuildContext context, WidgetRef ref, EnhancementLevel currentLevel) {
    return Row(
      children: EnhancementLevel.values.map((level) {
        final isSelected = level == currentLevel;
        return Expanded(
          child: GestureDetector(
            onTap: () => ref.read(enhancementProvider.notifier).setEnhancementLevel(level),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.cardBorder,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    _getLevelLabel(level),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? Colors.white : AppColors.textPrimary,
                    ),
                  ),
                  if (isSelected)
                    const Text(
                      '✓',
                      style: TextStyle(fontSize: 10, color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  String _getLevelLabel(EnhancementLevel level) {
    return switch (level) {
      EnhancementLevel.fast => 'Fast',
      EnhancementLevel.balanced => 'Balanced',
      EnhancementLevel.quality => 'Quality',
      EnhancementLevel.ultra => 'Ultra',
    };
  }

  Widget _buildToggle(String title, String subtitle, bool value, Function(bool) onChanged) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildEstimateCard(EnhancementPlan plan) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildEstimateItem(
            Icons.timer,
            '${plan.estimatedDurationSeconds}s',
            'Est. Time',
          ),
          Container(width: 1, height: 40, color: AppColors.cardBorder),
          _buildEstimateItem(
            Icons.storage,
            '${plan.estimatedOutputSizeMb}MB',
            'Est. Size',
          ),
        ],
      ),
    );
  }

  Widget _buildEstimateItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: AppColors.primary, size: 24),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}