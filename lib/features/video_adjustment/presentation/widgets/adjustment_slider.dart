import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

class AdjustmentSlider extends StatelessWidget {
  final String label;
  final IconData icon;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final bool isModified;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final VoidCallback? onReset;
  final String? defaultValueLabel;

  const AdjustmentSlider({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    this.divisions = 100,
    required this.displayValue,
    this.isModified = false,
    required this.onChanged,
    this.onChangeEnd,
    this.onReset,
    this.defaultValueLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        color: isModified ? AppColors.primary.withValues(alpha: 0.08) : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: isModified
            ? Border.all(color: AppColors.primary.withValues(alpha: 0.3))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: isModified ? AppColors.primary : AppColors.textSecondary),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: isModified ? AppColors.textPrimary : AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: isModified ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onReset,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isModified ? AppColors.primary.withValues(alpha: 0.15) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    displayValue,
                    style: TextStyle(
                      color: isModified ? AppColors.primaryLight : AppColors.textTertiary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (isModified && onReset != null) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: onReset,
                  child: const Icon(Icons.restart_alt, size: 16, color: AppColors.textTertiary),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: isModified ? AppColors.primary : AppColors.textTertiary,
              inactiveTrackColor: AppColors.surfaceLighter,
              thumbColor: isModified ? AppColors.primary : AppColors.textSecondary,
              overlayColor: AppColors.primary.withValues(alpha: 0.15),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd ?? (_) {},
            ),
          ),
        ],
      ),
    );
  }
}
