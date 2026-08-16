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

class CachedMediaThumbnail extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final double borderRadius;

  /// Auth for sources that need it (gateway character images sit behind the
  /// same Bearer token as the rest of the API; ComfyUI's /view does not).
  final Map<String, String>? headers;

  /// Decode width in pixels. Character cards are full-resolution PNGs — up
  /// to 6MB, which decodes to ~25MB of bitmap — so a grid of them at full
  /// size will OOM the app. Set this to roughly the on-screen width.
  final int? decodeWidth;

  const CachedMediaThumbnail({
    required this.url,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    this.headers,
    this.decodeWidth,
    super.key,
  });

  @override
  State<CachedMediaThumbnail> createState() => _CachedMediaThumbnailState();
}

class _CachedMediaThumbnailState extends State<CachedMediaThumbnail> {
  // Held in State, NOT created inside build(): a Future built in build() is a
  // new instance on every rebuild, which makes FutureBuilder resubscribe and
  // reset its snapshot to `waiting` — i.e. every visible image drops to a
  // spinner on each rebuild. The chat screen rebuilds every 120ms while a
  // reply streams (see _flushPendingTokens), so that flickered ~8x/second.
  Future<File>? _fileFuture;

  // Decoded once per source, NOT in build(): base64Decode of a ~1MB
  // attachment ran on every rebuild — 8x/second while a reply streams — and
  // handed Image.memory a brand-new Uint8List each time. MemoryImage keys the
  // ImageCache on list identity, so every one of those was a cache miss and a
  // full JPEG re-decode.
  Uint8List? _dataBytes;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CachedMediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only re-resolve when the actual source changes.
    if (oldWidget.url != widget.url) _resolve();
  }

  void _resolve() {
    final isData = widget.url.startsWith('data:');
    _dataBytes = isData ? _decodeDataUri(widget.url) : null;
    _fileFuture = isData
        ? null
        : MediaCacheService.fileFor(widget.url, headers: widget.headers);
  }

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
    if (widget.url.startsWith('data:')) {
      final dataBytes = _dataBytes;
      // A data: URI that failed to decode has no network fallback worth
      // attempting — data URIs aren't fetchable URLs — so show the broken
      // state directly instead of the old behavior of falling through to
      // Image.network(url) with the raw data: string, which is guaranteed
      // to fail with no visible error.
      if (dataBytes == null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: _broken(context),
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: GestureDetector(
          onTap: () => _openFullscreen(context, Image.memory(dataBytes)),
          child: Image.memory(
            dataBytes,
            fit: widget.fit,
            // Attachments are full-size camera/gallery photos; honour the
            // caller's decode bound here too, not just on the file path.
            cacheWidth: widget.decodeWidth,
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: FutureBuilder<File>(
        future: _fileFuture,
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
            child: Image.file(
              file,
              fit: widget.fit,
              cacheWidth: widget.decodeWidth,
            ),
          );
        },
      ),
    );
  }
}
