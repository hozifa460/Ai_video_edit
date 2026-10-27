import 'dart:async';
import 'dart:io';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/result.dart';
import '../../../audio_processing/data/repositories/audio_processor_repository_impl.dart';
import '../../../audio_processing/domain/entities/waveform_data.dart';
import '../../../video_import/data/repositories/video_import_repository_impl.dart';
import '../../data/services/professional_audio_editor_service.dart';

class AudioEditorScreen extends StatefulWidget {
  final String audioPath;
  final Duration? duration;

  const AudioEditorScreen({super.key, required this.audioPath, this.duration});

  @override
  State<AudioEditorScreen> createState() => _AudioEditorScreenState();
}

class _AudioEditorScreenState extends State<AudioEditorScreen> {
  final _service = const ProfessionalAudioEditorService();
  final _audioRepository = AudioProcessorRepositoryImpl();
  final _player = ja.AudioPlayer();
  final _waveController = PlayerController();
  final _undoStack = <_AudioEditSnapshot>[];
  final _redoStack = <_AudioEditSnapshot>[];

  WaveformData? _waveform;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  StreamSubscription<Duration>? _positionSub;

  double _startSeconds = 0;
  double _endSeconds = 1;
  double _zoom = 1;
  List<double> _cutPoints = [];
  bool _noiseReduction = false;
  bool _voiceEnhancement = false;
  bool _isLoading = true;
  bool _isProcessing = false;
  _DragTarget? _dragTarget;
  double _rangeDragOffset = 0;

  String get _fileName => widget.audioPath.split('/').last.split('\\').last;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _player.dispose();
    _waveController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      if (!ProfessionalAudioEditorService.isSupportedAudioPath(
        widget.audioPath,
      )) {
        throw Exception('Unsupported audio format');
      }

      final playerDuration = await _player.setFilePath(widget.audioPath);
      _duration = await _resolveDuration(playerDuration);
      _endSeconds = _duration.inMilliseconds > 0
          ? _duration.inMilliseconds / 1000
          : 1;
      _positionSub = _player.positionStream.listen((position) {
        if (!mounted) return;
        if (_player.playing && position.inMilliseconds / 1000 >= _endSeconds) {
          _player.pause();
        }
        setState(() => _position = position);
      });

