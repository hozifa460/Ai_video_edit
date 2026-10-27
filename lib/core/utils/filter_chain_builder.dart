import 'dart:math';

import '../constants/adjustment_defaults.dart';
import '../../features/video_adjustment/domain/entities/adjustment_settings.dart';
import '../../features/video_adjustment/domain/entities/color_adjustment.dart';
import '../../features/video_adjustment/domain/entities/tone_adjustment.dart';
import '../../features/video_adjustment/domain/entities/video_adjustment.dart';
import '../../features/video_adjustment/domain/entities/audio_adjustment.dart';

class FilterChainBuilder {
  final List<String> _videoFilters = [];
  final List<String> _audioFilters = [];

  AdjustmentSettings _settings;

  FilterChainBuilder(AdjustmentSettings settings) : _settings = settings;

  void updateSettings(AdjustmentSettings settings) {
    _settings = settings;
    _videoFilters.clear();
    _audioFilters.clear();
  }

  void addGeometricFilters(VideoAdjustment v) {
    if (v.rotate != 0) {
      final rotations = (v.rotate / 90).round() % 4;
      if (rotations == 1) {
        _videoFilters.add('transpose=1');
      } else if (rotations == 2) {
        _videoFilters.add('transpose=2,transpose=2');
      } else if (rotations == 3) {
        _videoFilters.add('transpose=2');
      }
    }
    if (v.flipHorizontal == 1) _videoFilters.add('hflip');
    if (v.flipVertical == 1) _videoFilters.add('vflip');
    if (v.cropWidth < 1.0 || v.cropHeight < 1.0) {
      _videoFilters.add('crop=iw*${v.cropWidth}:ih*${v.cropHeight}:iw*${v.cropX}:ih*${v.cropY}');
    }
    if (v.scaleWidth != 1.0 || v.scaleHeight != 1.0) {
      _videoFilters.add('scale=iw*${v.scaleWidth}:ih*${v.scaleHeight}:flags=bicubic');
    }
  }

  void addToneFilters(ToneAdjustment t) {
    if (!t.hasAdjustment) return;

    // Valid FFmpeg curves syntax: named option + 'x/y x/y' point pairs.
    final pts = <({double x, double y})>[];
    if (t.blacks != 0) {
      pts.add((x: 0.05, y: (0.05 + t.blacks * 0.08)));
    }
    if (t.shadows != 0) {
      pts.add((x: 0.25, y: (0.25 + t.shadows * 0.12)));
    }
    if (t.midtones != 0) {
      pts.add((x: 0.50, y: (0.50 + t.midtones * 0.15)));
    }
    if (t.highlights != 0) {
      pts.add((x: 0.75, y: (0.75 + t.highlights * 0.12)));
    }
    if (t.whites != 0) {
      pts.add((x: 0.95, y: (0.95 + t.whites * 0.05)));
    }

    if (pts.isEmpty) return;
    pts.sort((a, b) => a.x.compareTo(b.x));

    final curve = StringBuffer('0/0');
    for (final p in pts) {
      final y = p.y.clamp(0.0, 1.0);
      curve.write(' ${p.x.toStringAsFixed(2)}/${y.toStringAsFixed(3)}');
    }
    curve.write(' 1/1');

    _videoFilters.add("curves=all='$curve'");
  }

