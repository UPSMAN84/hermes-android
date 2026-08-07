import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';

void main() {
  group('looksLikeValidSchedule', () {
    test('accepts a 5-field cron expression', () {
      expect(looksLikeValidSchedule('0 9 * * *'), isTrue);
      expect(looksLikeValidSchedule('*/15 * * * *'), isTrue);
      expect(looksLikeValidSchedule('0 0 * * mon'), isTrue);
      expect(looksLikeValidSchedule('0 0 1 jan *'), isTrue);
    });

    test('accepts an "every <n><unit>" duration', () {
      expect(looksLikeValidSchedule('every 2h'), isTrue);
      expect(looksLikeValidSchedule('every 30m'), isTrue);
      expect(looksLikeValidSchedule('EVERY 1d'), isTrue);
    });

    test('rejects empty or prose input', () {
      expect(looksLikeValidSchedule(''), isFalse);
      expect(looksLikeValidSchedule('   '), isFalse);
      expect(looksLikeValidSchedule('every day at 9am'), isFalse);
      expect(looksLikeValidSchedule('daily'), isFalse);
    });

    test('rejects a cron expression with the wrong field count', () {
      expect(looksLikeValidSchedule('0 9 * *'), isFalse);
      expect(looksLikeValidSchedule('0 9 * * * *'), isFalse);
    });
  });
}