      final result = await _audioRepository.analyzeWaveform(widget.audioPath);
      if (!mounted) return;
      switch (result) {
        case Success<WaveformData>(value: final data):
          setState(() => _waveform = data);
        case AppError<WaveformData>(error: final error):
          AppLogger().e('Audio editor waveform failed: $error');
      }
    } catch (e, stack) {
      AppLogger().e('Audio editor init failed', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Audio editor failed: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<Duration> _resolveDuration(Duration? playerDuration) async {
    final provided = widget.duration;
    if (provided != null && provided.inMilliseconds > 0) return provided;
    if (playerDuration != null && playerDuration.inMilliseconds > 0) {
      return playerDuration;
    }

    final probe = await FFprobeKit.getMediaInformation(widget.audioPath);
    return VideoImportRepositoryImpl.parseFfprobeDuration(
      probe.getMediaInformation()?.getDuration(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Professional Audio Editor'),
        backgroundColor: AppColors.surface,
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: _undoStack.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: _redoStack.isEmpty ? null : _redo,
            icon: const Icon(Icons.redo),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 14),
                  _buildWaveformEditor(),
                  const SizedBox(height: 14),
                  _buildTransport(),
                  const SizedBox(height: 14),
                  _buildSelectionInfo(),
                  const SizedBox(height: 14),
                  _buildEditTools(),
                  const SizedBox(height: 14),
                  _buildSmartTools(),
                  const SizedBox(height: 14),
                  _buildEnhancementTools(),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panelDecoration(),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.graphic_eq, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_fmt(_duration.inMilliseconds / 1000)} • MP3 WAV AAC M4A',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaveformEditor() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: _panelDecoration(),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth * _zoom;
              return ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) =>
                        _seekFromDx(details.localPosition.dx, width),
                    onPanStart: (details) =>
                        _startDrag(details.localPosition.dx, width),
                    onPanUpdate: (details) =>
                        _updateDrag(details.localPosition.dx, width),
                    onPanEnd: (_) => _dragTarget = null,
                    onPanCancel: () => _dragTarget = null,
                    child: SizedBox(
                      width: width,
                      height: 184,
                      child: Stack(
                        children: [
                          AudioFileWaveforms(
                            size: Size(width, 184),
                            playerController: _waveController,
                            waveformData: (_waveform?.samples ?? const [])
                                .map((v) => v.clamp(0.02, 1.0).toDouble())
                                .toList(),
                            enableSeekGesture: false,
                            playerWaveStyle: const PlayerWaveStyle(
                              fixedWaveColor: AppColors.textTertiary,
                              liveWaveColor: AppColors.primary,
                              seekLineColor: Colors.transparent,
                              waveThickness: 3,
                              spacing: 6,
                              scaleFactor: 70,
                              showSeekLine: false,
                            ),
                          ),
                          CustomPaint(
                            size: Size(width, 184),
                            painter: _AudioOverlayPainter(
                              startSeconds: _startSeconds,
                              endSeconds: _endSeconds,
                              cutPoints: _cutPoints,
                              playheadSeconds: _position.inMilliseconds / 1000,
                              durationSeconds: _durationSeconds,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.zoom_out, color: AppColors.textSecondary),
              Expanded(
                child: Slider(
                  value: _zoom,
                  min: 1,
                  max: 8,
                  divisions: 28,
                  activeColor: AppColors.primary,
                  inactiveColor: AppColors.surfaceLighter,
                  onChanged: (value) => setState(() => _zoom = value),
                ),
              ),
              const Icon(Icons.zoom_in, color: AppColors.textSecondary),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTransport() {
    return StreamBuilder<ja.PlayerState>(
      stream: _player.playerStateStream,
      builder: (context, snapshot) {
        final playing = snapshot.data?.playing ?? _player.playing;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: _panelDecoration(),
          child: Row(
            children: [
              IconButton.filled(
                onPressed: _togglePlay,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: LinearProgressIndicator(
                  value:
                      (_durationSeconds > 0
                              ? _position.inMilliseconds /
                                    1000 /
                                    _durationSeconds
                              : 0)
                          .clamp(0.0, 1.0)
                          .toDouble(),
                  minHeight: 8,
                  backgroundColor: AppColors.surfaceLighter,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_fmt(_position.inMilliseconds / 1000)} / ${_fmt(_durationSeconds)}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSelectionInfo() {
    return Row(
      children: [
        Expanded(child: _metric('Start', _fmt(_startSeconds))),
        const SizedBox(width: 8),
        Expanded(child: _metric('End', _fmt(_endSeconds))),
        const SizedBox(width: 8),
        Expanded(child: _metric('Length', _fmt(_endSeconds - _startSeconds))),
      ],
    );
  }

  Widget _buildEditTools() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _panelDecoration(),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _toolButton(
                  icon: Icons.cut,
                  label: 'Trim',
                  onPressed: () => _exportTrim(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _toolButton(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  onPressed: () => _exportDelete(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _toolButton(
                  icon: Icons.add,
                  label: 'Add Split',
                  onPressed: _addCutPointAtPlayhead,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _toolButton(
                  icon: Icons.call_split,
                  label: 'Export Splits',
                  onPressed: _cutPoints.isEmpty ? null : () => _exportSplit(),
                ),
              ),
            ],
          ),
          if (_cutPoints.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _cutPoints
                  .map(
                    (point) => InputChip(
                      label: Text(_fmt(point)),
                      onDeleted: () => _removeCutPoint(point),
                      backgroundColor: AppColors.background,
                      labelStyle: const TextStyle(color: AppColors.textPrimary),
                      deleteIconColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.cardBorder),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSmartTools() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _panelDecoration(),
      child: Row(
        children: [
          Expanded(
            child: _toolButton(
              icon: Icons.auto_awesome,
              label: 'AI Silence',
              onPressed: _detectSilence,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _toolButton(
              icon: Icons.bolt,
              label: 'Smart Cut',
              onPressed: _applySmartCuts,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancementTools() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _panelDecoration(),
      child: Column(
        children: [
          SwitchListTile(
            value: _noiseReduction,
            onChanged: (value) =>
                _setSnapshot(_snapshot().copyWith(noiseReduction: value)),
            title: const Text(
              'Noise Reduction',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            activeThumbColor: AppColors.primary,
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _voiceEnhancement,
            onChanged: (value) =>
                _setSnapshot(_snapshot().copyWith(voiceEnhancement: value)),
            title: const Text(
              'Voice Enhancement',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            activeThumbColor: AppColors.primary,
            contentPadding: EdgeInsets.zero,
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_noiseReduction || _voiceEnhancement)
                  ? () => _exportEnhanced()
                  : null,
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Export Enhanced Audio'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: _panelDecoration(),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: _isProcessing ? null : onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.cardBorder),
        padding: const EdgeInsets.symmetric(vertical: 13),
      ),
    );
  }

  Future<void> _togglePlay() async {
    if (_player.playing) {
      await _player.pause();
      return;
    }
    final seconds = _position.inMilliseconds / 1000;
    if (seconds < _startSeconds || seconds >= _endSeconds) {
      await _seek(_startSeconds);
    }
    await _player.play();
  }

  Future<void> _seek(double seconds) {
    return _player.seek(Duration(milliseconds: (seconds * 1000).round()));
  }

  void _seekFromDx(double dx, double width) {
    final seconds = _secondsFromDx(dx, width);
    _seek(seconds);
  }

  void _startDrag(double dx, double width) {
    final seconds = _secondsFromDx(dx, width);
    final tolerance = (30 / width * _durationSeconds).clamp(0.08, 2.0);
    final startDistance = (seconds - _startSeconds).abs();
    final endDistance = (seconds - _endSeconds).abs();
    if (startDistance <= tolerance && startDistance <= endDistance) {
      _dragTarget = _DragTarget.start;
    } else if (endDistance <= tolerance) {
      _dragTarget = _DragTarget.end;
    } else if (seconds > _startSeconds && seconds < _endSeconds) {
      _dragTarget = _DragTarget.range;
      _rangeDragOffset = seconds - _startSeconds;
    } else {
      _dragTarget = startDistance < endDistance
          ? _DragTarget.start
          : _DragTarget.end;
      _pushUndo();
      _applyDrag(seconds);
      return;
    }
    _pushUndo();
  }

  void _updateDrag(double dx, double width) {
    _applyDrag(_secondsFromDx(dx, width));
  }

  void _applyDrag(double seconds) {
    const minLength = 0.05;
    switch (_dragTarget) {
      case _DragTarget.start:
        setState(() {
          _startSeconds = seconds
              .clamp(0.0, _endSeconds - minLength)
              .toDouble();
        });
      case _DragTarget.end:
        setState(() {
          _endSeconds = seconds
              .clamp(_startSeconds + minLength, _durationSeconds)
              .toDouble();
        });
      case _DragTarget.range:
        final length = _endSeconds - _startSeconds;
        final start = (seconds - _rangeDragOffset)
            .clamp(0.0, _durationSeconds - length)
            .toDouble();
        setState(() {
          _startSeconds = start;
          _endSeconds = start + length;
        });
      case null:
        break;
    }
  }

  double _secondsFromDx(double dx, double width) {
    if (width <= 0) return 0;
    return (dx / width * _durationSeconds)
        .clamp(0.0, _durationSeconds)
        .toDouble();
  }

  void _addCutPointAtPlayhead() {
    final point = _position.inMilliseconds / 1000;
    if (point <= 0.05 || point >= _durationSeconds - 0.05) return;
    if (_cutPoints.any((existing) => (existing - point).abs() < 0.05)) return;
    final next = [..._cutPoints, double.parse(point.toStringAsFixed(3))]
      ..sort();
    _setSnapshot(_snapshot().copyWith(cutPoints: next));
    AppLogger().i('Audio editor cut point added: $point');
  }

  void _removeCutPoint(double point) {
    _setSnapshot(
      _snapshot().copyWith(
        cutPoints: _cutPoints.where((item) => item != point).toList(),
      ),
    );
  }

  Future<void> _detectSilence() async {
    await _runWithProgress('Detecting silence...', () async {
      final regions = await _service.detectSilence(widget.audioPath);
      if (regions.isEmpty) return;
      final first = regions.first;
      _setSnapshot(
        _snapshot().copyWith(
          startSeconds: first.startSeconds,
          endSeconds: first.endSeconds,
        ),
      );
    });
  }

  Future<void> _applySmartCuts() async {
    await _runWithProgress('Finding smart cuts...', () async {
      final regions = await _service.detectSilence(widget.audioPath);
      final cuts = ProfessionalAudioEditorService.smartCutPointsFromSilence(
        regions,
      );
      if (cuts.isEmpty) return;
      _setSnapshot(_snapshot().copyWith(cutPoints: cuts));
    });
  }

  Future<void> _exportTrim() async {
    await _runWithProgress('Exporting trim...', () async {
      final output = await _outputPath('trimmed', _sourceExt);
      await _service.trim(
        inputPath: widget.audioPath,
        outputPath: output,
        startSeconds: _startSeconds,
        endSeconds: _endSeconds,
      );
      _showSaved(output);
    });
  }

  Future<void> _exportDelete() async {
    await _runWithProgress('Deleting selection...', () async {
      final output = await _outputPath('deleted', 'm4a');
      await _service.deleteRange(
        inputPath: widget.audioPath,
        outputPath: output,
        deleteStartSeconds: _startSeconds,
        deleteEndSeconds: _endSeconds,
        totalDurationSeconds: _durationSeconds,
      );
      _showSaved(output);
    });
  }

  Future<void> _exportSplit() async {
    await _runWithProgress('Exporting split parts...', () async {
      final dir = await FileUtils.getExportDirectory();
      final baseName = _baseName;
      final splitDir = Directory(
        '${dir.path}/${baseName}_audio_parts_${DateTime.now().millisecondsSinceEpoch}',
      );
      await splitDir.create(recursive: true);
      final outputs = await _service.split(
        inputPath: widget.audioPath,
        outputDirectory: splitDir.path,
        baseName: baseName,
        cutPointsSeconds: _cutPoints,
        totalDurationSeconds: _durationSeconds,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved ${outputs.length} parts'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    });
  }

  Future<void> _exportEnhanced() async {
    await _runWithProgress('Enhancing audio...', () async {
      final output = await _outputPath('enhanced', 'm4a');
      await _service.process(
        inputPath: widget.audioPath,
        outputPath: output,
        noiseReduction: _noiseReduction,
        voiceEnhancement: _voiceEnhancement,
      );
      _showSaved(output);
    });
  }

  Future<void> _runWithProgress(
    String label,
    Future<void> Function() action,
  ) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    _showProgress(label);
    try {
      await action();
    } catch (e, stack) {
      AppLogger().e('Audio editor action failed', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) Navigator.of(context).pop();
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showProgress(String label) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          content: Row(
            children: [
              const CircularProgressIndicator(color: AppColors.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _outputPath(String suffix, String ext) async {
    final dir = await FileUtils.getExportDirectory();
    return '${dir.path}/${_baseName}_${suffix}_${DateTime.now().millisecondsSinceEpoch}.$ext';
  }

  void _showSaved(String path) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved: ${path.split('/').last.split('\\').last}'),
        backgroundColor: AppColors.success,
      ),
    );
  }

  String get _baseName => _fileName.replaceAll(RegExp(r'\.[^.]+$'), '');

  String get _sourceExt => _fileName.split('.').last.toLowerCase();

  double get _durationSeconds {
    final seconds = _duration.inMilliseconds / 1000;
    return seconds > 0 ? seconds : 1;
  }

  void _pushUndo() {
    _undoStack.add(_snapshot());
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot());
    _restore(_undoStack.removeLast());
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot());
    _restore(_redoStack.removeLast());
  }

  void _setSnapshot(_AudioEditSnapshot next) {
    _pushUndo();
    _restore(next);
  }

  void _restore(_AudioEditSnapshot snapshot) {
    setState(() {
      _startSeconds = snapshot.startSeconds
          .clamp(0.0, _durationSeconds)
          .toDouble();
      _endSeconds = snapshot.endSeconds
          .clamp(_startSeconds + 0.05, _durationSeconds)
          .toDouble();
      _cutPoints = [...snapshot.cutPoints]..sort();
      _noiseReduction = snapshot.noiseReduction;
      _voiceEnhancement = snapshot.voiceEnhancement;
    });
  }

  _AudioEditSnapshot _snapshot() {
    return _AudioEditSnapshot(
      startSeconds: _startSeconds,
      endSeconds: _endSeconds,
      cutPoints: [..._cutPoints],
      noiseReduction: _noiseReduction,
      voiceEnhancement: _voiceEnhancement,
    );
  }

  String _fmt(double seconds) {
    final totalMs = (seconds * 1000).round();
    final minutes = totalMs ~/ 60000;
    final secs = (totalMs % 60000) ~/ 1000;
    final ms = (totalMs % 1000) ~/ 10;
    return '$minutes:${secs.toString().padLeft(2, '0')}.${ms.toString().padLeft(2, '0')}';
  }

  BoxDecoration _panelDecoration() {
    return BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.cardBorder),
    );
  }
}

enum _DragTarget { start, end, range }

class _AudioEditSnapshot {
  final double startSeconds;
  final double endSeconds;
  final List<double> cutPoints;
  final bool noiseReduction;
  final bool voiceEnhancement;

  const _AudioEditSnapshot({
    required this.startSeconds,
    required this.endSeconds,
    required this.cutPoints,
    required this.noiseReduction,
    required this.voiceEnhancement,
  });

  _AudioEditSnapshot copyWith({
    double? startSeconds,
    double? endSeconds,
    List<double>? cutPoints,
    bool? noiseReduction,
    bool? voiceEnhancement,
  }) {
    return _AudioEditSnapshot(
      startSeconds: startSeconds ?? this.startSeconds,
      endSeconds: endSeconds ?? this.endSeconds,
      cutPoints: cutPoints ?? this.cutPoints,
      noiseReduction: noiseReduction ?? this.noiseReduction,
      voiceEnhancement: voiceEnhancement ?? this.voiceEnhancement,
    );
  }
}

class _AudioOverlayPainter extends CustomPainter {
  final double startSeconds;
  final double endSeconds;
  final List<double> cutPoints;
  final double playheadSeconds;
  final double durationSeconds;

  const _AudioOverlayPainter({
    required this.startSeconds,
    required this.endSeconds,
    required this.cutPoints,
    required this.playheadSeconds,
    required this.durationSeconds,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final startX = _xFor(startSeconds, size.width);
    final endX = _xFor(endSeconds, size.width);
    final outside = Paint()..color = Colors.black.withValues(alpha: 0.48);
    canvas.drawRect(Rect.fromLTRB(0, 0, startX, size.height), outside);
    canvas.drawRect(Rect.fromLTRB(endX, 0, size.width, size.height), outside);

    final selected = Paint()..color = AppColors.primary.withValues(alpha: 0.10);
    canvas.drawRect(Rect.fromLTRB(startX, 0, endX, size.height), selected);

    final handle = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(startX, 0), Offset(startX, size.height), handle);
    canvas.drawLine(Offset(endX, 0), Offset(endX, size.height), handle);

    final cutPaint = Paint()
      ..color = const Color(0xFFFFC857)
      ..strokeWidth = 2;
    for (final point in cutPoints) {
      final x = _xFor(point, size.width);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), cutPaint);
    }

    final playPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5;
    final playX = _xFor(playheadSeconds, size.width);
    canvas.drawLine(Offset(playX, 0), Offset(playX, size.height), playPaint);

    final border = Paint()
      ..color = AppColors.cardBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(BorderRadius.circular(10).toRRect(rect), border);
  }

  double _xFor(double seconds, double width) {
    if (durationSeconds <= 0) return 0;
    return (seconds / durationSeconds).clamp(0.0, 1.0) * width;
  }

  @override
  bool shouldRepaint(covariant _AudioOverlayPainter oldDelegate) {
    return oldDelegate.startSeconds != startSeconds ||
        oldDelegate.endSeconds != endSeconds ||
        oldDelegate.cutPoints != cutPoints ||
        oldDelegate.playheadSeconds != playheadSeconds ||
        oldDelegate.durationSeconds != durationSeconds;
  }
}
