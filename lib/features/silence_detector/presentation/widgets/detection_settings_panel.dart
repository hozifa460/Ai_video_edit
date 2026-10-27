import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_colors.dart';
import '../controllers/editor_detection_controller.dart';
import '../../domain/entities/detection_params.dart';
import '../../domain/providers/silence_detection_provider.dart';

class DetectionSettingsPanel extends ConsumerWidget {
  final VoidCallback? onAutoDetect;
  final EditorDetectionController? controller;

  const DetectionSettingsPanel({super.key, this.onAutoDetect, this.controller});

  void _apply(void Function(EditorDetectionController c) viaController,
      void Function() viaProvider) {
    if (controller != null) {
      viaController(controller!);
    } else {
      viaProvider();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DetectionParams params = controller != null
        ? controller!.params
        : ref.watch(detectionParamsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Detection Settings',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (onAutoDetect != null)
                  TextButton.icon(
                    onPressed: onAutoDetect,
                    icon: const Icon(Icons.auto_fix_high, size: 16),
                    label: const Text('Auto', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _ThresholdSlider(params: params, controller: controller, ref: ref),
            const SizedBox(height: 8),
            _MinDurationSlider(params: params, controller: controller, ref: ref),
            const SizedBox(height: 8),
            _PaddingSlider(
              label: 'Speech Guard Before',
              value: params.paddingBefore,
              onChanged: (v) => _apply(
                (c) => c.updatePaddingBefore(v),
                () => ref
                    .read(detectionParamsProvider.notifier)
                    .updatePaddingBefore(v),
              ),
            ),
            const SizedBox(height: 8),
            _PaddingSlider(
              label: 'Speech Guard After',
              value: params.paddingAfter,
              onChanged: (v) => _apply(
                (c) => c.updatePaddingAfter(v),
                () => ref
                    .read(detectionParamsProvider.notifier)
                    .updatePaddingAfter(v),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Guards are kept inside each detected silence so the edges of a '
                'word are never cut. Raising a guard removes less audio.',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Voice Activity Detection',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              subtitle: const Text(
                'Filter non-speech noise',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
              ),
              value: params.useVad,
              activeTrackColor: AppColors.primary,
              onChanged: (_) => _apply(
                (c) => c.toggleVad(),
                () => ref.read(detectionParamsProvider.notifier).toggleVad(),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Breathing Protection',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              subtitle: const Text(
                'Preserve natural pauses & breaths',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
              ),
              value: params.useBreathingProtection,
              activeTrackColor: AppColors.primary,
              onChanged: (_) => _apply(
                (c) => c.toggleBreathingProtection(),
                () => ref
                    .read(detectionParamsProvider.notifier)
                    .toggleBreathingProtection(),
              ),
            ),
            const Divider(color: AppColors.divider, height: 1),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Smart Zoom',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              subtitle: const Text(
                'Auto zoom in/out on jump cuts',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
              ),
              value: params.smartZoom.enabled,
              activeTrackColor: AppColors.primary,
              onChanged: (_) => _apply(
                (c) => c.toggleSmartZoom(),
                () => ref
                    .read(detectionParamsProvider.notifier)
                    .toggleSmartZoom(),
              ),
            ),
            if (params.smartZoom.enabled)
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Zoom Amount',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '${(params.smartZoom.zoomAmount * 100).round()}%',
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: params.smartZoom.zoomAmount,
                      min: 1.01,
                      max: 1.20,
                      divisions: 19,
                      onChanged: (v) => _apply(
                        (c) => c.setSmartZoomAmount(v),
                        () => ref
                            .read(detectionParamsProvider.notifier)
                            .setSmartZoomAmount(v),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ThresholdSlider extends StatelessWidget {
  final dynamic params;
  final EditorDetectionController? controller;
  final WidgetRef ref;

  const _ThresholdSlider({
    required this.params,
    required this.controller,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Silence Threshold',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            Text(
              '${params.silenceThreshold.toStringAsFixed(0)} dB',
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        Slider(
          value: params.silenceThreshold,
          min: AppConstants.minSilenceThreshold,
          max: AppConstants.maxSilenceThreshold,
          divisions: 80,
          onChanged: (v) {
            if (controller != null) {
              controller!.updateThreshold(v);
            } else {
              ref
                  .read(detectionParamsProvider.notifier)
                  .updateThreshold(v);
            }
          },
        ),
      ],
    );
  }
}

class _MinDurationSlider extends StatelessWidget {
  final dynamic params;
  final EditorDetectionController? controller;
  final WidgetRef ref;

  const _MinDurationSlider({
    required this.params,
    required this.controller,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Min Silence Duration',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            Text(
              '${(params.minSilenceDuration * 1000).toStringAsFixed(0)} ms',
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        Slider(
          value: params.minSilenceDuration,
          min: AppConstants.minSilenceDuration,
          max: AppConstants.maxSilenceDuration,
          divisions: 499,
          onChanged: (v) {
            if (controller != null) {
              controller!.updateMinDuration(v);
            } else {
              ref
                  .read(detectionParamsProvider.notifier)
                  .updateMinDuration(v);
            }
          },
        ),
      ],
    );
  }
}

class _PaddingSlider extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _PaddingSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            Text(
              '${(value * 1000).toStringAsFixed(0)} ms',
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        Slider(
          value: value,
          min: AppConstants.minPadding,
          max: AppConstants.maxPadding,
          divisions: 50,
          onChanged: onChanged,
        ),
      ],
    );
  }
}