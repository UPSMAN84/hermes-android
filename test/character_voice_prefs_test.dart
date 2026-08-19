import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/character_voice_prefs.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CharacterVoicePrefs', () {
    test('a character with no override returns null', () async {
      final voice = await CharacterVoicePrefs.get(
        'characters/ada.png',
        'xtts',
      );
      expect(voice, isNull);
    });

    test('set then get round-trips the voice', () async {
      await CharacterVoicePrefs.set('characters/ada.png', 'xtts', 'nova.wav');
      final voice = await CharacterVoicePrefs.get(
        'characters/ada.png',
        'xtts',
      );
      expect(voice, 'nova.wav');
    });

    test('xtts and chatterbox overrides for the same character do not collide',
        () async {
      await CharacterVoicePrefs.set('characters/ada.png', 'xtts', 'nova.wav');
      await CharacterVoicePrefs.set(
        'characters/ada.png',
        'chatterbox',
        'deep_male.wav',
      );

      expect(
        await CharacterVoicePrefs.get('characters/ada.png', 'xtts'),
        'nova.wav',
      );
      expect(
        await CharacterVoicePrefs.get('characters/ada.png', 'chatterbox'),
        'deep_male.wav',
      );
    });

    test('different characters do not collide', () async {
      await CharacterVoicePrefs.set('characters/ada.png', 'xtts', 'nova.wav');
      await CharacterVoicePrefs.set(
        'characters/grim.png',
        'xtts',
        'gravel.wav',
      );

      expect(
        await CharacterVoicePrefs.get('characters/ada.png', 'xtts'),
        'nova.wav',
      );
      expect(
        await CharacterVoicePrefs.get('characters/grim.png', 'xtts'),
        'gravel.wav',
      );
    });

    test('setting null clears a previously assigned voice', () async {
      await CharacterVoicePrefs.set('characters/ada.png', 'xtts', 'nova.wav');
      await CharacterVoicePrefs.set('characters/ada.png', 'xtts', null);

      expect(
        await CharacterVoicePrefs.get('characters/ada.png', 'xtts'),
        isNull,
      );
    });

    test('setting an empty string clears the same as null', () async {
      await CharacterVoicePrefs.set('characters/ada.png', 'xtts', 'nova.wav');
      await CharacterVoicePrefs.set('characters/ada.png', 'xtts', '');

      expect(
        await CharacterVoicePrefs.get('characters/ada.png', 'xtts'),
        isNull,
      );
    });
  });
}
