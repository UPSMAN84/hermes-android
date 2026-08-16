import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/row_keys.dart';

void main() {
  group('stableContentHash', () {
    test('is deterministic for the same input', () {
      expect(stableContentHash('hello'), stableContentHash('hello'));
    });

    test('separates different inputs', () {
      expect(stableContentHash('hello'), isNot(stableContentHash('hellp')));
    });

    test('is always 8 hex chars, including for the empty string', () {
      for (final s in ['', 'a', 'a much longer message body', '🙂 unicode']) {
        expect(stableContentHash(s), matches(RegExp(r'^[0-9a-f]{8}$')));
      }
    });
  });

  group('messageRowKey', () {
    test('survives a refetch: same role and text give the same key', () {
      // getMessages() returns brand-new maps every time; the key must not.
      final before = messageRowKey(role: 'assistant', text: 'Hi there');
      final after = messageRowKey(role: 'assistant', text: 'Hi there');
      expect(before, after);
    });

    test('same text from a different role is a different row', () {
      expect(
        messageRowKey(role: 'user', text: 'Continue.'),
        isNot(messageRowKey(role: 'assistant', text: 'Continue.')),
      );
    });

    test('a server id wins over the content hash when present', () {
      expect(messageRowKey(role: 'user', text: 'anything', id: 'abc'), 'm:abc');
      // ...and an empty id falls back rather than producing "m:".
      expect(
        messageRowKey(role: 'user', text: 'x', id: ''),
        messageRowKey(role: 'user', text: 'x'),
      );
    });

    test('the streaming reply keeps one key as its text grows', () {
      final early = messageRowKey(
        role: 'assistant',
        text: 'Once upon',
        streaming: true,
      );
      final later = messageRowKey(
        role: 'assistant',
        text: 'Once upon a time, at some length…',
        streaming: true,
      );
      expect(early, later);
      // Without the flag the growing text would rekey the row on every flush.
      expect(
        messageRowKey(role: 'assistant', text: 'Once upon'),
        isNot(messageRowKey(role: 'assistant', text: 'Once upon a time')),
      );
    });
  });

  group('disambiguate', () {
    test('repeated identical rows get distinct keys', () {
      // Auto-continue sends the literal text "Continue." over and over, and
      // duplicate sibling keys are a hard crash in Flutter.
      final seen = <String, int>{};
      final base = messageRowKey(role: 'user', text: 'Continue.');
      final keys = [
        disambiguate(base, seen),
        disambiguate(base, seen),
        disambiguate(base, seen),
      ];
      expect(keys.toSet().length, 3);
    });

    test('suffixes are positional, so they are stable across rebuilds', () {
      List<String> pass(List<String> bases) {
        final seen = <String, int>{};
        return [for (final b in bases) disambiguate(b, seen)];
      }

      const rows = ['m:a', 'm:b', 'm:a', 'm:a', 'm:c'];
      expect(pass(rows), pass(rows));
      expect(pass(rows), ['m:a', 'm:b', 'm:a#1', 'm:a#2', 'm:c']);
    });

    test('an appended turn does not disturb earlier suffixes', () {
      List<String> pass(List<String> bases) {
        final seen = <String, int>{};
        return [for (final b in bases) disambiguate(b, seen)];
      }

      final before = pass(['m:a', 'm:b', 'm:a']);
      final after = pass(['m:a', 'm:b', 'm:a', 'm:new']);
      expect(after.take(3), before);
    });
  });

  group('row keys of other kinds', () {
    test('tool rows key on the first tool call id, with a fallback', () {
      expect(toolRowKey('call-7'), 't:call-7');
      expect(toolRowKey(''), 't:group');
      expect(toolRowKey(null), 't:group');
    });

    test('media rows key on the first url', () {
      expect(mediaRowKey('http://h/view?filename=a.png'),
          'media:http://h/view?filename=a.png');
      expect(mediaRowKey(null), 'media:');
    });

    test('kinds never collide with each other', () {
      final seen = <String, int>{};
      final keys = {
        disambiguate(messageRowKey(role: 'user', text: 'x'), seen),
        disambiguate(toolRowKey('x'), seen),
        disambiguate(mediaRowKey('x'), seen),
      };
      expect(keys.length, 3);
    });
  });
}
