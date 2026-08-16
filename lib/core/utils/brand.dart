import 'package:flutter/material.dart';

/// The HERMES wordmark face.
///
/// Cinzel is bundled as an asset (see pubspec.yaml) rather than pulled at
/// runtime by google_fonts. The package fetched it from fonts.gstatic.com on
/// first launch and silently fell back to the default face when that failed —
/// which for an app whose whole job is talking to a gateway on your LAN or
/// tailnet is a completely ordinary situation, so the brand mark was wrong
/// exactly as often as the app was used offline. It also put an HTTP request
/// in front of the first frame.
///
/// Only weight 700 is shipped, since that is the only weight the wordmark
/// uses; asking for any other weight here would get a synthesized fake.
TextStyle hermesWordmark({
  required double fontSize,
  double letterSpacing = 6,
  Color? color,
}) {
  return TextStyle(
    fontFamily: 'Cinzel',
    fontWeight: FontWeight.w700,
    fontSize: fontSize,
    letterSpacing: letterSpacing,
    color: color,
  );
}