  void addColorFilters(double brightness, double contrast, double saturation, double gamma, double hue, ColorAdjustment c) {
    final eqParts = <String>[];
    if (brightness != AdjustmentDefaults.brightness) eqParts.add('brightness=${brightness.toStringAsFixed(2)}');
    if (contrast != AdjustmentDefaults.contrast) eqParts.add('contrast=${contrast.toStringAsFixed(3)}');
    if (saturation != AdjustmentDefaults.saturation) eqParts.add('saturation=${saturation.toStringAsFixed(3)}');
    if (gamma != AdjustmentDefaults.gamma) eqParts.add('gamma=${gamma.toStringAsFixed(3)}');
    if (eqParts.isNotEmpty) _videoFilters.add('eq=${eqParts.join(":")}');

    if (hue != AdjustmentDefaults.hue) {
      _videoFilters.add('hue=h=${hue.toStringAsFixed(1)}');
    }

    if (c.temperature != 0) {
      final kelvin = (6500.0 + c.temperature * 25.0).clamp(2000.0, 15000.0);
      _videoFilters.add('colortemperature=temperature=${kelvin.toStringAsFixed(0)}');
    }

    if (c.tint != 0) {
      final g = ((c.tint / 100.0) * 0.3).clamp(-0.3, 0.3).toStringAsFixed(3);
      _videoFilters.add('colorbalance=gs=$g:gm=$g:gh=$g');
    }

    if (c.redBalance != 0 || c.greenBalance != 0 || c.blueBalance != 0) {
      final rs = (c.redBalance * 0.3).toStringAsFixed(3);
      final gs = (c.greenBalance * 0.3).toStringAsFixed(3);
      final bs = (c.blueBalance * 0.3).toStringAsFixed(3);
      _videoFilters.add('colorbalance=rs=$rs:gs=$gs:bs=$bs:rh=$rs:gh=$gs:bh=$bs:rm=$rs:gm=$gs:bm=$bs');
    }

    if (c.vibrance != 0) {
      final v = (1.0 + c.vibrance * 0.3).toStringAsFixed(3);
      _videoFilters.add('eq=saturation=$v');
    }

    if (c.fade != 0) {
      final f = (1.0 - c.fade * 0.5).toStringAsFixed(3);
      final o = (c.fade * 0.1).toStringAsFixed(3);
      _videoFilters.add('colorchannelmixer=rr=$f:gg=$f:bb=$f:rg=$o:gb=$o:rb=$o');
    }
  }

  void addDetailFilters(double sharpness, double blur, double denoise, double noiseAmt) {
    if (sharpness != AdjustmentDefaults.sharpness) {
      final s = (sharpness * 0.5).toStringAsFixed(2);
      _videoFilters.add('unsharp=l_msize_x=5:l_msize_y=5:l_amount=$s');
    }
    if (blur != AdjustmentDefaults.blur) {
      _videoFilters.add('boxblur=luma_radius=${blur.toStringAsFixed(1)}:luma_power=2');
    }
    if (denoise != AdjustmentDefaults.denoise) {
      _videoFilters.add('hqdn3d=${denoise.toStringAsFixed(1)}:${denoise.toStringAsFixed(1)}:${(denoise * 0.5).toStringAsFixed(1)}:${(denoise * 0.5).toStringAsFixed(1)}');
    }
    if (noiseAmt != AdjustmentDefaults.noise) {
      _videoFilters.add('noise=alls=${(noiseAmt * 10).round().toString()}:allf=t+u');
    }
  }

  void addEffectFilters(double vignette, double lensDistortion) {
    if (vignette != AdjustmentDefaults.vignette) {
      _videoFilters.add('vignette=PI*${(vignette * 0.5).toStringAsFixed(3)}');
    }
    if (lensDistortion != AdjustmentDefaults.lensDistortion) {
      final k = (lensDistortion * 0.2).toStringAsFixed(3);
      _videoFilters.add('lenscorrection=k1=$k:k2=0');
    }
  }

  void addLutFilter(String? lutPath) {
    if (lutPath != null && lutPath.isNotEmpty) {
      _videoFilters.add('lut3d=$lutPath');
    }
  }

  void addVideoSpeedFilters(VideoAdjustment v) {
    if (v.speed != 1.0) {
      _videoFilters.add('setpts=${(1.0 / v.speed).toStringAsFixed(3)}*PTS');
      _audioFilters.add('atempo=${min(v.speed, 2.0).toStringAsFixed(2)}');
      if (v.speed > 2.0) {
        _audioFilters.add('atempo=${(v.speed / 2.0).toStringAsFixed(2)}');
      }
    }
    if (v.reverse) {
      _videoFilters.add('reverse');
      _audioFilters.add('areverse');
    }
  }

  void addVideoFadeFilters(VideoAdjustment v, double videoDuration) {
    if (v.fadeIn > 0) {
      _videoFilters.add('fade=t=in:d=${v.fadeIn.toStringAsFixed(1)}');
    }
    if (v.fadeOut > 0 && videoDuration > 0) {
      _videoFilters.add('fade=t=out:st=${(videoDuration - v.fadeOut).toStringAsFixed(1)}:d=${v.fadeOut.toStringAsFixed(1)}');
    }
  }

