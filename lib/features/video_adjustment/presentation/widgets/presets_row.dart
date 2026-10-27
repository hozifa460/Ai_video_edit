import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/adjustment_preset.dart';
import '../providers/adjustment_provider.dart';

class PresetsRow extends ConsumerWidget {
  final VoidCallback onChanged;

  const PresetsRow({super.key, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(adjustmentProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 16, bottom: 8),
          child: Text('Presets', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF9E9EB0))),
        ),
        SizedBox(
          height: 100,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: AdjustmentPreset.builtinPresets.length,
            itemBuilder: (context, index) {
              final preset = AdjustmentPreset.builtinPresets[index];
              final isSelected = settings.presetName == preset.name;
              return GestureDetector(
                onTap: () {
                  ref.read(adjustmentProvider.notifier).applyPreset(preset);
                  onChanged();
                },
                child: Container(
                  width: 80,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary.withValues(alpha: 0.2) : AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(12),
                    border: isSelected
                        ? Border.all(color: AppColors.primary, width: 2)
                        : Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _presetIcon(preset.name),
                        size: 28,
                        color: isSelected ? AppColors.primary : AppColors.textSecondary,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        preset.name,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? AppColors.primary : AppColors.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  IconData _presetIcon(String name) {
    switch (name) {
      case 'Normal': return Icons.check_circle_outline;
      case 'Black & White': return Icons.filter_b_and_w;
      case 'Sepia': return Icons.filter_tilt_shift;
      case 'Vintage': return Icons.filter_vintage;
      case 'Cinematic': return Icons.movie;
      case 'Faded Film': return Icons.blur_linear;
      case 'Cool Tone': return Icons.ac_unit;
      case 'Warm Tone': return Icons.wb_sunny;
      case 'Dramatic': return Icons.flash_on;
      case 'Soft': return Icons.blur_on;
      case 'Vibrant': return Icons.palette;
      case 'Noir': return Icons.nightlight_round;
      default: return Icons.auto_fix_high;
    }
  }
}
