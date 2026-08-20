import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../models/comfy_workflow.dart';
import '../services/media_cache_service.dart';
import '../services/media_export_service.dart';

/// Ensures at most one [GeneratedMediaView] video plays at a time within
/// whatever scope owns this coordinator -- construct one per screen (chat,
/// the global media library) and pass it to every video-capable view on
/// that screen. A `null` coordinator means "don't coordinate" (each view
/// manages its own play state independently).
abstract interface class GeneratedVideoCoordinator {
  /// Called when the view identified by [id] starts playing. Pauses
  /// whatever [id] was previously registered as playing, if any.
  void notifyPlaying(String id, VoidCallback pause);

  /// Called when the view identified by [id] stops playing or is disposed.
  void notifyStopped(String id);
}

final class DefaultGeneratedVideoCoordinator
    implements GeneratedVideoCoordinator {
  String? _activeId;
  VoidCallback? _activePause;

  @override
  void notifyPlaying(String id, VoidCallback pause) {
    if (_activeId != null && _activeId != id) {
      _activePause?.call();
    }
    _activeId = id;
    _activePause = pause;
  }

  @override
  void notifyStopped(String id) {
    if (_activeId == id) {
      _activeId = null;
      _activePause = null;
    }
  }
}

/// One generated image or video, stream-first for video. The single shared
/// presentation path for a generated asset's URI -- used by both the chat
/// transcript and the global media library, so a fix to playback/caching/
/// save/share only has to happen once.
class GeneratedMediaView extends StatefulWidget {
  const GeneratedMediaView({
    super.key,
    required this.id,
    required this.kind,
    required this.uri,
    required this.mediaCache,
    required this.mediaExport,
    this.videoCoordinator,
    this.onDiscuss,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    this.maxWidth,
    this.borderRadius = 18,
  });

  /// Stable identity for this asset -- used as the video coordinator key and
  /// as the base for widget/test keys (`play-video-$id` etc.). The view's
  /// remote URL is a natural choice when there's no other durable id.
  final String id;
  final ComfyMediaKind kind;
  final Uri uri;
  final MediaCachePort mediaCache;
  final MediaExportService mediaExport;
  final GeneratedVideoCoordinator? videoCoordinator;

  /// Image-only per design; a caller must not pass this for a video asset.
  final VoidCallback? onDiscuss;
  final EdgeInsetsGeometry margin;
  final double? maxWidth;
  final double borderRadius;

  @override
  State<GeneratedMediaView> createState() => _GeneratedMediaViewState();
}

class _GeneratedMediaViewState extends State<GeneratedMediaView> {
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxW = widget.maxWidth ?? media.size.width;
    return Container(
      key: ValueKey('media-${widget.kind.name}-${widget.id}'),
      margin: widget.margin,
      constraints: BoxConstraints(maxWidth: maxW),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        color: widget.kind == ComfyMediaKind.video
            ? Colors.black
            : Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: widget.kind == ComfyMediaKind.video
          ? _GeneratedVideo(
              id: widget.id,
              uri: widget.uri,
              mediaExport: widget.mediaExport,
              coordinator: widget.videoCoordinator,
            )
          : _GeneratedImage(
              uri: widget.uri,
              mediaCache: widget.mediaCache,
              mediaExport: widget.mediaExport,
              onDiscuss: widget.onDiscuss,
              maxWidth: maxW,
            ),
    );
  }
}

class _GeneratedImage extends StatefulWidget {
  const _GeneratedImage({
    required this.uri,
    required this.mediaCache,
    required this.mediaExport,
    required this.maxWidth,
    this.onDiscuss,
  });

  final Uri uri;
  final MediaCachePort mediaCache;
  final MediaExportService mediaExport;
  final VoidCallback? onDiscuss;

  /// Logical width the image will actually render at -- computed once by
  /// the parent Container's own maxWidth constraint, not re-derived here
  /// via findRenderObject() (which can't be trusted to have a valid size
  /// yet on the first build).
  final double maxWidth;

  @override
  State<_GeneratedImage> createState() => _GeneratedImageState();
}

