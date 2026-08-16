// A missing or misdeclared bundled font fails SILENTLY at runtime — Flutter
// just falls back to the default face, with no error and no log line. That is
// the same wrong-wordmark symptom the google_fonts runtime fetch used to cause
// offline, so it is worth a test rather than an eyeball.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/brand.dart';

void main() {
  group('hermesWordmark', () {
    test('asks for the bundled family at the one weight that is shipped', () {
      final style = hermesWordmark(fontSize: 22);
      expect(style.fontFamily, 'Cinzel');
      // brand.dart hardcodes w700 because only that weight is bundled; any
      // other weight would be a synthesized fake.
      expect(style.fontWeight, FontWeight.w700);
    });

    test('passes through size, spacing and colour', () {
      final style = hermesWordmark(
        fontSize: 28,
        letterSpacing: 4,
        color: const Color(0xFFD4AF37),
      );
      expect(style.fontSize, 28);
      expect(style.letterSpacing, 4);
      expect(style.color, const Color(0xFFD4AF37));
    });

    test('defaults to the wordmark letter spacing', () {
      expect(hermesWordmark(fontSize: 22).letterSpacing, 6);
    });
  });

  group('pubspec font declaration', () {
    late final List<String> pubspec = File('pubspec.yaml').readAsLinesSync();

    test('declares the Cinzel family', () {
      expect(
        pubspec.any((l) => l.trim() == '- family: Cinzel'),
        isTrue,
        reason: 'brand.dart asks for fontFamily "Cinzel"',
      );
    });

    test('every declared font asset actually exists on disk', () {
      final assets = pubspec
          .map((l) => l.trim())
          .where((l) => l.startsWith('- asset: assets/fonts/'))
          .map((l) => l.substring('- asset: '.length))
          .toList();

      expect(assets, isNotEmpty, reason: 'no font assets declared');
      for (final asset in assets) {
        final file = File(asset);
        expect(file.existsSync(), isTrue, reason: '$asset is declared but missing');
        // A truncated or LFS-pointer file would still "exist"; a real TTF is
        // tens of KB and starts with a known magic number.
        expect(file.lengthSync(), greaterThan(10000), reason: '$asset looks truncated');
        final magic = file.openSync().readSync(4);
        expect(
          magic,
          anyOf(
            equals([0x00, 0x01, 0x00, 0x00]), // TrueType
            equals([0x4F, 0x54, 0x54, 0x4F]), // 'OTTO'
            equals([0x74, 0x72, 0x75, 0x65]), // 'true'
          ),
          reason: '$asset is not a font file',
        );
      }
    });

    test('declares weight 700, which brand.dart hardcodes', () {
      expect(pubspec.any((l) => l.trim() == 'weight: 700'), isTrue);
    });

    test('ships the OFL license alongside the font', () {
      // SIL OFL requires the license travel with the font.
      final license = File('assets/fonts/OFL.txt');
      expect(license.existsSync(), isTrue);
      expect(license.readAsStringSync(), contains('SIL Open Font License'));
    });
  });
}
