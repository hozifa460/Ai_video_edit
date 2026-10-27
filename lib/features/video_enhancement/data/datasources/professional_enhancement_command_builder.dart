import '../../domain/entities/video_analysis_result.dart';
import '../../domain/entities/enhancement_plan.dart';
import '../../domain/entities/enhancement_settings.dart';

class ProfessionalEnhancementCommandBuilder {
  String buildDirectCommand({
    required String inputPath,
    required String outputPath,
    required EnhancementSettings settings,
  }) {
    final vf = buildDirectVideoFilter(settings);
    final af = settings.audioEnhanceEnabled ? _buildDirectAudioFilter() : '';

    final parts = [
      '-y',
      '-i "${_normalizePath(inputPath)}"',
      '-map 0:v:0',
      '-map 0:a?',
      '-vf "$vf"',
    ];

    if (af.isNotEmpty) {
      parts.add('-af "$af"');
    }

    parts.addAll([
      '-c:v libx264',
      '-crf ${settings.qualityCrf}',
      '-preset ${settings.encodingPreset}',
      '-profile:v high',
      '-level 4.1',
      '-pix_fmt yuv420p',
      '-c:a aac',
      '-b:a 192k',
      '-ar 48000',
      '-movflags +faststart',
      '-metadata comment="Enhanced by AI Video Studio"',
      '"${_normalizePath(outputPath)}"',
    ]);

    return parts.join(' ');
  }

  String buildDirectVideoFilter(EnhancementSettings settings) {
    final videoFilters = <String>[];

    if (settings.denoiseEnabled) {
      videoFilters.add(_buildDenoiseFilter(0.55, settings.level));
    }

    videoFilters.add('deblock=filter=strong:block=8:alpha=0.05:beta=0.05');

    if (settings.upscaleEnabled) {
      videoFilters.add(
        _buildUpscaleFilter(settings.targetWidth, settings.targetHeight),
      );
    }

    if (settings.colorGradeEnabled) {
      videoFilters.add("curves=master='0/0 0.20/0.16 0.50/0.52 0.80/0.86 1/1'");
      videoFilters.add(
        'eq=saturation=1.16:brightness=0.01:contrast=1.08:gamma=1.02',
      );
    }

    if (settings.sharpenEnabled) {
      videoFilters.add(_buildSharpenFilter(0.55, settings.level));
    }

    videoFilters.add(
      'deband=1thr=0.02:2thr=0.02:3thr=0.02:4thr=0.016:range=16:blur=true',
    );
    videoFilters.add('format=yuv420p');
    return videoFilters.join(',');
  }

  String buildCommand({
    required String inputPath,
    required String outputPath,
    required VideoAnalysisResult analysis,
    required EnhancementSettings settings,
  }) {
    final videoFilters = <String>[];
    final audioFilters = <String>[];

    final quality = analysis.quality;
    final metadata = analysis.metadata;

    if (settings.denoiseEnabled && quality.noiseLevel > 0.2) {
      videoFilters.add(_buildDenoiseFilter(quality.noiseLevel, settings.level));
    }

    videoFilters.add('deblock=filter=strong:block=8:alpha=0.05:beta=0.05');

    if (settings.upscaleEnabled && metadata.needsUpscaling) {
      videoFilters.add(
        _buildUpscaleFilter(settings.targetWidth, settings.targetHeight),
      );
    }

    if (settings.colorGradeEnabled) {
      videoFilters.add(
        _buildTonemapFilter(quality.brightness, quality.contrast),
      );
      videoFilters.add(
        _buildColorGradingFilter(quality.saturation, quality.brightness),
      );
    }

    if (settings.sharpenEnabled && quality.blurLevel > 0.3) {
      videoFilters.add(_buildSharpenFilter(quality.blurLevel, settings.level));
    }

    videoFilters.add(
      'deband=1thr=0.02:2thr=0.02:3thr=0.02:4thr=0.016:range=16:blur=true',
    );
    videoFilters.add('format=yuv420p');

    if (settings.audioEnhanceEnabled && metadata.hasAudio) {
      audioFilters.add(_buildAudioFilter(quality.noiseLevel));
    }

    final vf = videoFilters.join(',');
    final af = audioFilters.isEmpty ? '' : audioFilters.join(',');

    final commandParts = [
      '-y',
      '-i',
      '"${_normalizePath(inputPath)}"',
      '-map',
      '0:v:0',
      '-map',
      '0:a?',
      '-vf',
      '"$vf"',
    ];

    if (af.isNotEmpty) {
      commandParts.addAll(['-af', '"$af"']);
    }

    commandParts.addAll([
      '-c:v',
      'libx264',
      '-crf',
      settings.qualityCrf.toString(),
      '-preset',
      settings.encodingPreset,
      '-profile:v',
      'high',
      '-level',
      '4.1',
      '-c:a',
      'aac',
      '-b:a',
      '192k',
      '-ar',
      '48000',
      '-movflags',
      '+faststart',
      '-metadata',
      'comment="Enhanced by AI Video Studio"',
      '"${_normalizePath(outputPath)}"',
    ]);

    return commandParts.join(' ');
  }