  void addAudioFilters(AudioAdjustment a) {
    if (a.mute) {
      _audioFilters.add('volume=0');
      return;
    }
    if (a.volume != AdjustmentDefaults.volume) {
      _audioFilters.add('volume=${a.volume.toStringAsFixed(2)}');
    }
    if (a.noiseReduction != AdjustmentDefaults.noiseReduction) {
      _audioFilters.add('afftdn=nr=${(a.noiseReduction * 20).round().toString()}');
    }
    if (a.normalize) _audioFilters.add('loudnorm=I=-16:LRA=11:TP=-1.5');
    if (a.fadeIn > 0) _audioFilters.add('afade=t=in:d=${a.fadeIn.toStringAsFixed(1)}');
    if (a.fadeOut > 0) _audioFilters.add('afade=t=out:d=${a.fadeOut.toStringAsFixed(1)}');
    if (a.bassBoost != AdjustmentDefaults.bassBoost) {
      _audioFilters.add('bass=g=${(a.bassBoost * 5).toStringAsFixed(1)}');
    }
    if (a.treble != AdjustmentDefaults.treble) {
      _audioFilters.add('treble=g=${(a.treble * 5).toStringAsFixed(1)}');
    }
    if (a.compressor != AdjustmentDefaults.compressor) {
      _audioFilters.add('acompressor=ratio=${(1.0 + a.compressor * 2).toStringAsFixed(1)}');
    }
    if (a.pitchShift != AdjustmentDefaults.pitchShift) {
      _audioFilters.add('asetrate=44100*${a.pitchShift.toStringAsFixed(3)},atempo=${(1.0 / a.pitchShift).toStringAsFixed(3)}');
    }
  }

  String? build({double videoDuration = 0, bool hasAudio = true}) {
    final v = _settings.video;
    final t = _settings.tone;
    final c = _settings.color;
    final a = _settings.audio;

    _videoFilters.clear();
    _audioFilters.clear();

    addGeometricFilters(v);
    addToneFilters(t);
    addColorFilters(_settings.brightness, _settings.contrast, _settings.saturation, _settings.gamma, _settings.hue, c);
    addDetailFilters(_settings.sharpness, _settings.blur, _settings.denoise, _settings.noise);
    addEffectFilters(_settings.vignette, _settings.lensDistortion);
    addLutFilter(_settings.lutPath);
    addVideoSpeedFilters(v);
    addVideoFadeFilters(v, videoDuration);

    if (hasAudio) {
      addAudioFilters(a);
    }

    if (_videoFilters.isEmpty && _audioFilters.isEmpty) return null;

    final vf = _videoFilters.isNotEmpty ? _videoFilters.join(',') : 'null';

    // Videos without an audio stream: mapping [0:a] would hard-fail the
    // whole export, so emit a video-only graph.
    if (!hasAudio) {
      return '-filter_complex "[0:v]$vf[outv]" -map "[outv]"';
    }

    if (_audioFilters.isEmpty) {
      return '-filter_complex "[0:v]$vf[outv];[0:a]anull[outa]" -map "[outv]" -map "[outa]"';
    }

    final af = _audioFilters.join(',');
    return '-filter_complex "[0:v]$vf[outv];[0:a]$af[outa]" -map "[outv]" -map "[outa]"';
  }

  String? buildPreview({double videoDuration = 0}) {
    final v = _settings.video;
    final t = _settings.tone;
    final c = _settings.color;

    _videoFilters.clear();
    _audioFilters.clear();

    addGeometricFilters(v);
    addToneFilters(t);
    addColorFilters(_settings.brightness, _settings.contrast, _settings.saturation, _settings.gamma, _settings.hue, c);
    addDetailFilters(_settings.sharpness, _settings.blur, _settings.denoise, _settings.noise);
    addEffectFilters(_settings.vignette, _settings.lensDistortion);
    addLutFilter(_settings.lutPath);

    return _videoFilters.isNotEmpty ? _videoFilters.join(',') : null;
  }
}
