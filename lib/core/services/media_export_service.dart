// Share / save-to-gallery for generated media (images and video clips).
// Both bubble types (chat_screen.dart's _ImageBubble/_VideoBubble) and the
// media gallery route through this so the two entry points can't drift.
import 'dart:io';

import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

class MediaExportService {
  MediaExportService._();

  /// Opens the system share sheet for [file].
  static Future<void> share(File file) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  /// Saves [file] to the device's own Photos/Gallery app -- distinct from
  /// this app's private MediaCacheService disk cache, which the OS gallery
  /// can't see at all. Returns null on success, or a short user-facing
  /// message on failure (permission denied, unsupported format).
  static Future<String?> saveToGallery(File file, {required bool isVideo}) async {
    try {
      // On API 24-29, gal's putImage/putVideo attempt the write directly and
      // throw if WRITE_EXTERNAL_STORAGE hasn't been granted yet -- unlike
      // hasAccess/requestAccess, they never trigger the OS permission
      // dialog themselves. Without this, a fresh install on those OS
      // versions would report "Photos permission denied" forever with no
      // way to actually grant it. toAlbum: true matches the album: 'Hermes'
      // save below (a plain gallery save needs no prompt on API 29; saving
      // into a named album does). No-ops on API 30+, where hasAccess is
      // unconditionally true and scoped storage handles consent per write.
      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) return 'Photos permission denied';
      }
      if (isVideo) {
        await Gal.putVideo(file.path, album: 'Hermes');
      } else {
        await Gal.putImage(file.path, album: 'Hermes');
      }
      return null;
    } on GalException catch (e) {
      switch (e.type) {
        case GalExceptionType.accessDenied:
          return 'Photos permission denied';
        case GalExceptionType.notSupportedFormat:
          return 'Unsupported file format';
        case GalExceptionType.notEnoughSpace:
          return 'Not enough storage space';
        case GalExceptionType.unexpected:
          return 'Save failed: ${e.type}';
      }
    } catch (e) {
      return 'Save failed: $e';
    }
  }
}
