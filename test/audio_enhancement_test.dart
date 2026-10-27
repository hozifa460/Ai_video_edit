import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video_editing/features/audio_enhancement/data/services/audio_enhancement_filter_builder.dart';

void main() {
  group('Audio enhancer filter command', () {
    test('always has highpass + compand', () {
      final r = AudioEnhancementFilterBuilder.build();
      expect(r, contains('highpass=f=80'));
      expect(r, contains('compand='));
    });

    test('no deesser when disabled', () {
      final r = AudioEnhancementFilterBuilder.build(deesser: 0);
      expect(r, isNot(contains('t=q')));
    });

    test('deesser appears when > 0', () {
      final r = AudioEnhancementFilterBuilder.build(deesser: 50);
      expect(r, contains('equalizer=f=8000'));
      expect(r, contains('g=-5.0'));
    });

    test('volume appears only when not 100', () {
      final r = AudioEnhancementFilterBuilder.build(volume: 150);
      expect(r, contains('volume='));

      final r2 = AudioEnhancementFilterBuilder.build(volume: 100);
      expect(r2, isNot(contains('volume=')));
    });

    test('all equalizer bands appear', () {
      final r = AudioEnhancementFilterBuilder.build(
        bass: 3,
        mid: 2,
        presence: 4,
        treble: 3,
      );
      expect(r, contains('equalizer=f=80'));
      expect(r, contains('equalizer=f=1000'));
      expect(r, contains('equalizer=f=3000'));
      expect(r, contains('equalizer=f=8000'));
    });

    test('compand points respect noise floor', () {
      final r = AudioEnhancementFilterBuilder.build(
        noiseFloor: -40,
        gateAmount: 50,
      );
      expect(r, contains('-40/'));
    });

    test('gate pushes the noise floor below the original level', () {
      final r = AudioEnhancementFilterBuilder.build(
        noiseFloor: -40,
        gateAmount: 75,
      );
      expect(r, contains('-40/-'));
      expect(r, isNot(contains('-40/-40|')));
    });
  });
}
