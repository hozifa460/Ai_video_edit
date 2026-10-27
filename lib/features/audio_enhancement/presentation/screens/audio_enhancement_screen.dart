import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/level.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/logger.dart';
import '../../data/services/audio_enhancement_filter_builder.dart';
import '../../data/services/audio_preview_command_builder.dart';
import '../../data/services/auto_noise_detector.dart';

enum AudioEnhancePreset {
  autoDetect,
  voice,
  music,
  podcast,
  bgRemove,
  fineTune,
}

class _PresetValues {
  final int noiseFloor; // -60 to -20
  final double gateAmount; // 0-100
  final double deesser; // 0-100 (equalizer cut at 8kHz)
  final double bass;
  final double mid;
  final double presence;
  final double treble;
  final double volume;

  const _PresetValues({
    this.noiseFloor = -45,
    this.gateAmount = 50,
    this.deesser = 0,
    this.bass = 0,
    this.mid = 0,
    this.presence = 0,
    this.treble = 5,
    this.volume = 100,
  });
}

const _presetConfigs = {
  AudioEnhancePreset.autoDetect: _PresetValues(),
  AudioEnhancePreset.voice: _PresetValues(
    noiseFloor: -45,
    gateAmount: 40,
    deesser: 50,
    bass: 0,
    mid: 4,
    presence: 4,
    treble: 3,
    volume: 100,
  ),
  AudioEnhancePreset.music: _PresetValues(
    noiseFloor: -50,
    gateAmount: 20,
    deesser: 0,
    bass: 2,
    mid: 0,
    presence: 1,
    treble: 4,
    volume: 100,
  ),
  AudioEnhancePreset.podcast: _PresetValues(
    noiseFloor: -40,
    gateAmount: 60,
    deesser: 40,
    bass: 2,
    mid: 5,
    presence: 3,
    treble: 4,
    volume: 100,
  ),
  AudioEnhancePreset.bgRemove: _PresetValues(
    noiseFloor: -28,
    gateAmount: 85,
    deesser: 30,
    bass: -1,
    mid: 4,
    presence: 6,
    treble: 2,
    volume: 100,
  ),
};

class AudioEnhancementScreen extends StatefulWidget {
  final String audioPath;

  const AudioEnhancementScreen({super.key, required this.audioPath});

  @override
  State<AudioEnhancementScreen> createState() => _AudioEnhancementScreenState();
}

class _AudioEnhancementScreenState extends State<AudioEnhancementScreen> {
  bool _isProcessing = false;
  bool _isPreviewing = false;
  final ValueNotifier<double> _progress = ValueNotifier(0.0);
  final ValueNotifier<String> _progressLabel = ValueNotifier('');
  VideoPlayerController? _previewController;
  VideoPlayerController? _origPreviewController;
  String? _previewPath;
  String? _origPreviewPath;

  AudioEnhancePreset _preset = AudioEnhancePreset.autoDetect;
  int _noiseFloor = -45;
  double _gateAmount = 50;
  double _deesser = 0;
  double _bassBoost = 0;
  double _midBoost = 4;
  double _presence = 4;
  double _trebleBoost = 3;
  double _volume = 100;

  @override
  void initState() {
    super.initState();
    _applyBuiltinPreset(AudioEnhancePreset.autoDetect);
  }

  @override
  void dispose() {
    _progress.dispose();
    _progressLabel.dispose();
    _previewController?.dispose();
    _origPreviewController?.dispose();
    if (_previewPath != null) File(_previewPath!).delete().ignore();
    if (_origPreviewPath != null) File(_origPreviewPath!).delete().ignore();
    super.dispose();
  }

  String get _fileName => widget.audioPath.split('/').last.split('\\').last;

  String _normalizePath(String path) => path.replaceAll('\\', '/');

  void _applyBuiltinPreset(AudioEnhancePreset preset) {
    final cfg = _presetConfigs[preset] ?? _PresetValues();
    setState(() {
      _preset = preset;
      _gateAmount = cfg.gateAmount;
      _deesser = cfg.deesser;
      _bassBoost = cfg.bass;
      _midBoost = cfg.mid;
      _presence = cfg.presence;
      _trebleBoost = cfg.treble;
      _volume = cfg.volume;
      _noiseFloor = cfg.noiseFloor;
    });
  }

