import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

class UndoRedoBar extends StatelessWidget {
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onReset;

  const UndoRedoBar({
    super.key,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          _button(Icons.undo, canUndo, onUndo),
          const SizedBox(width: 8),
          _button(Icons.redo, canRedo, onRedo),
          const Spacer(),
          _button(Icons.restart_alt, true, onReset, label: 'Reset'),
        ],
      ),
    );
  }

  Widget _button(IconData icon, bool enabled, VoidCallback onTap, {String? label}) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: enabled ? AppColors.surfaceLight : AppColors.surfaceLight.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: enabled ? AppColors.cardBorder : AppColors.cardBorder.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: enabled ? AppColors.textSecondary : AppColors.textTertiary),
            if (label != null) ...[
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12, color: enabled ? AppColors.textSecondary : AppColors.textTertiary)),
            ],
          ],
        ),
      ),
    );
  }
}
