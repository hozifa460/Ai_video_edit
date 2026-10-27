import 'dart:math';

class AudioEnhancementFilterBuilder {
  const AudioEnhancementFilterBuilder._();

  static String build({
    int noiseFloor = -42,
    double gateAmount = 50,
    double deesser = 0,
    double bass = 0,
    double mid = 0,
    double presence = 0,
    double treble = 5,
    double volume = 100,
  }) {
    final parts = <String>[];
    parts.add('highpass=f=80');

    final t = (gateAmount / 100).clamp(0.0, 1.0);
    final nf = noiseFloor.clamp(-60, -20);
    final quietIn = (nf - 18).clamp(-90, -21).round();
    final quietOut = (quietIn - (6 + 12 * t)).clamp(-90, -20).round();
    final floorOut = (nf - (8 + 16 * t)).clamp(-90, -20).round();
    final speechIn = (nf + 10 + (8 * t).round()).clamp(-50, -6).round();

    parts.add(
      'compand=attacks=0.02:decays=0.25:points='
      '-90/-90|$quietIn/$quietOut|$nf/$floorOut|$speechIn/$speechIn|0/0',
    );

    if (gateAmount > 65) {
      parts.add('lowpass=f=14500');
    }

    if (deesser > 0) {
      final deessGain = -(deesser / 100 * 10);
      parts.add('equalizer=f=8000:t=q:w=1:g=${deessGain.toStringAsFixed(1)}');
    }
    if (bass != 0) {
      parts.add('equalizer=f=80:t=o:w=100:g=${bass.toStringAsFixed(1)}');
    }
    if (mid != 0) {
      parts.add('equalizer=f=1000:t=o:w=500:g=${mid.toStringAsFixed(1)}');
    }
    if (presence != 0) {
      parts.add('equalizer=f=3000:t=o:w=1000:g=${presence.toStringAsFixed(1)}');
    }
    if (treble != 0) {
      parts.add('equalizer=f=8000:t=o:w=2000:g=${treble.toStringAsFixed(1)}');
    }
    if (volume != 100) {
      if (volume <= 0) {
        parts.add('volume=0');
      } else {
        final db = 20 * (log(volume / 100) / ln10);
        parts.add('volume=${db.toStringAsFixed(1)}dB');
      }
    }

    parts.add('alimiter=limit=0.95:attack=5:release=80');
    return parts.join(',');
  }
}
