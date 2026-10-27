import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

class BeforeAfterToggle extends StatelessWidget {
  final bool showOriginal;
  final VoidCallback onPeekStart;
  final VoidCallback onPeekEnd;

  const BeforeAfterToggle({
    super.key,
    required this.showOriginal,
    required this.onPeekStart,
    required this.onPeekEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Spacer(),
          GestureDetector(
            onTapDown: (_) => onPeekStart(),
            onTapUp: (_) => onPeekEnd(),
            onTapCancel: onPeekEnd,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: showOriginal ? AppColors.primary : AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: showOriginal ? AppColors.primary : AppColors.cardBorder,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.compare_arrows,
                    size: 18,
                    color: showOriginal ? Colors.white : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    showOriginal ? 'Release to compare' : 'Hold to peek original',
                    style: TextStyle(
                      color: showOriginal ? Colors.white : AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: showOriginal ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