  String _buildDenoiseFilter(double noiseLevel, EnhancementLevel level) {
    final intensity = switch (level) {
      EnhancementLevel.fast => 3.0,
      EnhancementLevel.balanced => 5.0,
      EnhancementLevel.quality => 7.0,
      EnhancementLevel.ultra => 10.0,
    };

    if (noiseLevel > 0.7) {
      return 'hqdn3d=${intensity.toInt()}:${(intensity * 0.75).toInt()}:${(intensity * 1.5).toInt()}:${(intensity * 1.1).toInt()}';
    } else if (noiseLevel > 0.4) {
      return 'hqdn3d=4:3:6:4.5';
    } else {
      return 'hqdn3d=2:1.5:3:2.25';
    }
  }

  String _buildTonemapFilter(double brightness, double contrast) {
    if (brightness < 0.3) {
      return "curves=master='0/0 0.2/0.35 0.5/0.65 0.85/0.95 1/1'";
    } else if (brightness > 0.8) {
      return "curves=master='0/0 0.15/0.1 0.5/0.45 0.85/0.75 1/0.95'";
    } else if (contrast < 0.5) {
      return "curves=master='0/0 0.25/0.18 0.5/0.5 0.75/0.82 1/1'";
    }
    return "curves=master='0/0 0.25/0.20 0.5/0.5 0.75/0.80 1/1'";
  }

  String _buildColorGradingFilter(double saturation, double brightness) {
    final satBoost = saturation < 0.5 ? 1.35 : (saturation < 0.7 ? 1.2 : 1.1);
    final contrast = brightness < 0.3 ? 1.1 : 1.0;
    return 'eq=saturation=$satBoost:brightness=0:contrast=$contrast';
  }

  String _buildSharpenFilter(double blurLevel, EnhancementLevel level) {
    final amount = blurLevel > 0.6 ? 2.0 : (blurLevel > 0.4 ? 1.5 : 1.0);
    return 'unsharp=lx=5:ly=5:la=$amount:cx=3:cy=3:ca=0.35';
  }

  String _buildUpscaleFilter(int targetWidth, int targetHeight) {
    return 'scale=$targetWidth:$targetHeight:flags=lanczos+accurate_rnd+full_chroma_int:force_original_aspect_ratio=decrease,'
        'pad=$targetWidth:$targetHeight:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1';
  }

  String _buildAudioFilter(double noiseLevel) {
    final n = noiseLevel > 0.5 ? '-0.80' : '-0.50';
    return [
      'afftdn=n=$n:nt=w:om=o',
      'acompressor=threshold=-18dB:ratio=3:attack=5:release=80:makeup=2dB',
      'equalizer=f=100:t=o:w=100:g=2',
      'equalizer=f=3000:t=o:w=1000:g=1.5',
      'loudnorm=I=-16:TP=-1.5:LRA=11:linear=true:print_format=none',
      'alimiter=limit=0.9:attack=5:release=50',
    ].join(',');
  }

  String _buildDirectAudioFilter() {
    return [
      'highpass=f=80',
      'compand=attacks=0.02:decays=0.25:points=-90/-90|-58/-70|-42/-54|-28/-28|0/0',
      'equalizer=f=100:t=o:w=100:g=1.5',
      'equalizer=f=3000:t=o:w=1000:g=1.2',
      'alimiter=limit=0.95:attack=5:release=80',
    ].join(',');
  }

  String _normalizePath(String path) => path.replaceAll('\\', '/');
}
