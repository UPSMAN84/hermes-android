// Shared image-rendering widget for both the inline chat attachment
// thumbnail and the media gallery grid — previously two near-identical
// copies (_AttachedImage in chat_screen.dart, _GalleryTile in
// media_gallery_screen.dart) with inconsistent error handling between them.
// Handles three sources uniformly, with a broken-image fallback at every
// render site (thumbnail AND the full-screen tap-to-zoom viewer):
//   - data: URIs (user-attached images) — decoded once, rendered from memory.
//   - http(s) URLs (ComfyUI-generated images) — resolved through
//     MediaCacheService so a re-opened chat/gallery reads from disk instead
//     of re-fetching the same file from the LAN gateway every time.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/media_cache_service.dart';

class CachedMediaThumbnail extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double borderRadius;

  const CachedMediaThumbnail({
    required this.url,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    super.key,
  });

  static Uint8List? _decodeDataUri(String url) {
    if (!url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  static Widget _broken(BuildContext context) => Container(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: const Icon(Icons.broken_image_outlined),
  );

  void _openFullscreen(BuildContext context, Widget image) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black),
          body: SafeArea(
            child: Center(child: InteractiveViewer(child: image)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dataBytes = _decodeDataUri(url);

    if (url.startsWith('data:')) {
      // A data: URI that failed to decode has no network fallback worth
      // attempting — data URIs aren't fetchable URLs — so show the broken
      // state directly instead of the old behavior of falling through to
      // Image.network(url) with the raw data: string, which is guaranteed
      // to fail with no visible error.
      if (dataBytes == null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: _broken(context),
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: GestureDetector(
          onTap: () => _openFullscreen(context, Image.memory(dataBytes)),
          child: Image.memory(dataBytes, fit: fit),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: FutureBuilder<File>(
        future: MediaCacheService.fileFor(url),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          final file = snapshot.data;
          if (snapshot.hasError || file == null) {
            return _broken(context);
          }
          return GestureDetector(
            onTap: () => _openFullscreen(context, Image.file(file)),
            child: Image.file(file, fit: fit),
          );
        },
      ),
    );
  }
}
