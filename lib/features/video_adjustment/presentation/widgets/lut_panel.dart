import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../providers/adjustment_provider.dart';

class LutPanel extends ConsumerWidget {
  final VoidCallback onChanged;

  const LutPanel({super.key, required this.onChanged});

  static const builtInLuts = [
    _LutInfo('Natural', null),
    _LutInfo('Warm', null),
    _LutInfo('Cool', null),
    _LutInfo('Dramatic', null),
    _LutInfo('Pastel', null),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(adjustmentProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 16, bottom: 8),
          child: Text('LUT Filters', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF9E9EB0))),
        ),
        SizedBox(
          height: 80,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              ...builtInLuts.map((lut) => _LutTile(
                label: lut.name,
                isSelected: false,
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Built-in LUTs require .cube files in assets')),
                  );
                },
              )),
              _LutTile(
                label: 'Import .cube',
                icon: Icons.add,
                isSelected: false,
                onTap: () async {
                  final result = await FilePicker.pickFiles(
                    type: FileType.any,
                    allowMultiple: false,
                  );
                  if (!context.mounted) return;
                  if (result != null && result.files.single.path != null) {
                    final path = result.files.single.path!;
                    if (path.endsWith('.cube')) {
                      ref.read(adjustmentProvider.notifier).applyLut(path);
                      onChanged();
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please select a .cube LUT file')),
                      );
                    }
                  }
                },
              ),
              if (settings.lutPath != null)
                _LutTile(
                  label: 'Clear LUT',
                  icon: Icons.close,
                  isSelected: false,
                  onTap: () {
                    ref.read(adjustmentProvider.notifier).clearLut();
                    onChanged();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LutInfo {
  final String name;
  final String? path;
  const _LutInfo(this.name, this.path);
}

class _LutTile extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _LutTile({
    required this.label,
    this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        margin: const EdgeInsets.only(right: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withValues(alpha: 0.2) : AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(10),
          border: isSelected ? Border.all(color: AppColors.primary) : Border.all(color: AppColors.cardBorder),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon ?? Icons.filter_vintage, size: 22, color: isSelected ? AppColors.primary : AppColors.textSecondary),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 10, color: isSelected ? AppColors.primary : AppColors.textSecondary), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
