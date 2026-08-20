// Global, repository-backed media library: every generated image/video the
// app knows about (direct Create generations plus chat-tool outputs
// backfilled from transcripts), independent of any one chat session.
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/comfy_workflow.dart';
import '../models/media_asset.dart';
import '../services/generation_repository.dart';
import '../services/media_cache_service.dart';
import '../services/media_export_service.dart';
import '../widgets/generated_media_view.dart';

enum _MediaFilter { all, images, videos }

final class MediaGalleryScreen extends StatefulWidget {
  const MediaGalleryScreen({
    super.key,
    required this.repository,
    this.onOpenSourceMessage,
    this.mediaCache,
    this.mediaExport,
  });

  final GenerationRepository repository;
  final Future<void> Function(MediaAsset asset)? onOpenSourceMessage;
  final MediaCachePort? mediaCache;
  final MediaExportService? mediaExport;

  @override
  State<MediaGalleryScreen> createState() => _MediaGalleryScreenState();
}

class _MediaGalleryScreenState extends State<MediaGalleryScreen> {
  late final StreamSubscription<List<MediaAsset>> _subscription;
  final GeneratedVideoCoordinator _videoCoordinator =
      DefaultGeneratedVideoCoordinator();
  List<MediaAsset> _media = const [];
  _MediaFilter _filter = _MediaFilter.all;

  MediaCachePort get _mediaCache =>
      widget.mediaCache ?? MediaCacheService.appDefault;
  MediaExportService get _mediaExport =>
      widget.mediaExport ?? MediaExportService.appDefault;

  @override
  void initState() {
    super.initState();
    _subscription = widget.repository.watchMedia().listen((media) {
      if (!mounted) return;
      setState(() {
        _media = media.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      });
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  List<MediaAsset> get _filtered {
    switch (_filter) {
      case _MediaFilter.all:
        return _media;
      case _MediaFilter.images:
        return _media.where((a) => a.kind == ComfyMediaKind.image).toList();
      case _MediaFilter.videos:
        return _media.where((a) => a.kind == ComfyMediaKind.video).toList();
    }
  }

  Future<void> _openSource(MediaAsset asset) async {
    final callback = widget.onOpenSourceMessage;
    if (callback == null) return;
    Navigator.of(context).pop();
    await callback(asset);
  }

  Future<void> _delete(MediaAsset asset) async {
    final clearCache = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from Hermes?'),
        content: const Text(
          'This only removes the local record (and cached copy, if you '
          'choose). The file stays on the ComfyUI server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep cache'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove and clear cache'),
          ),
        ],
      ),
    );
    if (clearCache == null) return;
    await widget.repository.removeMedia(asset.id, clearCache: clearCache);
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: Text('Media (${items.length})'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _filter == _MediaFilter.all,
                  onSelected: (_) => setState(() => _filter = _MediaFilter.all),
                ),
                ChoiceChip(
                  label: const Text('Images'),
                  selected: _filter == _MediaFilter.images,
                  onSelected: (_) =>
                      setState(() => _filter = _MediaFilter.images),
                ),
                ChoiceChip(
                  label: const Text('Videos'),
                  selected: _filter == _MediaFilter.videos,
                  onSelected: (_) =>
                      setState(() => _filter = _MediaFilter.videos),
                ),
              ],
            ),
          ),
        ),
      ),
      body: items.isEmpty
          ? Center(
              child: Text(
                'No media yet',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: items.length,
              itemBuilder: (context, index) => _MediaCard(
                key: ValueKey(items[index].id),
                asset: items[index],
                mediaCache: _mediaCache,
                mediaExport: _mediaExport,
                videoCoordinator: _videoCoordinator,
                onOpenSource:
                    widget.onOpenSourceMessage == null ||
                        items[index].sourceSessionId == null ||
                        items[index].sourceMessageId == null
                    ? null
                    : () => _openSource(items[index]),
                onDelete: () => _delete(items[index]),
              ),
            ),
    );
  }
}

class _MediaCard extends StatelessWidget {
  const _MediaCard({
    super.key,
    required this.asset,
    required this.mediaCache,
    required this.mediaExport,
    required this.videoCoordinator,
    required this.onDelete,
    this.onOpenSource,
  });

  final MediaAsset asset;
  final MediaCachePort mediaCache;
  final MediaExportService mediaExport;
  final GeneratedVideoCoordinator videoCoordinator;
  final VoidCallback onDelete;
  final VoidCallback? onOpenSource;

  @override
  Widget build(BuildContext context) {
    ComfyEndpoint? endpoint;
    try {
      endpoint = ComfyEndpoint.parse(asset.endpointSnapshot);
    } on FormatException {
      endpoint = null;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (endpoint == null)
              const SizedBox(
                height: 100,
                child: Center(
                  child: Text(
                    'This endpoint is unavailable.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            else
              GeneratedMediaView(
                id: asset.id,
                kind: asset.kind,
                uri: endpoint.viewUri(asset.outputRef),
                mediaCache: mediaCache,
                mediaExport: mediaExport,
                videoCoordinator: videoCoordinator,
                margin: EdgeInsets.zero,
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    asset.filename,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (onOpenSource != null)
                  IconButton(
                    icon: const Icon(Icons.chat_bubble_outline, size: 20),
                    tooltip: 'Open source message',
                    onPressed: onOpenSource,
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Remove',
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