  Future<void> _runAutoDetect() async {
    _progressLabel.value = 'Analyzing noise floor...';
    final detected = await AutoNoiseDetector.detectNoiseFloor(widget.audioPath);
    _applyBuiltinPreset(AudioEnhancePreset.autoDetect);
    setState(() => _noiseFloor = detected);
    AppLogger().i('Auto noise floor: $detected dB');
  }

  Future<void> _detectAndApply() async {
    setState(() => _isProcessing = true);
    await _runAutoDetect();
    setState(() {
      _preset = AudioEnhancePreset.fineTune;
      _isProcessing = false;
    });
  }

  void _onSliderChanged() {
    _preset = AudioEnhancePreset.fineTune;
  }

  String _buildAudioFilter() {
    return AudioEnhancementFilterBuilder.build(
      noiseFloor: _noiseFloor,
      gateAmount: _gateAmount,
      deesser: _deesser,
      bass: _bassBoost,
      mid: _midBoost,
      presence: _presence,
      treble: _trebleBoost,
      volume: _volume,
    );
  }

  String _buildCommand(String outputPath) {
    final af = _buildAudioFilter();
    final afPart = af.isNotEmpty ? '-af "$af" ' : '';
    return '-i "${_normalizePath(widget.audioPath)}" -vn '
        '$afPart'
        '-c:a aac -b:a 256k '
        '-y "${_normalizePath(outputPath)}"';
  }

  String _buildPreviewCommand(String outputPath) {
    return AudioPreviewCommandBuilder.buildEnhancedPreviewCommand(
      inputPath: widget.audioPath,
      outputPath: outputPath,
      audioFilter: _buildAudioFilter(),
    );
  }

  String _buildOriginalPreviewCommand(String outputPath) {
    return AudioPreviewCommandBuilder.buildOriginalPreviewCommand(
      inputPath: widget.audioPath,
      outputPath: outputPath,
    );
  }

  Future<void> _previewAudio() async {
    if (_isPreviewing || _isProcessing) return;
    setState(() => _isPreviewing = true);
    await Future.delayed(const Duration(milliseconds: 50));

    try {
      final tempDir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final previewPath = '${tempDir.path}/audio_preview_$ts.m4a';
      final origPreviewPath = '${tempDir.path}/audio_original_preview_$ts.m4a';
      final originalCmd = _buildOriginalPreviewCommand(origPreviewPath);
      final cmd = _buildPreviewCommand(previewPath);
      AppLogger().i('Audio original preview: $originalCmd');
      AppLogger().i('Audio preview: $cmd');

      final originalSession = await FFmpegKit.execute(originalCmd);
      final originalRc = await originalSession.getReturnCode();
      if (!ReturnCode.isSuccess(originalRc) ||
          !File(origPreviewPath).existsSync()) {
        final logs = await originalSession.getAllLogsAsString() ?? '';
        throw Exception(
          'Original preview failed: ${_shortFfmpegError(logs, originalRc)}',
        );
      }
      await _ensurePlayablePreview(origPreviewPath, 'Original');

      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();

      if (!ReturnCode.isSuccess(rc) || !File(previewPath).existsSync()) {
        final logs = await session.getAllLogsAsString() ?? '';
        final failTrace = await session.getFailStackTrace() ?? '';
        AppLogger().e('Preview failed — rc: $rc');
        AppLogger().e('Logs: $logs');
        if (failTrace.isNotEmpty) AppLogger().e('Fail trace: $failTrace');
        if (mounted) {
          final errMsg = logs.isNotEmpty
              ? _shortFfmpegError(logs, rc)
              : 'Exit code: $rc';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Preview failed: $errMsg'),
              backgroundColor: AppColors.error,
              duration: const Duration(seconds: 8),
            ),
          );
        }
        return;
      }
      await _ensurePlayablePreview(previewPath, 'Enhanced');

      if (!mounted) return;

      final origCtrl = VideoPlayerController.file(File(origPreviewPath));
      final enhCtrl = VideoPlayerController.file(File(previewPath));
      await Future.wait([origCtrl.initialize(), enhCtrl.initialize()]);

      _origPreviewController?.dispose();
      _previewController?.dispose();
      if (_previewPath != null) File(_previewPath!).delete().ignore();
      if (_origPreviewPath != null) File(_origPreviewPath!).delete().ignore();
      _origPreviewController = origCtrl;
      _previewController = enhCtrl;
      _previewPath = previewPath;
      _origPreviewPath = origPreviewPath;