class _GeneratedImageState extends State<_GeneratedImage> {
  // Built once, not in build(): a fresh Future per rebuild makes FutureBuilder
  // resubscribe and drop back to `waiting`, which flickers the image to a
  // spinner on every streaming-token flush.
  Future<File?>? _fileFuture;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_GeneratedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        !identical(oldWidget.mediaCache, widget.mediaCache)) {
      _resolve();
    }
  }

  void _resolve() {
    _fileFuture = widget.mediaCache.cache(widget.uri);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final decodeWidth = (widget.maxWidth * media.devicePixelRatio).round();

    return FutureBuilder<File?>(
      future: _fileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final file = snapshot.data;
        if (snapshot.hasError || file == null) {
          return const SizedBox(
            height: 80,
            child: Center(
              child: Text(
                'image unavailable',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          );
        }
        return Stack(
          children: [
            GestureDetector(
              onTap: () => _openFull(context, file),
              child: Image.file(
                file,
                fit: BoxFit.contain,
                cacheWidth: decodeWidth > 0 ? decodeWidth : null,
                errorBuilder: (context, _, _) => const SizedBox(
                  height: 80,
                  child: Center(
                    child: Text(
                      'image unavailable',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Row(
                children: [
                  if (widget.onDiscuss != null)
                    _MediaActionButton(
                      icon: Icons.chat_bubble_outline,
                      tooltip: 'Discuss in chat',
                      onPressed: widget.onDiscuss!,
                    ),
                  _MediaActionButton(
                    onPressed: () => showMediaActions(
                      context,
                      widget.uri,
                      isVideo: false,
                      mediaExport: widget.mediaExport,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _openFull(BuildContext context, File file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black),
          body: SafeArea(
            child: Center(child: InteractiveViewer(child: Image.file(file))),
          ),
        ),
      ),
    );
  }
}

/// Loads media_kit's native backend on first use.
///
/// This runs lazily rather than unconditionally in main(), which would put
/// the shared-object load in front of the first frame on every cold start --
/// including the majority of launches that never open a video.
/// MediaKit.ensureInitialized is itself idempotent; the flag just avoids the
/// repeat call per view.
bool _mediaKitReady = false;
void ensureMediaKitInitialized() {
  if (_mediaKitReady) return;
  MediaKit.ensureInitialized();
  _mediaKitReady = true;
}

/// media_kit hardcodes `cache-on-disk: yes` for every Player but never sets
/// `cache-dir`, so on Android mpv has nowhere to put its demuxer cache file
/// and silently falls back to memory-only buffering. getTemporaryDirectory()
/// is async but the path is fixed for the life of the process, so fetch it
/// once and reuse it.
Future<String>? _mpvCacheDirFuture;
Future<String> _mpvCacheDir() =>
    _mpvCacheDirFuture ??= getTemporaryDirectory().then((d) => d.path);

/// One generated video, streamed straight from its remote URI. Tap toggles
/// play/pause; initialized paused so multiple clips don't all autoplay.
///
/// Backed by media_kit (libmpv/FFmpeg): it software-decodes codecs Android's
/// hardware MediaCodec path rejects -- HEVC/H.265, VP9, AV1, 10-bit
/// (yuv420p10le), and mkv/webm containers.
class _GeneratedVideo extends StatefulWidget {
  const _GeneratedVideo({
    required this.id,
    required this.uri,
    required this.mediaExport,
    this.coordinator,
  });

  final String id;
  final Uri uri;
  final MediaExportService mediaExport;
  final GeneratedVideoCoordinator? coordinator;

  @override
  State<_GeneratedVideo> createState() => _GeneratedVideoState();
}

class _GeneratedVideoState extends State<_GeneratedVideo> {
  // Both are assigned in initState, in this order, BEFORE the first
  // _openSource(). media_kit starts every Player with `--vid=no` ("to
  // prevent redundant video decoding"); attaching a VideoController is what
  // flips it to `--vid=auto`. Constructing the controller lazily (e.g. as a
  // `late final` field initializer, read only once build() first needs it)
  // would mean it isn't attached until AFTER _player.open() already ran --
  // every clip would then open with video decoding switched off, and since
  // generated clips often carry no audio track either, mpv would select no
  // tracks at all and the view would stay permanently black behind its play
  // button.
  Player? _player;
  VideoController? _videoController;
  bool _ready = false;
  bool _failed = false;
  bool _playing = false;
  double _aspect = 16 / 9;

  final List<StreamSubscription<dynamic>> _subs = [];

  /// Bumped on every [_openSource]. An open that resolves after a newer one
  /// started must not flip this view to ready/failed for a clip that is no
  /// longer the one being shown.
  int _openEpoch = 0;

  @override
  void initState() {
    super.initState();
    try {
      // Must happen before the first Player is constructed.
      ensureMediaKitInitialized();
      final player = Player();
      _player = player;
      // Attach the controller before _openSource() below: this is what sets
      // `--vid=auto`, and Player.open() awaits an attached controller's
      // initialization, so the media is opened with video decoding enabled.
      _videoController = VideoController(player);
    } catch (e) {
      debugPrint('[media_kit] video initialization failed: $e');
      _failed = true;
      return;
    }
    final player = _player!;
    _subs.add(
      player.stream.error.listen((e) {
        debugPrint('[media_kit] video error for ${widget.uri}: $e');
        if (mounted) setState(() => _failed = true);
      }),
    );
    _subs.add(
      player.stream.playing.listen((p) {
        if (mounted) setState(() => _playing = p);
        if (p) {
          widget.coordinator?.notifyPlaying(widget.id, () => _player?.pause());
        } else {
          widget.coordinator?.notifyStopped(widget.id);
        }
      }),
    );
    _subs.add(player.stream.width.listen((_) => _updateAspect()));
    _subs.add(player.stream.height.listen((_) => _updateAspect()));
    _openSource();
  }

  @override
  void didUpdateWidget(_GeneratedVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) _openSource();
  }

  Future<void> _openSource() async {
    final player = _player;
    if (player == null || _videoController == null) return;
    final epoch = ++_openEpoch;
    if (_ready || _failed) {
      setState(() {
        _ready = false;
        _failed = false;
        _playing = false;
      });
    }
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('cache-dir', await _mpvCacheDir());
      }
      if (!mounted || epoch != _openEpoch) return;
      // Open paused so multiple clips don't all autoplay.
      await player.open(Media(widget.uri.toString()), play: false);
      if (!mounted || epoch != _openEpoch) return;
      setState(() => _ready = true);
    } catch (e) {
      debugPrint('[media_kit] open failed for ${widget.uri}: $e');
      if (mounted && epoch == _openEpoch) setState(() => _failed = true);
    }
  }

  void _updateAspect() {
    final player = _player;
    if (player == null) return;
    final w = player.state.width;
    final h = player.state.height;
    if (w != null && h != null && w > 0 && h > 0) {
      final next = w / h;
      if (next != _aspect && mounted) setState(() => _aspect = next);
    }
  }

  void _togglePlay() {
    final player = _player;
    if (player == null) return;
    _playing ? player.pause() : player.play();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    widget.coordinator?.notifyStopped(widget.id);
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final videoController = _videoController;
    if (_failed || player == null || videoController == null) {
      return const SizedBox(
        height: 100,
        child: Center(
          child: Text(
            'video unavailable',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    if (!_ready) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return GestureDetector(
      key: ValueKey('play-video-${widget.id}'),
      onTap: _togglePlay,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: _aspect,
            child: Video(
              controller: videoController,
              controls: NoVideoControls,
            ),
          ),
          if (!_playing)
            Container(
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(12),
              child: const Icon(
                Icons.play_arrow,
                color: Colors.white,
                size: 32,
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _VideoProgressBar(player: player),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: _MediaActionButton(
              onPressed: () => showMediaActions(
                context,
                widget.uri,
                isVideo: true,
                mediaExport: widget.mediaExport,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thin scrubbable progress bar, mirroring the look of the platform
/// VideoProgressIndicator (played/buffered/background tint) since
/// media_kit_video's default controls are replaced with [NoVideoControls].
class _VideoProgressBar extends StatelessWidget {
  const _VideoProgressBar({required this.player});

  final Player player;

  void _seekToFraction(BuildContext context, double dx, double width) {
    final duration = player.state.duration;
    if (duration == Duration.zero) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    player.seek(duration * fraction);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, positionSnap) {
        return StreamBuilder<Duration>(
          stream: player.stream.duration,
          initialData: player.state.duration,
          builder: (context, durationSnap) {
            final position = positionSnap.data ?? Duration.zero;
            final duration = durationSnap.data ?? Duration.zero;
            final fraction = duration.inMilliseconds > 0
                ? (position.inMilliseconds / duration.inMilliseconds).clamp(
                    0.0,
                    1.0,
                  )
                : 0.0;
            return LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _seekToFraction(
                    context,
                    d.localPosition.dx,
                    constraints.maxWidth,
                  ),
                  onHorizontalDragUpdate: (d) => _seekToFraction(
                    context,
                    d.localPosition.dx,
                    constraints.maxWidth,
                  ),
                  child: SizedBox(
                    height: 6,
                    width: double.infinity,
                    child: Stack(
                      children: [
                        Container(color: Colors.white24),
                        FractionallySizedBox(
                          widthFactor: fraction,
                          child: Container(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Small overlay button for [showMediaActions], shared by the image and
/// video views.
class _MediaActionButton extends StatelessWidget {
  const _MediaActionButton({
    required this.onPressed,
    this.icon = Icons.more_vert,
    this.tooltip = 'Media actions',
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 18),
        tooltip: tooltip,
        onPressed: onPressed,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// Share / save-to-gallery bottom sheet for a generated media view.
/// Exports [uri] remotely so sharing and saving use bounded downloads.
Future<void> showMediaActions(
  BuildContext context,
  Uri uri, {
  required bool isVideo,
  required MediaExportService mediaExport,
}) async {
  if (!context.mounted) return;
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('Share'),
            onTap: () => Navigator.pop(sheetContext, 'share'),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('Save to Photos'),
            onTap: () => Navigator.pop(sheetContext, 'save'),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;

  try {
    Future<bool> confirm(MediaDownloadInfo info) =>
        _confirmMediaDownload(context, info);

    if (action == 'share') {
      await mediaExport.shareRemote(uri, confirmAfterHeaders: confirm);
      return;
    }

    final error = await mediaExport.saveRemote(
      uri,
      isVideo: isVideo,
      confirmAfterHeaders: confirm,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'Saved to Photos')));
  } on MediaDownloadDeclinedException {
    return;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not load media: $e')));
    }
  }
}

Future<bool> _confirmMediaDownload(
  BuildContext context,
  MediaDownloadInfo info,
) async {
  if (!context.mounted) return false;
  final declaredBytes = info.declaredBytes;
  final description = declaredBytes == null
      ? 'The download size is unknown.'
      : 'This download is ${(declaredBytes / (1024 * 1024)).toStringAsFixed(1)} MiB.';
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Download media?'),
      content: Text('$description Continue?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return accepted ?? false;
}