      if (!mounted) return;
      _showPreviewDialog();
    } catch (e, stack) {
      AppLogger().e('Preview error', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Preview error: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPreviewing = false);
    }
  }

  String _shortFfmpegError(String logs, Object? rc) {
    final lines = logs
        .split('\n')
        .where(
          (l) =>
              l.contains('Error') ||
              l.contains('error') ||
              l.contains('Invalid') ||
              l.contains('No such') ||
              l.contains('failed'),
        )
        .take(2)
        .join('\n');
    return lines.isNotEmpty ? lines : 'Exit code: $rc';
  }

  Future<void> _ensurePlayablePreview(String path, String label) async {
    final probe = await FFprobeKit.getMediaInformation(path);
    final info = probe.getMediaInformation();
    final duration = double.tryParse(info?.getDuration() ?? '') ?? 0;
    final streams = info?.getStreams() ?? const [];
    final hasAudio = streams.any((stream) => stream.getType() == 'audio');
    if (!hasAudio || duration <= 0.05) {
      final logs = await probe.getAllLogsAsString() ?? '';
      AppLogger().e('$label preview is not playable. Logs: $logs');
      throw Exception('$label preview has no playable audio stream');
    }
  }

  void _showPreviewDialog() {
    final origCtrl = _origPreviewController!;
    final enhCtrl = _previewController!;
    enhCtrl.play();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        var showOriginal = false;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: AppColors.surface,
            content: StatefulBuilder(
              builder: (context, setInnerState) {
                final active = showOriginal ? origCtrl : enhCtrl;
                return SizedBox(
                  width: double.maxFinite,
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: active,
                    builder: (context, value, _) {
                      final pos = value.position;
                      final dur = value.duration;
                      final progress = dur.inMilliseconds > 0
                          ? pos.inMilliseconds / dur.inMilliseconds
                          : 0.0;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              _previewTab('Original', showOriginal, () {
                                if (showOriginal) return;
                                enhCtrl.pause();
                                origCtrl.seekTo(Duration.zero);
                                origCtrl.play();
                                showOriginal = true;
                                setInnerState(() {});
                              }),
                              const SizedBox(width: 8),
                              _previewTab('Enhanced', !showOriginal, () {
                                if (!showOriginal) return;
                                origCtrl.pause();
                                enhCtrl.seekTo(Duration.zero);
                                enhCtrl.play();
                                showOriginal = false;
                                setInnerState(() {});
                              }),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppColors.cardBorder),
                            ),
                            child: Column(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: progress.clamp(0.0, 1.0),
                                    minHeight: 8,
                                    backgroundColor: AppColors.surfaceLighter,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                          AppColors.primary,
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${pos.inSeconds}s / ${dur.inSeconds}s',
                                  style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: Icon(
                                  value.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: AppColors.textPrimary,
                                ),
                                onPressed: () {
                                  value.isPlaying
                                      ? active.pause()
                                      : active.play();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                origCtrl.pause();
                                enhCtrl.pause();
                                Navigator.of(ctx).pop();
                              },
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('Apply to full audio'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                textStyle: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
      },
    ).then((_) {
      origCtrl.pause();
      enhCtrl.pause();
    });
  }

  Widget _previewTab(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.08)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.cardBorder,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? Icons.visibility : Icons.visibility_off,
                size: 14,
                color: selected ? AppColors.primary : AppColors.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showProgressDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text(
                  'Enhancing audio...',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 20),
                ValueListenableBuilder<double>(
                  valueListenable: _progress,
                  builder: (context, progress, _) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: progress > 0 ? progress : null,
                        minHeight: 10,
                        backgroundColor: AppColors.surfaceLighter,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<String>(
                  valueListenable: _progressLabel,
                  builder: (context, label, _) {
                    return Text(
                      label.isNotEmpty ? label : 'Preset: ${_preset.name}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _process() async {
    setState(() => _isProcessing = true);
    _progress.value = 0.0;
    _progressLabel.value = 'Probing audio...';

    try {
      final dir = await FileUtils.getExportDirectory();
      final baseName = _fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
      final outputPath = '${dir.path}/${baseName}_enhanced.m4a';

      if (!mounted) return;

      double totalDurationSec = 0;
      try {
        final probe = await FFprobeKit.getMediaInformation(widget.audioPath);
        final durStr = probe.getMediaInformation()?.getDuration();
        if (durStr != null && durStr.isNotEmpty) {
          totalDurationSec = double.tryParse(durStr) ?? 0;
        }
      } catch (_) {}

      if (!mounted) return;
      _showProgressDialog();

      final logBuffer = StringBuffer();
      FFmpegKitConfig.enableLogCallback((Log log) {
        logBuffer.write(log.getMessage());
      });
      FFmpegKitConfig.setLogLevel(Level.avLogVerbose);

      final cmd = _buildCommand(outputPath);
      AppLogger().i('Audio enhance: $cmd');

      final completer = Completer<void>();
      FFmpegKitConfig.enableStatisticsCallback((Statistics s) {
        final timeMs = s.getTime();
        if (timeMs > 0 && totalDurationSec > 0) {
          final p = (timeMs / 1000.0) / totalDurationSec;
          _progress.value = p.clamp(0.0, 1.0);
          _progressLabel.value = '${(p * 100).round()}%';
        }
      });

      final session = await FFmpegKit.executeAsync(
        cmd,
        (_) => completer.complete(),
      );
      await completer.future;
      if (!mounted) {
        FFmpegKit.cancel();
        return;
      }

      FFmpegKitConfig.setLogLevel(Level.avLogInfo);

      final rc = await session.getReturnCode();
      final logs = logBuffer.isEmpty
          ? (await session.getAllLogsAsString()) ?? ''
          : logBuffer.toString();
      final failTrace = await session.getFailStackTrace() ?? '';

      if (mounted) Navigator.of(context).pop();

      if (ReturnCode.isSuccess(rc)) {
        final outputFile = File(outputPath);
        if (await outputFile.exists() && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved: ${baseName}_enhanced.m4a'),
              backgroundColor: AppColors.success,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } else {
        AppLogger().e('Audio enhance failed — rc: $rc');
        AppLogger().e('Logs: $logs');
        if (failTrace.isNotEmpty) AppLogger().e('Fail trace: $failTrace');
        if (mounted) {
          final errMsg = logs.isNotEmpty
              ? logs
                    .split('\n')
                    .where(
                      (l) =>
                          l.contains('Error') ||
                          l.contains('error') ||
                          l.contains('Invalid') ||
                          l.contains('No such'),
                    )
                    .take(2)
                    .join('\n')
              : 'FFmpeg exit code: $rc';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errMsg.isNotEmpty ? errMsg : 'Enhancement failed'),
              backgroundColor: AppColors.error,
              duration: const Duration(seconds: 6),
            ),
          );
        }
      }
    } catch (e, stack) {
      AppLogger().e('Audio enhance error', e, stack);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      FFmpegKitConfig.enableStatisticsCallback(null);
      FFmpegKitConfig.setLogLevel(Level.avLogInfo);
      if (mounted) setState(() => _isProcessing = false);
      _progress.value = 0.0;
      _progressLabel.value = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Audio Enhancer'),
        backgroundColor: AppColors.surface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFileInfo(),
            const SizedBox(height: 14),
            const Text('Preset', style: _sectionStyle),
            const SizedBox(height: 8),
            _buildPresetRow(),
            const SizedBox(height: 16),
            if (_preset == AudioEnhancePreset.autoDetect)
              _buildAutoDetectBanner(),
            const SizedBox(height: 4),
            const Text('Noise & Gate', style: _sectionStyle),
            const SizedBox(height: 6),
            _slider(
              label: 'Noise Floor',
              value: (_noiseFloor + 60) * (100 / 40).toDouble(),
              display: '$_noiseFloor dB',
              onChanged: (v) {
                setState(() {
                  _noiseFloor = (v * 40 / 100 - 60).round();
                  _onSliderChanged();
                });
              },
            ),
            _slider(
              label: 'Gate/Expander',
              value: _gateAmount,
              display: '${_gateAmount.round()}%',
              onChanged: (v) {
                setState(() {
                  _gateAmount = v;
                  _onSliderChanged();
                });
              },
            ),
            _slider(
              label: 'De-esser',
              value: _deesser,
              display: _deesser == 0 ? 'Off' : '${_deesser.round()}%',
              onChanged: (v) {
                setState(() {
                  _deesser = v;
                  _onSliderChanged();
                });
              },
            ),
            const SizedBox(height: 10),
            const Text('Equalizer', style: _sectionStyle),
            const SizedBox(height: 6),
            _slider(
              label: 'Bass 80Hz',
              value: (_bassBoost + 12) * (100 / 24),
              display:
                  '${_bassBoost >= 0 ? "+" : ""}${_bassBoost.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() {
                  _bassBoost = v * (24 / 100) - 12;
                  _onSliderChanged();
                });
              },
            ),
            _slider(
              label: 'Mid 1kHz',
              value: (_midBoost + 12) * (100 / 24),
              display:
                  '${_midBoost >= 0 ? '+' : ''}${_midBoost.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() {
                  _midBoost = v * (24 / 100) - 12;
                  _onSliderChanged();
                });
              },
            ),
            _slider(
              label: 'Presence 3kHz',
              value: (_presence + 12) * (100 / 24),
              display:
                  '${_presence >= 0 ? '+' : ''}${_presence.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() {
                  _presence = v * (24 / 100) - 12;
                  _onSliderChanged();
                });
              },
            ),
            _slider(
              label: 'Treble 8kHz',
              value: (_trebleBoost + 12) * (100 / 24),
              display:
                  '${_trebleBoost >= 0 ? '+' : ''}${_trebleBoost.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() {
                  _trebleBoost = v * (24 / 100) - 12;
                  _onSliderChanged();
                });
              },
            ),
            const SizedBox(height: 10),
            const Text('Output', style: _sectionStyle),
            const SizedBox(height: 6),
            _slider(
              label: 'Volume',
              value: _volume / 2,
              display: '${_volume.round()}%',
              onChanged: (v) {
                setState(() {
                  _volume = v * 2;
                  _onSliderChanged();
                });
              },
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isPreviewing || _isProcessing)
                        ? null
                        : _previewAudio,
                    icon: _isPreviewing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.play_arrow, size: 20),
                    label: Text(
                      _isPreviewing ? 'Generating...' : 'Preview 12s',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surface,
                      foregroundColor: AppColors.textPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: const BorderSide(color: AppColors.cardBorder),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: (_isProcessing || _isPreviewing)
                        ? null
                        : _process,
                    icon: _isProcessing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.auto_fix_high, size: 20),
                    label: Text(
                      _isProcessing ? 'Processing...' : 'Export Full',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileInfo() {
    return Card(
      color: AppColors.surface,
      child: ListTile(
        dense: true,
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.audiotrack,
            size: 18,
            color: AppColors.primary,
          ),
        ),
        title: Text(
          _fileName,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'Audio file',
          style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
        ),
      ),
    );
  }

  Widget _buildAutoDetectBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Auto noise floor: $_noiseFloor dB. Tap Analyze to re-detect.',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ),
          TextButton(
            onPressed: _detectAndApply,
            child: const Text('Analyze', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetRow() {
    final presets = [
      (AudioEnhancePreset.autoDetect, Icons.auto_awesome, 'Auto'),
      (AudioEnhancePreset.voice, Icons.mic, 'Voice'),
      (AudioEnhancePreset.music, Icons.music_note, 'Music'),
      (AudioEnhancePreset.podcast, Icons.podcasts, 'Podcast'),
      (AudioEnhancePreset.bgRemove, Icons.people_outline, 'Bg Remove'),
    ];
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: presets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final (preset, icon, label) = presets[i];
          final selected = _preset == preset;
          return GestureDetector(
            onTap: preset == AudioEnhancePreset.autoDetect
                ? () async {
                    _applyBuiltinPreset(preset);
                    await _runAutoDetect();
                  }
                : () => _applyBuiltinPreset(preset),
            child: Container(
              width: 64,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.08)
                    : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? AppColors.primary : AppColors.cardBorder,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: selected
                        ? AppColors.primary
                        : AppColors.textTertiary,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    style: TextStyle(
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 10,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static const _sectionStyle = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );

  Widget _slider({
    required String label,
    required double value,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                display,
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 28,
            child: Slider(
              value: value.clamp(0, 100),
              onChanged: onChanged,
              min: 0,
              max: 100,
              divisions: 100,
              activeColor: AppColors.primary,
              inactiveColor: AppColors.surfaceLighter,
            ),
          ),
        ],
      ),
    );
  }
}
