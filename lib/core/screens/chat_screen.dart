// Chat screen with real-time streaming via REST API.
// Uses REST endpoints: POST /api/sessions/{id}/chat and
// GET /api/sessions/{id}/messages.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../models/pending_chat_send.dart';
import '../services/speech_recognition_coordinator.dart';

import '../services/background_activity_service.dart';
import '../services/character_voice_prefs.dart';
import '../services/chatterbox_service.dart';
import '../services/connection_manager.dart';
import '../services/comfyui.dart';
import '../services/media_cache_service.dart';
import '../services/media_export_service.dart';
import '../services/reply_notification_service.dart';
import '../services/tts_provider.dart';
import '../services/xtts_service.dart';
import '../utils/responsive.dart';
import '../utils/reveal_row.dart';
import '../utils/row_keys.dart';
import '../widgets/cached_media_thumbnail.dart';
import 'call_screen.dart';
import 'character_picker_screen.dart';
import 'media_gallery_screen.dart';
import 'session_list_screen.dart';
import 'skills_screen.dart';

/// Identifies the in-chat search field.
const Key searchFieldKey = Key('chat-search-field');

class ChatScreen extends StatefulWidget {
  final SavedConnection connection;
  final Session session;

  /// Character whose card was just picked. When set, the screen sends the
  /// persona as its opening turn (see _loadPickedCharacter) and uses the
  /// card art as the chat background. Null for an ordinary chat — a
  /// previously-picked character is restored from prefs instead.
  final CharacterSummary? character;
  final CharacterCard? characterCard;

  /// Test seam. Production never passes these.
  ///
  /// ChatScreen owns the app's riskiest logic -- the optimistic send, the
  /// token stream, the interrupted-turn recovery -- and none of it was
  /// reachable from a test, because the HTTP client and the TTS backend were
  /// constructed inside the State from `connection`. These two overrides are
  /// the whole seam: everything else the screen touches is either pure or
  /// already mockable (SharedPreferences).
  final http.Client? httpClient;
  final TtsProvider Function()? ttsOverride;
  final MediaCachePort? mediaCache;
  final MediaExportService? mediaExport;

  const ChatScreen({
    required this.connection,
    required this.session,
    this.character,
    this.characterCard,
    this.httpClient,
    this.ttsOverride,
    this.mediaCache,
    this.mediaExport,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  MediaCachePort get _mediaCache =>
      widget.mediaCache ?? MediaCacheService.appDefault;
  MediaExportService get _mediaExport =>
      widget.mediaExport ?? MediaExportService.appDefault;

  List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _toolMessages = [];
  bool _loading = true;
  String? _error;
  late final ApiClient _client;
  late final GatewayChatClient _gateway;

  // Chat sending state
  final _textController = TextEditingController();
  bool _sending = false;
  bool _streaming = false;
  StreamCancelToken? _streamCancelToken;
  // True while the background-keepalive foreground service is running.
  // Started the moment a send begins (see _sendMessage) — not reactively on
  // backgrounding — so there's no async gap between "app backgrounds" and
  // "OS actually protects the process" for the OS to suspend the socket in.
  // Costs a brief notification on every send, including ones that never
  // leave the foreground.
  bool _backgroundServiceActive = false;

  // Image attach (gallery picker) — one pending image per send, mirroring
  // Telegram's attach-then-caption flow.
  final ImagePicker _imagePicker = ImagePicker();
  Uint8List? _pickedImageBytes;
  String? _pickedImageMimeType;

  /// The picked image already base64-encoded. Computed in [_pickImage] so the
  /// encode doesn't land on the main isolate when Send is tapped.
  String? _pickedImageDataUrl;

  // Voice input / spoken replies
  final Object _speechOwner = Object();
  final SpeechRecognitionCoordinator _speechCoordinator =
      SpeechRecognitionCoordinator.instance;
  SpeechToText get _speechToText => _speechCoordinator.speech;
  late TtsProvider _xtts =
      widget.ttsOverride?.call() ??
      XttsService(fallbackHost: widget.connection.host);
  bool _speechAvailable = false;
  bool _listening = false;
  bool _voiceReplyEnabled = true;
  bool _awaitingVoiceReply = false;
  String? _voiceStatus;
  String? _sttLocaleId;
  // The assistant message currently being spoken by a manual replay tap.
  // Null when idle. Compared by identity against the message maps in _messages.
  Map<String, dynamic>? _speakingMessage;

  // Verbose mode
  bool _verboseMode = false;

  // ComfyUI base URL — used to fetch images referenced in tool results.
  String _comfyBaseUrl = ComfyUiPrefs.defaultBaseUrl;

  // Bumped whenever a new turn starts, the messages are manually refetched, or
  // the screen is disposed. A late-media poll captures this at launch and stops
  // if it changes, so a stale poll from a previous turn can't clobber newer
  // state.
  int _mediaPollGen = 0;

  // Auto-continue: after a reply finishes (voice playback done, or a short
  // fixed delay if voice reply is off), automatically send another turn at a
  // random interval, indefinitely, until toggled off or Stop is hit. The
  // continuation turn is a fixed, content-neutral nudge — this only drives
  // the send loop, it never picks or steers what gets said.
  bool _autoContinueEnabled = false;
  Timer? _autoContinueTimer;
  final _autoContinueRandom = Random();

  // Media discovered mid-stream (via a completed image_generate or
  // video_generate tool call) that haven't landed in a getMessages() refetch
  // yet — rendered as their own row right under the in-progress reply so
  // generated media shows up as soon as it's ready instead of waiting for the
  // whole turn to finish.
  final List<String> _liveMediaUrls = [];

  // True once this gateway has been seen emitting a rendered `filename` on a
  // completed media tool's hermes.tool.progress frame. That frame is the whole
  // reason the read-after-write polling exists, so a server that sends it
  // makes every poll pure waste: each poll refetches the ENTIRE transcript and
  // jsonDecodes it on the UI isolate, and a turn with two generated images
  // fired up to ten of those. Persisted per connection so the very first turn
  // after a cold start doesn't pay for the discovery again.
  bool _serverSendsMediaFilename = false;

  static String _mediaFilenameCapKey(String connectionId) =>
      'server_sends_media_filename_$connectionId';

  Future<void> _rememberMediaFilenameCapability() async {
    if (_serverSendsMediaFilename) return;
    _serverSendsMediaFilename = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mediaFilenameCapKey(widget.connection.id), true);
  }

  // Scroll management
  final _scrollController = ScrollController();
  bool _showScrollToBottom = false;
  double _lastPixels = 0;
  // Restored scroll offset per session. Static so it survives the screen
  // being popped and reopened, which means nothing ever disposes it — so it
  // is bounded rather than left to grow one entry per session for the life of
  // the process. Dart Maps keep insertion order, so the oldest entry is
  // simply the first key.
  static const int _maxSavedPositions = 50;
  static final Map<String, double> _savedPositions = {};

  static void _rememberScrollPosition(String sessionId, double pixels) {
    _savedPositions.remove(sessionId);
    _savedPositions[sessionId] = pixels;
    while (_savedPositions.length > _maxSavedPositions) {
      _savedPositions.remove(_savedPositions.keys.first);
    }
  }

  // Streaming-token batching: coalesce onToken callbacks into periodic
  // setState flushes instead of rebuilding on every token. Mirrors the
  // gateway's own Telegram adapter text-batch delay (adapter.py
  // _flush_text_batch) — a short fixed delay smooths bursty output into a
  // steady cadence without the UI feeling laggy.
  static const _tokenFlushDelay = Duration(milliseconds: 120);
  final StringBuffer _pendingTokens = StringBuffer();
  Timer? _tokenFlushTimer;

  /// Flush interval, widened as the in-progress reply grows.
  ///
  /// Every flush re-parses the WHOLE accumulated reply: flutter_markdown
  /// re-runs md.Document over `data` whenever it changes (see
  /// _MarkdownWidgetState.didUpdateWidget), so a fixed 120ms cadence makes
  /// total parse work quadratic in reply length — a 20KB answer gets parsed
  /// from scratch ~160 times, and the last parses are the expensive ones.
  /// Backing off past a couple of KB keeps the start of a reply feeling live
  /// (where the parse is cheap and the eye is on it) and stops paying 8Hz for
  /// re-parsing a wall of text nobody is reading character-by-character.
  ///
  /// Deliberately NOT solved by rendering the streaming bubble as plain Text:
  /// that would drop the character-chat dialogue/narration styling for the
  /// whole duration of the reply and snap it in at the end.
  Duration _flushDelayFor(int contentLength) {
    if (contentLength < 2000) return _tokenFlushDelay;
    if (contentLength < 8000) return const Duration(milliseconds: 250);
    return const Duration(milliseconds: 400);
  }

  /// Length of the assistant reply currently being streamed into, used to
  /// pick the flush cadence above.
  int get _streamingContentLength {
    if (_messages.isEmpty || _messages.last['role'] != 'assistant') return 0;
    final content = _messages.last['content'];
    return content is String ? content.length : 0;
  }

  // In-chat "/" commands, mirroring a small subset of the Telegram gateway
  // adapter's slash-command menu (/model, /new, /skills). These are handled
  // entirely client-side — the API server endpoint this screen talks to is
  // stateless and doesn't dispatch slash commands the way the gateway's
  // platform adapters do, so a match here short-circuits before anything is
  // sent to the model.
  static const Map<String, String> _slashCommands = {
    '/new': 'Start a new chat',
    '/model': 'Switch model',
    '/skills': 'View skills',
  };
  DashboardClient? _dashboard;

  DashboardClient _dashboardClient() {
    return _dashboard ??= DashboardClient(
      host: widget.connection.host,
      port: widget.connection.dashboardPort,
      pathPrefix: widget.connection.dashboardPrefix ?? '',
      proxied: widget.connection.dashboardProxied,
      useHttps: widget.connection.useHttps,
      username: widget.connection.dashboardUsername,
      password: widget.connection.dashboardPassword,
    );
  }

  @override
  void initState() {
    super.initState();
    _client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
      pathPrefix: widget.connection.gatewayPrefix ?? '',
      httpClient: widget.httpClient,
    );
    _gateway = GatewayChatClient(_client);
    _fetchMessages();
    _loadStartupPrefs();
    // Kept separate from the batch: this one is permission-gated and can sit
    // behind a system dialog, so folding it in would hold every other setting
    // hostage to the microphone prompt.
    _initVoice();
    _initTtsProvider();
    _scrollController.addListener(_onScroll);
    _textController.addListener(_onTextChanged);
  }

  /// Reads every SharedPreferences-derived setting the screen opens with and
  /// applies them in ONE setState.
  ///
  /// These used to be five independent initializers, each awaiting prefs and
  /// then calling its own setState — up to five extra full rebuilds of the
  /// screen during the exact moment the user is waiting for the chat to
  /// appear. SharedPreferences caches its instance after the first call, so
  /// the reads themselves are cheap; the rebuilds were the cost.
  Future<void> _loadStartupPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionId = widget.session.id;

    // Remembering the session is a pure write, nothing renders from it.
    await prefs.setString('last_session_id_${widget.connection.id}', sessionId);

    final verbose = prefs.getBool('verbose_mode') ?? false;
    final comfyUrl = ComfyUi.normalizeBaseUrl(
      prefs.getString(ComfyUiPrefs.baseUrl) ?? ComfyUiPrefs.defaultBaseUrl,
    );
    _serverSendsMediaFilename =
        prefs.getBool(_mediaFilenameCapKey(widget.connection.id)) ?? false;

    // Character: an explicitly picked one is persisted now, otherwise restore
    // whatever this session was last opened with.
    final picked = widget.character;
    if (picked != null) {
      await prefs.setString(_characterNameKey(sessionId), picked.name);
      await prefs.setString(_characterImageKey(sessionId), picked.primaryImage);
    }
    final characterImage =
        picked?.primaryImage ?? prefs.getString(_characterImageKey(sessionId));
    final characterName =
        picked?.name ?? prefs.getString(_characterNameKey(sessionId));

    if (!mounted) return;
    _invalidateDisplayList();
    setState(() {
      _verboseMode = verbose;
      _comfyBaseUrl = comfyUrl;
      _characterImagePath = characterImage;
      _characterName = characterName;
    });

    // The persona turn has to go after the state is applied, because it sends
    // a message and the send path reads _characterImagePath.
    if (picked != null) await _sendCharacterSetup();
  }

  // ── Character background ────────────────────────────────────────────
  //
  // The picked character's image path (relative to the gateway's characters
  // dir), used as the chat background. Persisted per session so reopening a
  // chat restores its character art.
  String? _characterImagePath;
  String? _characterName;

  // Stored as two keys rather than one delimited string: character names
  // and image filenames both contain spaces, punctuation and unicode
  // ("Bianca Laurent", "Julia Villasenor"), so any in-band separator is a
  // bug waiting to happen.
  static String _characterImageKey(String sessionId) =>
      'character_image_$sessionId';
  static String _characterNameKey(String sessionId) =>
      'character_name_$sessionId';

  /// Sends the picked card's persona as the opening turn. It goes as an
  /// ordinary user message because the gateway rebuilds history from its own
  /// DB and ignores any client-supplied history — a persona only persists if
  /// it is a real message. It's tagged with CharacterCard.setupMarker so the
  /// transcript can hide the prose while the model still receives it.
  Future<void> _sendCharacterSetup() async {
    final card = widget.characterCard;
    if (card == null) return;
    await _sendMessage(textOverride: card.buildSetupMessage());
  }

  Future<void> _pickCharacter() async {
    final picked = await Navigator.push<CharacterSummary>(
      context,
      MaterialPageRoute(
        builder: (_) => CharacterPickerScreen(connection: widget.connection),
      ),
    );
    if (picked == null || !mounted) return;

    CharacterCard card;
    try {
      card = await _client.getCharacterCard(picked.primaryImage);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not load ${picked.name}: $e',
            style: const TextStyle(color: Colors.black87),
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (!mounted) return;

    // Each character gets its own conversation — injecting a second persona
    // into an existing thread leaves the model with conflicting characters.
    final session = Session(
      id: GatewayChatClient.generateSessionId(),
      title: picked.name,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    );
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          connection: widget.connection,
          session: session,
          character: picked,
          characterCard: card,
        ),
      ),
    );
  }

  void _openSessionList() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionListScreen(connection: widget.connection),
      ),
    );
  }

  /// Starts a fresh session, replacing this screen (not pushing on top of
  /// it) so the back button doesn't stack chats — same generateSessionId +
  /// placeholder-Session shape SessionListScreen._createNewSession uses.
  void _startNewChat() {
    final session = Session(
      id: GatewayChatClient.generateSessionId(),
      title: 'New Chat',
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    );
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(connection: widget.connection, session: session),
      ),
    );
  }

  /// Rebuilds only when the slash-command suggestion row should appear or
  /// disappear, so this doesn't add a rebuild per keystroke on ordinary text.
  bool _showingSlashSuggestions = false;
  void _onTextChanged() {
    final showing = _slashSuggestions().isNotEmpty;
    if (showing != _showingSlashSuggestions) {
      setState(() => _showingSlashSuggestions = showing);
    }
  }

  /// Slash commands whose name starts with the current input, shown only
  /// while the user is still typing the command name (no space yet).
  List<MapEntry<String, String>> _slashSuggestions() {
    final text = _textController.text;
    if (!text.startsWith('/') || text.contains(' ')) return const [];
    final query = text.toLowerCase();
    return _slashCommands.entries
        .where((e) => e.key.startsWith(query))
        .toList();
  }

  /// Swap the default XTTS backend for the one chosen in Settings (Chatterbox)
  /// once prefs are available. speak()/stop() read [_xtts] fresh each call, so
  /// a mid-init swap is safe.
  Future<void> _initTtsProvider() async {
    // An injected backend is the one the test wants; don't swap it out from
    // under them for whatever the prefs happen to say.
    if (widget.ttsOverride != null) return;
    final prefs = await SharedPreferences.getInstance();
    final selected = await ttsProviderForPrefs(
      prefs,
      fallbackHost: widget.connection.host,
    );
    if (!mounted) {
      selected.dispose();
      return;
    }
    if (selected is! XttsService) {
      _xtts.dispose();
      _xtts = selected;
    } else {
      // Already holding an XttsService (the default) — this freshly built
      // one won't be used, so release its AudioPlayer/http.Client now.
      selected.dispose();
    }
  }

  @override
  void dispose() {
    if (_backgroundServiceActive) {
      _backgroundServiceActive = false;
      stopBackgroundSendService();
    }
    // Stop any in-flight late-media poll from touching state after teardown.
    _mediaPollGen++;
    _rememberScrollPosition(widget.session.id, _lastPixels);
    _tokenFlushTimer?.cancel();
    _streamCancelToken?.cancel();
    _autoContinueTimer?.cancel();
    _speechToText.cancel();
    _speechCoordinator.release(_speechOwner);
    _xtts.dispose();
    _client.close();
    _dashboard?.close();
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _searchController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initVoice() async {
    try {
      // Voice + language are handled by the XTTS server (see Settings → Voice).
      // Here we only derive the speech-to-text locale from the saved language.
      final prefs = await SharedPreferences.getInstance();
      final language = prefs.getString(XttsPrefs.language);
      _sttLocaleId = (language != null && language.isNotEmpty)
          ? language.replaceAll('-', '_')
          : null;

      _speechCoordinator.claim(
        _speechOwner,
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
      );
      final available = await _speechCoordinator.initialize();
      if (!mounted) return;
      setState(() {
        _speechAvailable = available;
        _voiceStatus = available ? null : 'Speech recognition is unavailable';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _speechAvailable = false;
        _voiceStatus = 'Voice setup failed: $e';
      });
    }
  }

  void _handleSpeechStatus(String status) {
    if (!mounted) return;
    final listening = status == 'listening';
    setState(() {
      _listening = listening;
      if (!listening && status == 'done') {
        _voiceStatus = null;
      }
    });
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    if (!mounted) return;
    setState(() {
      _listening = false;
      _voiceStatus = error.errorMsg;
    });
  }

  Future<void> _toggleVoiceInput() async {
    if (_streaming || _sending || _loading) return;
    // Don't capture our own TTS reply as a "turn". Stop the player first and
    // bail if it was mid-playback.
    if (_xtts.isPlaying) {
      await _xtts.stop();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Stopped reply to listen'),
          duration: Duration(seconds: 1),
        ),
      );
    }
    if (_listening) {
      await _speechToText.stop();
      if (!mounted) return;
      setState(() => _listening = false);
      return;
    }

    if (!_speechAvailable) {
      await _initVoice();
      if (!_speechAvailable) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _voiceStatus ?? 'Speech recognition is unavailable',
              ),
            ),
          );
        }
        return;
      }
    }

    await _xtts.stop();
    if (!mounted) return;
    _speechCoordinator.claim(
      _speechOwner,
      onStatus: _handleSpeechStatus,
      onError: _handleSpeechError,
    );
    setState(() => _voiceStatus = 'Listening…');
    await _speechToText.listen(
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        localeId: _sttLocaleId,
      ),
      onResult: _handleSpeechResult,
    );
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    final recognised = result.recognizedWords.trim();
    if (recognised.isEmpty || !mounted) return;
    setState(() {
      _textController.text = recognised;
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    });
    if (result.finalResult) {
      _sendMessage();
    }
  }

  /// Speaks a reply that arrived on its own (the automatic voice reply), as
  /// opposed to [_replayMessage]'s manual tap.
  ///
  /// [message] is the transcript row the text came from. Passing it makes the
  /// automatic path drive the same `_speakingMessage` state the manual one
  /// does, so the per-bubble stop/replay icon and the "jump to it" bar reflect
  /// an auto-spoken reply too. Previously only manual replay set it, which
  /// meant the more common path showed no speaking state at all.
  /// The active character's assigned voice (see CharacterVoicePrefs), or
  /// null when no character is active or it uses the app-wide default from
  /// Settings. `_xtts`'s concrete type already reflects whichever backend
  /// _initTtsProvider swapped in, so checking it directly is always accurate
  /// to what's actually active -- no separate prefs read needed.
  Future<String?> _characterVoiceOverride() async {
    final imagePath = _characterImagePath;
    if (imagePath == null) return null;
    final provider = _xtts is ChatterboxService ? 'chatterbox' : 'xtts';
    return CharacterVoicePrefs.get(imagePath, provider);
  }

  Future<void> _speakAssistantText(
    String text, {
    void Function()? onComplete,
    Map<String, dynamic>? message,
  }) async {
    final spokenText = text.trim();
    if (spokenText.isEmpty || !_voiceReplyEnabled) {
      onComplete?.call();
      return;
    }
    // Only claim the speaking slot if there is actually something to say,
    // matching _replayMessage's silent no-op on an unspeakable reply.
    final speakable = XttsService.stripForSpeech(
      spokenText,
      keepActions: _characterImagePath != null,
    );
    if (speakable.isEmpty) {
      onComplete?.call();
      return;
    }
    if (message != null && mounted) {
      setState(() => _speakingMessage = message);
    }
    void finish() {
      if (message != null && mounted && identical(_speakingMessage, message)) {
        setState(() => _speakingMessage = null);
      }
      onComplete?.call();
    }

    try {
      await _xtts.speak(
        spokenText,
        onComplete: finish,
        keepActions: _characterImagePath != null,
        voiceOverride: await _characterVoiceOverride(),
      );
    } catch (e) {
      finish();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'TTS failed: $e',
            style: const TextStyle(color: Colors.black87),
          ),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  /// Re-speaks an assistant message on demand (the per-message replay button).
  /// Independent of [_voiceReplyEnabled] — manual replay works even when spoken
  /// replies are off — but requires an XTTS speaker to be configured.
  /// Tapping the message currently speaking stops it (toggle).
  /// Opens [msg]'s text in an edit dialog; confirming sends the edited text
  /// as a new message. See _MessageBubble.onEdit's doc comment for why this
  /// can't replace the original message in place.
  Future<void> _editAndResend(Map<String, dynamic> msg) async {
    final original = parseMessageContent(msg['content']).text;
    final edited = await showDialog<String>(
      context: context,
      builder: (_) => _EditMessageDialog(initialText: original),
    );
    if (edited == null || edited.isEmpty || !mounted) return;
    await _sendMessage(textOverride: edited);
  }

  /// Re-sends the last user turn as a new message, producing a fresh reply
  /// appended after the current one -- see _MessageBubble.onRegenerate's doc
  /// comment for why this can't replace the last reply in place.
  Future<void> _regenerateLastReply() async {
    final lastUser = _messages.reversed.firstWhere(
      (m) => (m['role'] as String?) == 'user',
      orElse: () => const <String, dynamic>{},
    );
    final text = parseMessageContent(lastUser['content']).text.trim();
    if (text.isEmpty) return;
    await _sendMessage(textOverride: text);
  }

  Future<void> _replayMessage(Map<String, dynamic> msg) async {
    final wasSpeaking = identical(msg, _speakingMessage);
    debugPrint(
      '[Replay] tapped: ${parseMessageContent(msg['content']).text.length} chars, '
      'wasSpeaking=$wasSpeaking',
    );

    // If this is the message currently speaking, stop and bail BEFORE doing
    // any other work. Doing it after the stop() awaiting leaves a window
    // where the prior speak()'s onComplete has already cleared _speakingMessage
    // and the "set then check toggle" no longer matches the user's intent.
    if (wasSpeaking) {
      debugPrint('[Replay] toggle OFF (stop)');
      setState(() => _speakingMessage = null);
      await _xtts.stop();
      return;
    }

    await _xtts.stop();
    if (!mounted) return;

    final content = parseMessageContent(msg['content']).text;

    // Nothing speakable in this message -> silent no-op (don't set state).
    // Must use the same keepActions as the speak() below, or a pure-narration
    // reply in a character chat looks empty here and never plays.
    final speakable = XttsService.stripForSpeech(
      content,
      keepActions: _characterImagePath != null,
    );
    if (speakable.isEmpty) {
      debugPrint('[Replay] no speakable text -> no-op');
      return;
    }

    if (!mounted) return;
    setState(() => _speakingMessage = msg);
    debugPrint('[Replay] requesting speak (${speakable.length} chars)...');

    try {
      await _xtts.speak(
        content,
        keepActions: _characterImagePath != null,
        voiceOverride: await _characterVoiceOverride(),
        onComplete: () {
          debugPrint('[Replay] playback complete');
          if (mounted) setState(() => _speakingMessage = null);
        },
      );
    } catch (e) {
      debugPrint('[Replay] FAILED: $e');
      if (!mounted) return;
      setState(() => _speakingMessage = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Voice playback failed: $e',
            style: const TextStyle(color: Colors.black87),
          ),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // Object identity alone isn't enough: _messages (and therefore every Map
  // instance in it) gets wholesale-replaced on every refetch (onDone,
  // _fetchMessages, _pollForLateMedia), so a replay started before a refetch
  // would otherwise desync from the bubble that's actually still playing.
  // Falls back to role+text equality, which survives the refetch since the
  // same historical turn's content doesn't change.
  bool _isSpeakingMessage(Map<String, dynamic> msg) {
    final speaking = _speakingMessage;
    if (speaking == null) return false;
    if (identical(msg, speaking)) return true;
    return (msg['role'] as String?) == (speaking['role'] as String?) &&
        parseMessageContent(msg['content']).text ==
            parseMessageContent(speaking['content']).text;
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      _lastPixels = _scrollController.position.pixels;
    }
    // Previously gated on _streaming, which meant the flag only ever went
    // true mid-reply and then stayed stale — and nothing rendered it anyway.
    // Being scrolled up is worth an escape hatch whether or not a reply is in
    // flight, so this now just tracks the position.
    final atBottom = isNearBottom(_scrollController);
    if (atBottom == _showScrollToBottom) {
      setState(() => _showScrollToBottom = !atBottom);
    }
  }

  /// Applies buffered streaming tokens to the placeholder assistant message
  /// in one setState, then clears the timer so the next onToken schedules
  /// a fresh flush.
  void _flushPendingTokens() {
    _tokenFlushTimer = null;
    if (_pendingTokens.isEmpty) return;
    final chunk = _pendingTokens.toString();
    _pendingTokens.clear();
    if (!mounted) return;
    // Stay pinned to the newest text as it arrives, but only if the view was
    // already at the bottom -- scrolling up to re-read something must not be
    // yanked back. _showScrollToBottom is exactly that "user has scrolled
    // away" signal. jumpTo rather than animateTo: an animation restarted
    // every flush fights itself and never settles.
    final follow = !_showScrollToBottom;
    setState(() {
      if (_messages.isNotEmpty && _messages.last['role'] == 'assistant') {
        _messages.last['content'] =
            (_messages.last['content'] as String) + chunk;
      }
    });
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
    }
  }

  Future<void> _scrollToBottom() =>
      scrollToEnd(_scrollController, isMounted: () => mounted);

  Future<void> _fetchMessages() async {
    // A manual/refresh fetch supersedes any in-flight late-media poll.
    _mediaPollGen++;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final messages = await _client.getMessages(widget.session.id);
      if (!mounted) return;
      _extractToolMessages(messages);
      setState(() {
        _messages = messages;
        _loading = false;
      });
      final saved = _savedPositions[widget.session.id];
      if (saved != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              saved.clamp(0.0, _scrollController.position.maxScrollExtent),
            );
          }
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      final errStr = e.toString();
      if (errStr.contains('404') || errStr.contains('not found')) {
        _invalidateDisplayList();
        setState(() {
          _messages = [];
          _loading = false;
        });
        return;
      }
      setState(() {
        _error = errStr;
        _loading = false;
      });
      // A refresh failure with an already-loaded conversation shouldn't hide
      // that conversation behind a full-screen error (see _buildBody, which
      // only shows the full-screen state when _messages is empty) — surface
      // it as a SnackBar instead so the chat stays visible underneath.
      if (_messages.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Refresh failed: $errStr',
              style: const TextStyle(color: Colors.black87),
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  // extractMediaFilenames runs a regex over a tool message's FULL content,
  // and tool outputs can be tens of KB. _buildBody re-derives the display
  // list on every rebuild — ~8x/second while a reply streams (see
  // _flushPendingTokens) — so without memoization that regex re-scans the
  // entire transcript every frame; measured at ~15ms/frame with 50 tool
  // messages on desktop, which alone blows the 16.7ms/60fps budget on a
  // phone. A tool message's content never changes once set, and a refetch
  // builds new map objects, so caching per map object is both safe and
  // self-invalidating.
  final Expando<List<String>> _mediaNamesCache = Expando<List<String>>();

  List<String> _mediaNamesIn(Map<String, dynamic> msg) {
    final cached = _mediaNamesCache[msg];
    if (cached != null) return cached;
    final names = ComfyUi.extractMediaFilenames(
      (msg['content'] as String?) ?? '',
    );
    _mediaNamesCache[msg] = names;
    return names;
  }

  /// All generated-media URLs currently derivable from a message list — the
  /// same harvest the build() path uses (tool messages → filenames → view URL).
  Set<String> _mediaUrlsIn(List<Map<String, dynamic>> messages) {
    final urls = <String>{};
    for (final msg in messages) {
      if ((msg['role'] as String?) != 'tool') continue;
      for (final name in _mediaNamesIn(msg)) {
        urls.add(ComfyUi.viewUrl(_comfyBaseUrl, name));
      }
    }
    return urls;
  }

  /// Work around a read-after-write race: the image tool can persist its
  /// tool-result message (which carries the rendered file path) a beat after
  /// the SSE stream signals done, so the single refetch in [onDone] sometimes
  /// misses it and the image only appears after leaving and re-opening the
  /// chat. Re-pull a few times with a short delay; adopt the first fetch whose
  /// media set is larger than what we're already showing, then stop.
  Future<void> _pollForLateMedia() async {
    // On a server that reports rendered filenames mid-stream there is nothing
    // for this to discover: the media is already in _liveMediaUrls, and onDone
    // now keeps any entry the refetch hasn't caught up with instead of
    // clearing it, so a late-landing tool row no longer makes the image blink
    // out. Skipping the poll saves up to four full-transcript refetches and
    // main-isolate jsonDecodes per turn.
    if (_serverSendsMediaFilename) return;
    final gen = _mediaPollGen;
    var known = _mediaUrlsIn(_messages).length;
    for (var attempt = 0; attempt < 4; attempt++) {
      await Future.delayed(const Duration(milliseconds: 1500));
      // Abort if a new turn started, a manual refetch ran, or we left/streamed.
      if (!mounted || gen != _mediaPollGen || _streaming) return;
      List<Map<String, dynamic>> messages;
      try {
        messages = await _client.getMessages(widget.session.id);
      } catch (_) {
        continue;
      }
      if (!mounted || gen != _mediaPollGen || _streaming) return;
      final fresh = _mediaUrlsIn(messages).length;
      if (fresh > known) {
        _extractToolMessages(messages);
        setState(() => _messages = messages);
        return;
      }
    }
  }

  /// Fired the moment an `image_generate` tool call reports "completed"
  /// mid-stream. The tool-result message carrying the rendered file path
  /// lands in the DB a beat later, so poll briefly and, as soon as it shows
  /// up, surface it via [_liveMediaUrls] instead of waiting for the whole
  /// turn to finish and the [onDone] refetch to happen.
  Future<void> _pollForLiveMedia() async {
    final gen = _mediaPollGen;
    final known = _mediaUrlsIn(_messages)..addAll(_liveMediaUrls);
    for (var attempt = 0; attempt < 5; attempt++) {
      await Future.delayed(const Duration(milliseconds: 800));
      // Abort if a new turn started, a manual refetch ran, or the turn ended
      // -- matches _pollForLateMedia's abort conditions so a straggling poll
      // can't re-add a URL to _liveMediaUrls after onDone already cleared it.
      if (!mounted || gen != _mediaPollGen || !_streaming) return;
      List<Map<String, dynamic>> messages;
      try {
        messages = await _client.getMessages(widget.session.id);
      } catch (_) {
        continue;
      }
      if (!mounted || gen != _mediaPollGen || !_streaming) return;
      final fresh = _mediaUrlsIn(messages).difference(known);
      if (fresh.isNotEmpty) {
        _invalidateDisplayList();
        setState(() {
          // Guarded like the fast path's equivalent add (below): two polls
          // completing close together on a legacy (no-filename) server must
          // not add the same URL twice.
          for (final url in fresh) {
            if (!_liveMediaUrls.contains(url)) _liveMediaUrls.add(url);
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        return;
      }
    }
  }

  void _extractToolMessages(List<Map<String, dynamic>> messages) {
    // Always called immediately before _messages is replaced, so this single
    // bump covers both inputs at every refetch site.
    _invalidateDisplayList();
    _toolMessages.clear();
    for (final msg in messages) {
      final role = (msg['role'] as String?) ?? '';
      if (role != 'tool') continue;

      final name =
          (msg['name'] as String?) ??
          (msg['tool_name'] as String?) ??
          (msg['toolCallName'] as String?) ??
          '';
      final toolCallId = (msg['tool_call_id'] as String?) ?? '';
      final content = (msg['content'] as String?) ?? '';

      String toolName = name.isNotEmpty ? name : '';
      if (toolName.isEmpty && content.isNotEmpty) {
        final match = RegExp(r'source="([^"]+)"').firstMatch(content);
        if (match != null) toolName = match.group(1)!;
      }
      if (toolName.isEmpty) toolName = 'tool';

      final emoji = _toolEmoji(toolName);
      _toolMessages.add({
        'role': 'tool_progress',
        'content': '$emoji $toolName — done',
        'toolCallId': toolCallId,
        'status': 'completed',
        'tool': toolName,
      });
    }
  }

  String _toolEmoji(String toolName) {
    switch (toolName) {
      case 'browser_navigate':
      case 'browser_console':
      case 'browser':
        return '🌐';
      case 'read_file':
      case 'read':
        return '📄';
      case 'write_file':
      case 'write':
        return '✏️';
      case 'search':
      case 'google_search':
        return '🔍';
      case 'execute':
      case 'shell':
        return '💻';
      case 'think':
      case 'reasoning':
        return '🧠';
      default:
        return '🔧';
    }
  }

  /// Send message via SSE streaming (Gateway API Server).
  Future<void> _handleSlashCommand(String command) async {
    switch (command) {
      case '/new':
        _cmdNewChat();
        break;
      case '/model':
        await _cmdSwitchModel();
        break;
      case '/skills':
        await _cmdSkills();
        break;
    }
  }

  void _cmdNewChat() {
    final sessionId = GatewayChatClient.generateSessionId();
    final session = Session(
      id: sessionId,
      title: 'New Chat',
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    );
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(connection: widget.connection, session: session),
      ),
    );
  }

  Future<void> _cmdSkills() async {
    // SkillsScreen pops back the tapped skill's name (enabled skills only).
    // There's no client-callable "run this skill" endpoint — skills are
    // invoked by the agent's own skill_view/skill_load tool calls, not by a
    // slash command the API server understands (that expansion only exists
    // in gateway/run.py's platform-adapter dispatch, which api_server.py
    // doesn't go through). So this just seeds the composer with a prompt
    // that nudges the model to pull the skill in, rather than pretending to
    // invoke it directly.
    final selected = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => SkillsScreen(connection: widget.connection),
      ),
    );
    if (selected == null || !mounted) return;
    final prompt = 'Use the "$selected" skill: ';
    _textController.text = prompt;
    _textController.selection = TextSelection.collapsed(offset: prompt.length);
  }

  Future<void> _cmdSwitchModel() async {
    final dashboard = _dashboardClient();
    Map<String, dynamic> info;
    Map<String, dynamic> options;
    try {
      info = await dashboard.getModelInfo();
      options = await dashboard.getModelOptions();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not load models: $e')));
      return;
    }
    if (!mounted) return;

    final currentProvider = (info['provider'] as String?) ?? '';
    final currentModel = (info['model'] as String?) ?? '';
    final providers = (options['providers'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();

    final selection = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Switch model',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              for (final p in providers)
                ..._modelTiles(sheetContext, p, currentProvider, currentModel),
            ],
          ),
        );
      },
    );
    if (selection == null || !mounted) return;

    final (provider, model) = selection;
    try {
      await dashboard.setModel('main', provider, model);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Model set to $model — applies to new sessions'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not set model: $e')));
    }
  }

  List<Widget> _modelTiles(
    BuildContext sheetContext,
    Map<String, dynamic> provider,
    String currentProvider,
    String currentModel,
  ) {
    final providerId =
        (provider['slug'] as String?) ?? (provider['id'] as String?) ?? '';
    final rawModels = provider['models'] as List<dynamic>? ?? [];
    if (providerId.isEmpty || rawModels.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          providerId,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      for (final m in rawModels)
        if (m is String)
          ListTile(
            dense: true,
            title: Text(m),
            trailing: providerId == currentProvider && m == currentModel
                ? const Icon(Icons.check, size: 18)
                : null,
            onTap: () => Navigator.pop(sheetContext, (providerId, m)),
          ),
    ];
  }

  Future<void> _sendMessage({String? textOverride}) async {
    final text = (textOverride ?? _textController.text).trim();
    if (text.isEmpty) return;
    if (_sending || _streaming) return;

    if (textOverride == null &&
        _slashCommands.containsKey(text.toLowerCase())) {
      _textController.text = '';
      await _handleSlashCommand(text.toLowerCase());
      return;
    }

    // Keep the user's text in case send fails — the controller is cleared
    // below and without this the typed message is gone for good on error.
    if (textOverride == null) _textController.text = '';
    // Speak the reply whenever spoken replies are toggled on, regardless of
    // whether the message was typed or dictated.
    _awaitingVoiceReply = _voiceReplyEnabled;

    // No history is sent. sendMessageStreaming always sets
    // X-Hermes-Session-Id, and with a session id the gateway rebuilds the
    // conversation from its own DB and discards any client-supplied history
    // (see GatewayChatClient.buildChatCompletionMessages). Serializing the
    // whole transcript into every request body just to have the server throw
    // it away cost hundreds of KB of upload per turn on a long chat, delaying
    // the first token for nothing.

    // Keep the exact optimistic rows and attachment together so a failed
    // multimodal send can remove only its own UI rows and restore the draft.
    final pendingSend = PendingChatSend(
      text: text,
      imageBytes: _pickedImageBytes,
      imageMimeType: _pickedImageMimeType,
      imageDataUrl: _pickedImageDataUrl,
    );

    // Snapshot before the optimistic rows go in, so onError can tell a
    // genuinely-nothing-sent failure apart from a connection drop that the
    // gateway had already persisted a turn for (it interrupts-and-persists
    // rather than discarding — see _handleSendError).
    final baselineMessageCount = _messages.length;

    // Invalidate any in-flight late-media poll from the previous turn.
    _mediaPollGen++;
    _invalidateDisplayList();
    setState(() {
      _sending = true;
      _streaming = true;
      _showScrollToBottom = false;
      pendingSend.appendOptimisticRows(_messages);
      _pickedImageBytes = null;
      _pickedImageMimeType = null;
      _pickedImageDataUrl = null;
      _liveMediaUrls.clear();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    // Started here (not reactively on backgrounding) so there's no gap
    // between the app going to the background and the OS actually
    // protecting the process — see _backgroundServiceActive's doc comment.
    // Stopped in the finally below, whichever state the app is in by then.
    _backgroundServiceActive = true;
    startBackgroundSendService();

    // Accumulate tokens into the streaming placeholder
    _streamCancelToken = StreamCancelToken();
    try {
      await _gateway.sendMessageStreaming(
      message: text,
      sessionId: widget.session.id,
      imageDataUrls: pendingSend.imageDataUrls,
      cancelToken: _streamCancelToken,
      onToken: (token) {
        if (!mounted) return;
        _pendingTokens.write(token);
        _tokenFlushTimer ??= Timer(
          _flushDelayFor(_streamingContentLength),
          _flushPendingTokens,
        );
      },
      onToolProgress: (progress) {
        if (!mounted) return;
        _upsertToolProgress(progress);
      },
      onDone: () async {
        // Server-side history is about to replace _messages wholesale — drop
        // any buffered tokens instead of letting a stray delayed flush write
        // them onto the freshly fetched list.
        _tokenFlushTimer?.cancel();
        _tokenFlushTimer = null;
        _pendingTokens.clear();
        _streamCancelToken = null;
        if (!mounted) return;
        // Refresh messages to get the final server-side state
        try {
          final messages = await _client.getMessages(widget.session.id);
          if (!mounted) return;
          _extractToolMessages(messages);
          final settled = _mediaUrlsIn(messages);
          setState(() {
            _messages = messages;
            _streaming = false;
            _sending = false;
            _showScrollToBottom = false;
            // Drop only the URLs the refetched transcript actually carries, so
            // nothing renders twice. Anything whose tool-result row hasn't
            // been persisted yet stays put rather than blinking out and
            // reappearing a poll later — that flash is what _pollForLateMedia
            // used to paper over.
            _liveMediaUrls.removeWhere(settled.contains);
          });
          // The image tool's result row may land just after this refetch;
          // poll briefly so a freshly generated image doesn't require leaving
          // and reopening the chat to appear.
          _pollForLateMedia();
          // The foreground service (started unconditionally above, not only
          // when actually backgrounded) keeps the notification "Waiting for a
          // reply…" up throughout, then just dismisses it on completion --
          // nothing tells the user it's actually done if they weren't looking
          // at the screen. Only worth a notification if they in fact weren't.
          if (WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.resumed) {
            final lastAssistant = messages.reversed.firstWhere(
              (m) => m['role'] == 'assistant',
              orElse: () => const <String, dynamic>{},
            );
              final replyText = parseMessageContent(
                lastAssistant['content'],
              ).text.trim();
            if (replyText.isNotEmpty) {
              ReplyNotificationService.showReplyReady(
                widget.session.id,
                title: 'Hermes replied',
                preview: replyText.length > 200
                    ? '${replyText.substring(0, 200)}…'
                    : replyText,
              );
            }
          }
          if (_awaitingVoiceReply) {
            _awaitingVoiceReply = false;
            final assistant = messages.reversed.firstWhere(
              (message) => message['role'] == 'assistant',
              orElse: () => const <String, dynamic>{},
            );
            final assistantText = assistant['content']?.toString();
            if (assistantText != null) {
              await _speakAssistantText(
                assistantText,
                message: assistant.isEmpty ? null : assistant,
                  onComplete: _autoContinueEnabled
                      ? _scheduleAutoContinue
                      : null,
              );
            } else if (_autoContinueEnabled) {
              _scheduleAutoContinue();
            }
          } else if (_autoContinueEnabled) {
            // Voice reply is off, so there's no playback-finished signal to
            // wait on — just pace on a fixed delay instead.
            _scheduleAutoContinue();
          }
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _scrollToBottom(),
            );
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _streaming = false;
            _sending = false;
          });
        }
      },
      onError: (error) async {
        _tokenFlushTimer?.cancel();
        _tokenFlushTimer = null;
        _pendingTokens.clear();
        _streamCancelToken = null;
        if (!mounted) return;
        await _handleSendError(pendingSend, error, baselineMessageCount);
      },
      );
    } finally {
      // Always stop once the send completes — success, error, or cancel —
      // regardless of whether the app is foreground or background by then.
      if (_backgroundServiceActive) {
        _backgroundServiceActive = false;
        stopBackgroundSendService();
      }
    }
  }

  // Aborts the in-flight SSE connection. The gateway treats a dropped
  // connection the same as any other client disconnect: it interrupts the
  // agent and persists whatever was generated so far, so onDone's history
  // refetch picks up the partial reply — mirrors the Telegram adapter's
  // /stop command, which also just interrupts the running agent.
  //
  // Also the kill switch for auto-continue: hitting Stop ends the
  // automatic-reply loop, not just the in-flight response.
  void _stopStreaming() {
    _streamCancelToken?.cancel();
    _autoContinueTimer?.cancel();
    _autoContinueTimer = null;
    if (_autoContinueEnabled && mounted) {
      setState(() => _autoContinueEnabled = false);
    }
  }

  void _toggleAutoContinue() {
    setState(() => _autoContinueEnabled = !_autoContinueEnabled);
    if (!_autoContinueEnabled) {
      _autoContinueTimer?.cancel();
      _autoContinueTimer = null;
    }
  }

  /// Schedules the next automatic turn at a random interval (30s–3min),
  /// fired once the previous reply's audio has finished playing (or
  /// immediately-ish if voice reply is off). The continuation text is a
  /// fixed, neutral nudge — content is entirely whatever the user steered
  /// the conversation toward themselves.
  void _scheduleAutoContinue() {
    if (!_autoContinueEnabled || !mounted) return;
    _autoContinueTimer?.cancel();
    final delay = Duration(seconds: 30 + _autoContinueRandom.nextInt(151));
    _autoContinueTimer = Timer(delay, () {
      _autoContinueTimer = null;
      if (!_autoContinueEnabled || !mounted || _sending || _streaming) return;
      _sendMessage(textOverride: 'Continue.');
    });
  }

  /// Handles a failed/interrupted send. The gateway treats a dropped SSE
  /// connection (e.g. the OS suspending the socket when the app backgrounds)
  /// the same as any other client disconnect: it interrupts the agent but
  /// PERSISTS whatever was generated so far, rather than discarding it — see
  /// the comment on _stopStreaming. So a network-level onError does not mean
  /// nothing happened server-side; check before rolling back the optimistic
  /// rows, or a message that actually landed (fully or partially) would
  /// visually vanish and the user would re-type + re-send a duplicate.
  Future<void> _handleSendError(
    PendingChatSend pending,
    Object e,
    int baselineMessageCount,
  ) async {
    List<Map<String, dynamic>>? serverMessages;
    try {
      final fetched = await _client.getMessages(widget.session.id);
      if (fetched.length > baselineMessageCount) {
        serverMessages = fetched;
      }
    } catch (_) {
      // Refetch itself failed (e.g. still offline) — fall through to the
      // optimistic-rollback path below, same as before this fix existed.
    }

    if (!mounted) return;

    if (serverMessages != null) {
      // The gateway actually has a turn recorded for this send (complete or
      // interrupted-partial) — show it instead of pretending nothing was
      // sent. Mirrors onDone's success-path refetch, minus auto-continue/
      // voice-reply (an interrupted turn isn't a "reply finished" event).
      _extractToolMessages(serverMessages);
      final settled = _mediaUrlsIn(serverMessages);
      setState(() {
        _messages = serverMessages!;
        _sending = false;
        _streaming = false;
        _awaitingVoiceReply = false;
        // Same rule as onDone: keep anything the server hasn't persisted yet.
        _liveMediaUrls.removeWhere(settled.contains);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Connection dropped — reply was interrupted, but your message went through.',
              style: TextStyle(color: Colors.black87),
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: 'Continue',
              textColor: Colors.black87,
              onPressed: () {
                if (!_sending && !_streaming) {
                  _sendMessage(textOverride: 'Continue.');
                }
              },
            ),
          ),
        );
      }
      return;
    }

    _invalidateDisplayList();
    setState(() {
      _sending = false;
      _streaming = false;
      _awaitingVoiceReply = false;
      pending.rollbackOptimisticRows(_messages);
      _pickedImageBytes = pending.imageBytes;
      _pickedImageMimeType = pending.imageMimeType;
      // Reuse the already-encoded data URL rather than paying for the base64
      // again on the retry path.
      _pickedImageDataUrl = pending.imageDataUrls?.firstOrNull;
      // Restore the typed text so the user doesn't lose their message on a
      // transient failure. Put the cursor at the end of the restored text.
      _textController.text = pending.text;
      _textController.selection = TextSelection.collapsed(
        offset: pending.text.length,
      );
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Send failed: $e',
            style: const TextStyle(color: Colors.black87),
          ),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  void _upsertToolProgress(Map<String, dynamic> progress) {
    final toolCallId =
        progress['toolCallId']?.toString() ??
        progress['tool_call_id']?.toString() ??
        progress['id']?.toString() ??
        '';
    final tool = progress['tool']?.toString() ?? 'tool';
    final status = progress['status']?.toString() ?? 'running';
    final emoji = progress['emoji']?.toString() ?? '🔧';
    final label = progress['label']?.toString();
    final display = label == null || label.isEmpty ? tool : label;
    final done = status == 'completed' || status == 'finished';
    final content = done
        ? '$emoji $display — done'
        : '$emoji $display — $status';

    _invalidateDisplayList();
    setState(() {
      final idx = toolCallId.isEmpty
          ? -1
          : _toolMessages.indexWhere((m) => m['toolCallId'] == toolCallId);
      final payload = {
        'role': 'tool_progress',
        'content': content,
        'toolCallId': toolCallId,
        'status': status,
        'tool': tool,
      };
      if (idx >= 0) {
        _toolMessages[idx] = payload;
      } else {
        _toolMessages.add(payload);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    if (done && (tool == 'image_generate' || tool == 'video_generate')) {
      // Newer servers emit hermes.tool.progress with the rendered filename
      // directly in the SSE payload — render off that and skip polling.
      final filename = progress['filename']?.toString();
      if (filename != null && filename.isNotEmpty) {
        // Proof this gateway reports rendered filenames mid-stream, so the
        // read-after-write polling can stay switched off from here on.
        _rememberMediaFilenameCapability();
        final url = ComfyUi.viewUrl(_comfyBaseUrl, filename);
        if (!_liveMediaUrls.contains(url)) {
          _invalidateDisplayList();
          setState(() => _liveMediaUrls.add(url));
        }
        return;
      }
      // Fallback for older servers that don't include filename: poll briefly.
      _pollForLiveMedia();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _searching
          ? _buildSearchAppBar()
          : AppBar(
        title: Text(
          _characterName ?? widget.session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search this chat',
            onPressed: _toggleSearch,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'All chats',
            onPressed: _openSessionList,
          ),
          IconButton(
            icon: const Icon(Icons.face_retouching_natural),
            tooltip: 'Characters',
            onPressed: _streaming ? null : _pickCharacter,
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New chat',
            onPressed: _streaming ? null : _startNewChat,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) {
              switch (value) {
                case 'auto_continue':
                  _toggleAutoContinue();
                  break;
                case 'gallery':
                  _openGallery();
                  break;
                case 'call':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CallScreen(
                        connection: widget.connection,
                        session: widget.session,
                      ),
                    ),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'auto_continue',
                child: ListTile(
                  leading: Icon(
                    _autoContinueEnabled ? Icons.repeat_on : Icons.repeat,
                    color: _autoContinueEnabled
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: Text(
                          _autoContinueEnabled
                              ? 'Auto-continue on'
                              : 'Auto-continue',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'gallery',
                child: ListTile(
                  leading: Icon(Icons.photo_library_outlined),
                  title: Text('Image gallery'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'call',
                child: ListTile(
                  leading: Icon(Icons.call),
                  title: Text('Phone call mode'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          if (_streaming)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton.icon(
                onPressed: _stopStreaming,
                icon: const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                label: const Text('Stop', style: TextStyle(fontSize: 13)),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _fetchMessages,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: Stack(
        children: [
          if (_characterImagePath != null) _buildCharacterBackdrop(),
          _buildChatColumn(),
        ],
      ),
    );
  }

  /// The picked character's card art, behind the conversation. Only lightly
  /// veiled: the reply bubbles go transparent in a character chat, so the
  /// art is meant to be seen. Legibility comes from the text halos in
  /// _MessageBubble rather than from hiding the picture.
  Widget _buildCharacterBackdrop() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Positioned.fill(
      child: IgnorePointer(
        // The backdrop never changes while a reply streams, but it shares a
        // Stack with the chat column, so without this boundary every
        // token-flush setState repainted a full-screen image. The veil is a
        // plain overlay rather than a ColorFiltered wrapper for the same
        // reason: ColorFiltered forces an offscreen layer on every repaint,
        // and a flat translucent Container over the image is visually
        // identical here (srcOver of a solid colour is exactly that).
        child: RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CachedMediaThumbnail(
                url: _client.characterImageUrl(_characterImagePath!),
                mediaCache: _mediaCache,
                headers: _client.authHeaders,
                fit: BoxFit.cover,
                // Decode near screen width, not the card's native resolution —
                // these run to 6MB / ~25MB decoded.
                decodeWidth: MediaQuery.of(context).size.width.round(),
              ),
              Container(
                color: (isDark ? Colors.black : Colors.white).withValues(
                  alpha: 0.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatColumn() {
    return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: Responsive.isTablet(context) ? 800 : double.infinity,
          ),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    _buildBody(),
                    Positioned(
                      right: 16,
                      bottom: 12,
                      child: _buildScrollToBottomButton(),
                    ),
                  ],
                ),
              ),
              if (_speakingMessage != null) _buildSpeakingJumpBar(),
              if (_showingSlashSuggestions) _buildSlashSuggestions(),
              _buildInputBar(),
            ],
          ),
        ),
    );
  }

  /// Opens the image gallery. Long-pressing a tile there pops back with the
  /// message that produced it, which we then scroll to and flash — the
  /// gallery doubles as an index into the conversation, not just a lightbox.
  Future<void> _openGallery() async {
    final source = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaGalleryScreen(
          messages: _messages,
          comfyBaseUrl: _comfyBaseUrl,
          mediaCache: _mediaCache,
        ),
      ),
    );
    if (source == null || !mounted) return;
    await _jumpToMessage(source);
  }

  /// App bar replacement while searching: query field plus hit counter and
  /// prev/next stepping. Matches are flashed in place rather than shown in a
  /// separate results list, so you land in the conversation with its context
  /// around you instead of reading an excerpt out of context.
  PreferredSizeWidget _buildSearchAppBar() {
    final hits = _searchHits.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: 'Close search',
        onPressed: _toggleSearch,
      ),
      title: TextField(
        // Keyed so tests can target it unambiguously: the composer is also a
        // TextField, and Scaffold places body before appBar in its child list.
        key: searchFieldKey,
        controller: _searchController,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: 'Search this chat…',
          border: InputBorder.none,
        ),
        onChanged: _runSearch,
        onSubmitted: (_) => _stepSearch(-1),
      ),
      actions: [
        if (_searchQuery.isNotEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                hits == 0 ? 'none' : '${_searchCursor + 1}/$hits',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_up),
          tooltip: 'Previous match',
          onPressed: hits == 0 ? null : () => _stepSearch(-1),
        ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: 'Next match',
          onPressed: hits == 0 ? null : () => _stepSearch(1),
        ),
      ],
    );
  }

  /// Escape hatch back to the newest message, shown once the view is scrolled
  /// away from the bottom.
  ///
  /// Animated in and out rather than added and removed from the tree, so it
  /// doesn't pop in and out during the small scroll jitters around the
  /// threshold. IgnorePointer while hidden keeps it from eating taps aimed at
  /// the bubble underneath.
  Widget _buildScrollToBottomButton() {
    final visible = _showScrollToBottom;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 0.4),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: FloatingActionButton.small(
            heroTag: null,
            tooltip: 'Jump to latest',
            onPressed: _scrollToBottom,
            child: const Icon(Icons.arrow_downward, size: 20),
          ),
        ),
      ),
    );
  }

  /// Shown while a message is being replayed aloud: names it and offers to
  /// scroll back to it. Only the manual per-message replay sets
  /// [_speakingMessage] — an auto-spoken reply is the newest message and is
  /// already at the bottom of the view, so there is nothing to jump to.
  Widget _buildSpeakingJumpBar() {
    final speaking = _speakingMessage;
    if (speaking == null) return const SizedBox.shrink();
    final preview = parseMessageContent(
      speaking['content'],
    ).text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: _jumpToSpokenMessage,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.volume_up_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  preview.isEmpty ? 'Speaking…' : preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Jump to it',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlashSuggestions() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.surface,
      child: Wrap(
        spacing: 8,
        children: [
          for (final entry in _slashSuggestions())
            ActionChip(
              label: Text('${entry.key} — ${entry.value}'),
              onPressed: () async {
                _textController.text = '';
                await _handleSlashCommand(entry.key);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(blurRadius: 4, color: Colors.black.withValues(alpha: 0.1)),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_pickedImageBytes != null) _buildImagePreviewStrip(),
            Row(
          children: [
            IconButton(
              icon: const Icon(Icons.image_outlined),
              tooltip: 'Attach photo',
              onPressed: (!_loading && !_streaming && !_sending)
                  ? _pickImage
                  : null,
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: 'Type a message…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  isDense: true,
                ),
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.send,
                enabled: !_loading && !_streaming,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              icon: Icon(_listening ? Icons.mic_off : Icons.mic),
                  color: _listening
                      ? Theme.of(context).colorScheme.error
                      : null,
              onPressed: (!_loading && !_streaming && !_sending)
                  ? _toggleVoiceInput
                  : null,
              tooltip: _listening ? 'Stop listening' : 'Speak to Hermes',
            ),
            IconButton(
              icon: Icon(
                _voiceReplyEnabled ? Icons.volume_up : Icons.volume_off,
              ),
              onPressed: () {
                setState(() => _voiceReplyEnabled = !_voiceReplyEnabled);
                if (!_voiceReplyEnabled) {
                  _xtts.stop();
                }
              },
              tooltip: _voiceReplyEnabled
                  ? 'Spoken replies on'
                  : 'Spoken replies off',
            ),
            const SizedBox(width: 4),
            CircleAvatar(
              child: _streaming
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.send, size: 20),
                      onPressed: _sendMessage,
                      tooltip: 'Send',
                    ),
            ),
          ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePreviewStrip() {
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              _pickedImageBytes!,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 8),
          const Text('Photo attached', style: TextStyle(fontSize: 12)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Remove photo',
            onPressed: () => setState(() {
              _pickedImageBytes = null;
              _pickedImageMimeType = null;
              _pickedImageDataUrl = null;
            }),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage() async {
    final file = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2000,
      imageQuality: 85,
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    // The platform picker usually already knows the real MIME type; only
    // guess from the extension when it doesn't say.
    final platformMime = file.mimeType;
    final mime = (platformMime != null && platformMime.isNotEmpty)
        ? platformMime
        : switch (file.name.split('.').last.toLowerCase()) {
            'png' => 'image/png',
            'webp' => 'image/webp',
            'gif' => 'image/gif',
            _ => 'image/jpeg',
          };
    // Encode here, on the async pick path, not in _sendMessage — see
    // buildImageDataUrl.
    final dataUrl = await Isolate.run(() => buildImageDataUrl(bytes, mime));
    if (!mounted) return;
    setState(() {
      _pickedImageBytes = bytes;
      _pickedImageMimeType = mime;
      _pickedImageDataUrl = dataUrl;
    });
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Only the "nothing to show" case gets the full-screen error+Retry —
    // a refresh failure with an already-loaded conversation surfaces via
    // SnackBar instead (see _fetchMessages) so the conversation stays
    // visible underneath rather than being replaced by an error screen.
    if (_error != null && _messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                'Failed to load messages',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _fetchMessages,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final display = _displayList();

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: display.rows.length,
      // Load-bearing alongside the keys below, not an optimization. In a lazy
      // list a keyed child that moved index is discarded and rebuilt unless
      // the sliver can locate it — so keys WITHOUT this are worse than no keys
      // at all. Proven both ways in test/list_element_reuse_test.dart.
      findChildIndexCallback: (key) => display.indexByKey[key],
      itemBuilder: (context, index) {
        final item = display.rows[index];
        final key = display.keys[index];

        final Widget child;
        if (item is List<Map<String, dynamic>>) {
          child = _ToolProgressCard(items: item, verbose: _verboseMode);
        } else if (item is List<String>) {
          // Generated media (images/videos) extracted from tool results.
          child = _MediaRow(
            urls: item,
            mediaCache: _mediaCache,
            mediaExport: _mediaExport,
          );
        } else {
          final msg = item as Map<String, dynamic>;
          final role = (msg['role'] as String?) ?? 'assistant';
          final parsed = parseMessageContent(msg['content']);
          final isUser = role == 'user';

          child = _MessageBubble(
            content: parsed.text,
            imageUrls: parsed.imageUrls,
            mediaCache: _mediaCache,
            isUser: isUser,
            verbose: _verboseMode,
            metadata: msg,
            isSpeaking: _isSpeakingMessage(msg),
            onReplay: isUser ? null : () => _replayMessage(msg),
            onEdit: isUser ? () => _editAndResend(msg) : null,
            // Only the LAST assistant message -- see _MessageBubble.onRegenerate.
            onRegenerate:
                !isUser &&
                    _messages.isNotEmpty &&
                    identical(msg, _messages.last)
                ? _regenerateLastReply
                : null,
            // In a character chat the reply sits directly on the card art:
            // no bubble fill, dialogue in yellow, *narration* in bold black.
            roleplay: _characterImagePath != null,
          );
        }

        // The row key goes on a KeyedSubtree rather than on the row widget
        // itself, so the jump target can be wrapped without displacing the
        // key the sliver matches on.
        return KeyedSubtree(
          key: key,
          child: key == _flashRowKey
              ? _FlashHighlight(
                  key: _flashAnchorKey,
                  flashId: _flashId,
                  child: child,
                )
              : child,
        );
      },
    );
  }

  // ── Jump to the message being spoken ────────────────────────────────
  //
  // Tapping replay on an old message and then scrolling away leaves no way
  // back to it short of hunting. These track the jump target so it can be
  // located and flashed once it is on screen.
  Key? _flashRowKey;
  int _flashId = 0;
  final GlobalKey _flashAnchorKey = GlobalKey();

  Future<void> _jumpToSpokenMessage() =>
      _jumpToRow((row) => _isSpeakingMessage(row));

  /// Scrolls to the first message row matching [matches] and flashes it.
  ///
  /// The target can legitimately be absent — a refetch may have replaced the
  /// transcript since whatever pointed at it was captured — so a miss is a
  /// no-op rather than an error.
  Future<void> _jumpToRow(
    bool Function(Map<String, dynamic> row) matches,
  ) async {
    final display = _displayList();
    var index = -1;
    for (var i = 0; i < display.rows.length; i++) {
      final row = display.rows[i];
      if (row is Map<String, dynamic> && matches(row)) {
        index = i;
        break;
      }
    }
    if (index < 0) return;

    setState(() {
      _flashRowKey = display.keys[index];
      _flashId++;
    });
    await _revealRow(index);
  }

  /// Jump to a specific message, e.g. the one that produced an image the user
  /// tapped in the gallery. Matched by identity first, falling back to
  /// role+text so it still resolves across a refetch that rebuilt the maps.
  Future<void> _jumpToMessage(Map<String, dynamic> target) {
    final targetText = parseMessageContent(target['content']).text;
    final targetRole = target['role'] as String?;
    return _jumpToRow((row) {
      if (identical(row, target)) return true;
      return (row['role'] as String?) == targetRole &&
          parseMessageContent(row['content']).text == targetText;
    });
  }

  // ── In-chat search ──────────────────────────────────────────────────
  bool _searching = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  /// Display-row indices matching the current query, in transcript order.
  List<int> _searchHits = const [];
  int _searchCursor = 0;

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchController.clear();
        _searchQuery = '';
        _searchHits = const [];
        _searchCursor = 0;
        _flashRowKey = null;
      }
    });
  }

  void _runSearch(String query) {
    final q = query.trim().toLowerCase();
    final hits = <int>[];
    if (q.isNotEmpty) {
      final rows = _displayList().rows;
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        if (row is! Map<String, dynamic>) continue;
        final text = parseMessageContent(row['content']).text;
        if (text.toLowerCase().contains(q)) hits.add(i);
      }
    }
    setState(() {
      _searchQuery = q;
      _searchHits = hits;
      // Land on the most recent match: in a long roleplay the thing you are
      // looking for is far more often the last time it came up than the first.
      _searchCursor = hits.isEmpty ? 0 : hits.length - 1;
    });
    if (hits.isNotEmpty) _revealSearchHit();
  }

  void _stepSearch(int delta) {
    if (_searchHits.isEmpty) return;
    setState(() {
      _searchCursor = (_searchCursor + delta) % _searchHits.length;
      if (_searchCursor < 0) _searchCursor += _searchHits.length;
    });
    _revealSearchHit();
  }

  Future<void> _revealSearchHit() async {
    if (_searchHits.isEmpty) return;
    final index = _searchHits[_searchCursor];
    final display = _displayList();
    if (index >= display.rows.length) return;
    setState(() {
      _flashRowKey = display.keys[index];
      _flashId++;
    });
    await _revealRow(index);
  }

  /// Scrolls [index] into view — see [revealRow] for why this needs more than
  /// one pass. `alignment` puts the message a little below the top edge so it
  /// reads as "here" rather than being jammed under the app bar.
  Future<void> _revealRow(int index) => revealRow(
    controller: _scrollController,
    index: index,
    rowCount: () => _displayList().rows.length,
    anchorContext: () => _flashAnchorKey.currentContext,
    isMounted: () => mounted,
  );

  // ── Display list ────────────────────────────────────────────────────
  //
  // Deriving the rendered row list walks the ENTIRE transcript: every
  // message parsed, tool groups assembled, media URLs harvested and deduped,
  // and a pile of fresh Lists/Sets allocated. That ran on every rebuild —
  // which during a streaming reply means several times a second (see
  // _flushPendingTokens) — to produce a list identical to the previous one
  // except for the final bubble's text. On a long session that was thousands
  // of message-visits per second and a steady stream of garbage.
  //
  // The result is cached and reused until one of its inputs actually changes.
  // Token flushes deliberately do NOT invalidate it: the cached list holds
  // references to the same message maps, so a mutated `content` is picked up
  // for free by the bubble that renders it.
  _DisplayRows? _displayCache;
  ({
    int revision,
    int messageCount,
    int toolCount,
    int liveMediaCount,
    String comfyBaseUrl,
    bool lastMessageEmpty,
  })?
  _displayCacheKey;

  /// Bumped by [_invalidateDisplayList] whenever _messages, _toolMessages,
  /// _liveMediaUrls or _comfyBaseUrl are mutated in a way the row list depends
  /// on. Anything that touches those must call it.
  int _displayRevision = 0;

  void _invalidateDisplayList() => _displayRevision++;

  /// The optimistic assistant row starts empty and is therefore skipped by the
  /// builder below; it has to appear the moment the first token lands. That is
  /// the one content mutation the cache must notice, so it is part of the key.
  bool get _lastMessageEmpty {
    if (_messages.isEmpty) return false;
    final content = _messages.last['content'];
    return content is String && content.isEmpty;
  }

  _DisplayRows _displayList() {
    final key = (
      revision: _displayRevision,
      messageCount: _messages.length,
      toolCount: _toolMessages.length,
      liveMediaCount: _liveMediaUrls.length,
      comfyBaseUrl: _comfyBaseUrl,
      lastMessageEmpty: _lastMessageEmpty,
    );
    final cached = _displayCache;
    if (cached != null && key == _displayCacheKey) return cached;
    final built = _keyRows(_buildDisplayList());
    _displayCache = built;
    _displayCacheKey = key;
    return built;
  }

  /// The assistant reply currently being streamed into, if any — it gets a
  /// sentinel key rather than a content-derived one. See [messageRowKey].
  Map<String, dynamic>? get _streamingTailMessage {
    if (!_streaming || _messages.isEmpty) return null;
    final last = _messages.last;
    return (last['role'] as String?) == 'assistant' ? last : null;
  }

  /// Attaches a stable, unique key to each row and builds the key→index map
  /// that findChildIndexCallback needs.
  _DisplayRows _keyRows(List<dynamic> rows) {
    final keys = <Key>[];
    final indexByKey = <Key, int>{};
    final seen = <String, int>{};
    final streamingTail = _streamingTailMessage;

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final String base;
      if (row is List<Map<String, dynamic>>) {
        base = toolRowKey(
          row.isEmpty ? null : row.first['toolCallId']?.toString(),
        );
      } else if (row is List<String>) {
        base = mediaRowKey(row.isEmpty ? null : row.first);
      } else {
        final msg = row as Map<String, dynamic>;
        base = messageRowKey(
          role: (msg['role'] as String?) ?? 'assistant',
          text: parseMessageContent(msg['content']).text,
          id: msg['id']?.toString(),
          streaming: streamingTail != null && identical(msg, streamingTail),
        );
      }
      final key = ValueKey(disambiguate(base, seen));
      keys.add(key);
      indexByKey[key] = i;
    }
    return _DisplayRows(rows, keys, indexByKey);
  }

  /// Build display list: consecutive tool messages grouped into cards,
  /// interleaved with user/assistant bubbles. Images rendered by the ComfyUI
  /// tool are detected by filename in the tool content and shown inline.
  List<dynamic> _buildDisplayList() {
    final toolQueue = List<Map<String, dynamic>>.from(_toolMessages);
    final displayMessages = <dynamic>[];
    final currentGroup = <Map<String, dynamic>>[];
    final groupImages = <String>{};
    // Every URL already placed into displayMessages, across every group and
    // turn in this session — not just the current group. A later tool result
    // (e.g. a post-render `os.listdir()` verification call, or a duplicate
    // filename mention) can reference a file whose image already rendered
    // earlier in the transcript; without this the same picture reappears as
    // a brand-new row every time its filename resurfaces in tool content.
    final seenImages = <String>{};

    for (final msg in _messages) {
      final role = (msg['role'] as String?) ?? 'assistant';
      if (role == 'tool') {
        // Harvest generated-image filenames from the raw tool content
        // (memoized per message — see _mediaNamesIn).
        for (final name in _mediaNamesIn(msg)) {
          final url = ComfyUi.viewUrl(_comfyBaseUrl, name);
          if (seenImages.add(url)) groupImages.add(url);
        }
        if (toolQueue.isNotEmpty) {
          currentGroup.add(toolQueue.removeAt(0));
        }
        continue;
      }
      if (role != 'user' && role != 'assistant') continue;
      final parsed = parseMessageContent(msg['content']);
      if (parsed.text.isEmpty && parsed.imageUrls.isEmpty) continue;
      // Hide the character-persona turn: the model needs those ~10k chars,
      // the reader doesn't want a wall of card prose as the first bubble.
      if (role == 'user' && parsed.text.startsWith(CharacterCard.setupMarker)) {
        continue;
      }

      if (currentGroup.isNotEmpty) {
        displayMessages.add(currentGroup.toList());
        currentGroup.clear();
      }
      if (groupImages.isNotEmpty) {
        displayMessages.add(groupImages.toList());
        groupImages.clear();
      }
      displayMessages.add(msg);
    }
    if (currentGroup.isNotEmpty) {
      displayMessages.add(currentGroup.toList());
    }
    if (groupImages.isNotEmpty) {
      displayMessages.add(groupImages.toList());
    }

    // Tools from SSE events that arrived during streaming but haven't been
    // matched to server messages yet — show them as a card.
    if (toolQueue.isNotEmpty) {
      displayMessages.add(toolQueue.toList());
    }

    // A generated image that landed mid-stream, before the turn's final
    // getMessages() refetch — see _pollForLiveMedia. Not gated on _streaming:
    // onDone keeps any entry the refetch hasn't caught up with, and dropping
    // the row the instant the turn ended is exactly the flash-out that made
    // the late-media polling necessary.
    if (_liveMediaUrls.isNotEmpty) {
      displayMessages.add(_liveMediaUrls.toList());
    }

    return displayMessages;
  }
}

/// Tints a row briefly, then fades back, to mark where a jump landed.
///
/// Driven by [flashId] rather than by mounting: the target row's element
/// survives repeated jumps to the same message, so a mount-triggered
/// animation would only ever play once.
class _FlashHighlight extends StatefulWidget {
  const _FlashHighlight({
    required this.flashId,
    required this.child,
    super.key,
  });

  final int flashId;
  final Widget child;

  @override
  State<_FlashHighlight> createState() => _FlashHighlightState();
}

class _FlashHighlightState extends State<_FlashHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  late final Animation<double> _opacity = TweenSequence<double>([
    // Rise quickly so the eye catches it, linger, then fade out slowly.
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 15),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 35),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 50),
  ]).animate(_controller);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didUpdateWidget(_FlashHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flashId != widget.flashId) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        // Ignores pointers so the replay button underneath stays tappable
        // while the flash plays.
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: _opacity,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFD4AF37).withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The transcript's rows plus their stable keys and a key→index map.
///
/// Keys and rows are built and cached together: recomputing keys on every
/// rebuild would undo the point of caching the rows.
class _DisplayRows {
  const _DisplayRows(this.rows, this.keys, this.indexByKey);

  final List<dynamic> rows;
  final List<Key> keys;
  final Map<Key, int> indexByKey;
}

/// Content of the "Edit & resend" dialog. Owns its TextEditingController as
/// a StatefulWidget rather than the caller creating and disposing one
/// around showDialog(): a dialog Route doesn't leave the tree the instant
/// its Navigator.pop() call returns -- it's still mounted through its exit
/// transition -- so disposing a controller right after that await produced
/// "A TextEditingController was used after being disposed." Owning it here
/// means the framework disposes it at the correct point in the Element's
/// own lifecycle instead of the caller guessing at the timing.
class _EditMessageDialog extends StatefulWidget {
  final String initialText;
  const _EditMessageDialog({required this.initialText});

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit & resend'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: null,
        decoration: const InputDecoration(
          hintText: 'Message text',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Send'),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final List<String> imageUrls;
  final MediaCachePort mediaCache;
  final bool isUser;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final bool isSpeaking;
  final VoidCallback? onReplay;

  /// User messages only. Opens an edit dialog pre-filled with this message's
  /// text; confirming sends it as a brand-new message rather than replacing
  /// this one -- the gateway has no endpoint to delete or truncate persisted
  /// history (only an append-only /chat and a whole-history-copying /fork),
  /// so a true in-place edit isn't possible without a gateway change.
  final VoidCallback? onEdit;

  /// Assistant messages only, and only wired at the call site for the LAST
  /// message in the transcript (regenerating an older reply would append a
  /// new one at the bottom, nowhere near the message that triggered it,
  /// which reads as broken rather than as a regeneration). Re-sends the
  /// preceding user turn as a new message for the same reason onEdit does.
  final VoidCallback? onRegenerate;

  /// Character-chat styling: the assistant's reply drops its bubble fill so
  /// the card art shows through, with dialogue in yellow and *narration* in
  /// bold black. User messages keep their normal bubble either way.
  final bool roleplay;

  const _MessageBubble({
    required this.content,
    this.imageUrls = const [],
    required this.mediaCache,
    required this.isUser,
    this.verbose = false,
    this.metadata = const {},
    this.isSpeaking = false,
    this.onReplay,
    this.onEdit,
    this.onRegenerate,
    this.roleplay = false,
  });

  /// Bright yellow — spoken dialogue.
  static const Color _rpDialogue = Color(0xFFFFEB3B);

  /// Bold white — narration and actions, i.e. *asterisk* spans, which the
  /// markdown renderer surfaces as emphasis. White rather than black: the
  /// bubble has to stay dark for the yellow dialogue to read, and black ink
  /// on a dark bubble is invisible.
  static const Color _rpNarration = Color(0xFFFFFFFF);

  /// Same idea for the yellow: a dark rim so it holds up over light art.
  static const List<Shadow> _rpDialogueHalo = [
    Shadow(color: Color(0xCC000000), blurRadius: 3),
    Shadow(color: Color(0x99000000), blurRadius: 6),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Bubble colors. A character reply keeps a bubble — going fully
    // transparent over the card art made replies unreadable — but uses a
    // translucent dark scrim so the picture still reads behind the text.
    final rp = roleplay && !isUser;
    final userBubbleColor = const Color(0xFFD4AF37);
    final assistantBubbleColor = rp
        ? const Color(0xFF141414).withValues(alpha: 0.82)
        : (isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA));
    final assistantTextColor = rp
        ? _rpDialogue
        : (isDark ? Colors.white : Colors.black87);
    // White text on this gold measures ~2.1:1 contrast — well under WCAG AA's
    // 4.5:1 minimum for normal text. Dark text on the same gold comfortably
    // clears it, so every isUser text color below uses this instead of white.
    final userTextColor = Colors.black87;

    // Collect extra metadata for verbose mode
    final List<String> metaLines = [];
    if (verbose) {
      final role = (metadata['role'] as String?) ?? 'unknown';
      metaLines.add('role: $role');
      // Show any extra fields that aren't role/content
      for (final entry in metadata.entries) {
        if (entry.key == 'role' || entry.key == 'content') continue;
        final value = entry.value?.toString() ?? 'null';
        if (value.length > 80) {
          metaLines.add('${entry.key}: ${value.substring(0, 80)}…');
        } else {
          metaLines.add('${entry.key}: $value');
        }
      }
    }

    final bubble = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width - 80,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isUser ? userBubbleColor : assistantBubbleColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Verbose metadata header
          if (metaLines.isNotEmpty) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (isUser ? Colors.white : Colors.black).withValues(
                  alpha: 0.1,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: metaLines
                    .map(
                      (line) => Text(
                        line,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: isUser
                              ? userTextColor.withValues(alpha: 0.8)
                              : (isDark ? Colors.grey[400] : Colors.grey[600]),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          if (imageUrls.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: content.isEmpty ? 0 : 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: imageUrls
                    .map(
                      (url) => SizedBox(
                        width: 140,
                        height: 140,
                        child: CachedMediaThumbnail(
                          url: url,
                          mediaCache: mediaCache,
                          borderRadius: 12,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          // Message content
          if (content.isNotEmpty)
            MarkdownBody(
              data: content,
            styleSheet: MarkdownStyleSheet(
              p: (isUser
                  ? theme.textTheme.bodyMedium?.copyWith(color: userTextColor)
                  : theme.textTheme.bodyMedium?.copyWith(
                      color: assistantTextColor,
                      shadows: rp ? _rpDialogueHalo : null,
                    )),
              code: TextStyle(
                backgroundColor: Colors.black.withValues(alpha: 0.12),
                fontFamily: 'monospace',
                color: isUser ? userTextColor : null,
              ),
              a: TextStyle(
                color: isUser ? Colors.blue[900] : theme.colorScheme.primary,
              ),
              h1: isUser
                    ? theme.textTheme.headlineSmall?.copyWith(
                        color: userTextColor,
                      )
                  : theme.textTheme.headlineSmall,
              h2: isUser
                  ? theme.textTheme.titleLarge?.copyWith(color: userTextColor)
                  : theme.textTheme.titleLarge,
              h3: isUser
                    ? theme.textTheme.titleMedium?.copyWith(
                        color: userTextColor,
                      )
                  : theme.textTheme.titleMedium,
              blockquote: TextStyle(
                  color: isUser
                      ? userTextColor.withValues(alpha: 0.7)
                      : Colors.grey,
                fontStyle: FontStyle.italic,
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isUser
                        ? userTextColor.withValues(alpha: 0.4)
                        : theme.colorScheme.primary,
                    width: 3,
                  ),
                ),
              ),
              // *asterisks* — narration and actions. The markdown renderer
              // surfaces them as emphasis, which is what makes roleplay
              // styling possible without a custom parser.
              em: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: userTextColor,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: rp ? FontStyle.normal : FontStyle.italic,
                      fontWeight: rp ? FontWeight.bold : null,
                      color: rp ? _rpNarration : null,
                    ),
              strong: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: userTextColor,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: rp ? _rpNarration : null,
                    ),
            ),
          ),
          // Per-message actions: TTS replay + regenerate (assistant only),
          // edit & resend (user only).
          if (onReplay != null || onRegenerate != null || onEdit != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: isUser
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isUser && onReplay != null)
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        icon: Icon(
                          isSpeaking
                              ? Icons.stop_rounded
                              : Icons.volume_up_rounded,
                        ),
                        tooltip: isSpeaking ? 'Stop' : 'Replay',
                        color: isDark ? Colors.white54 : Colors.black45,
                        onPressed: onReplay,
                      ),
                    if (!isUser && onRegenerate != null)
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        icon: const Icon(Icons.refresh_rounded),
                        tooltip: 'Ask again (sends as a new message)',
                        color: isDark ? Colors.white54 : Colors.black45,
                        onPressed: onRegenerate,
                      ),
                    if (isUser && onEdit != null)
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: 'Edit & resend as a new message',
                        color: userTextColor.withValues(alpha: 0.6),
                        onPressed: onEdit,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    return Row(
      mainAxisAlignment: isUser
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [bubble],
    );
  }
}

class _ToolProgressCard extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final bool verbose;

  const _ToolProgressCard({required this.items, this.verbose = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final fg = isDark ? Colors.white70 : Colors.black54;

    final active = items.any((item) {
      final status = (item['status'] as String?) ?? '';
      return status != 'completed' && status != 'finished';
    });

    final emojis = items.map((item) {
      final content = (item['content'] as String?) ?? '';
      return content.isNotEmpty
          ? content.substring(0, content.length < 2 ? content.length : 2)
          : '\uD83D\uDD27';
    }).toList();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width - 80,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Text(
            active ? '\u23F3' : '\u2705',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(width: 6),
          Text(emojis.join(' '), style: const TextStyle(fontSize: 13)),
          if (active)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: fg),
              ),
            ),
        ],
      ),
    );
  }
}

// Attached-image rendering moved to the shared CachedMediaThumbnail widget
// (see ../widgets/cached_media_thumbnail.dart) — this used to be its own
// near-identical copy of the gallery's tile widget.

/// A column of generated media (images and/or videos) from tool results.
class _MediaRow extends StatelessWidget {
  final List<String> urls;
  final MediaCachePort mediaCache;
  final MediaExportService mediaExport;
  const _MediaRow({
    required this.urls,
    required this.mediaCache,
    required this.mediaExport,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      // Keyed on the URL. Unlike the transcript's lazy ListView — where a key
      // without findChildIndexCallback makes a moved child get discarded and
      // rebuilt rather than reused — a Column builds all its children eagerly,
      // so keys here genuinely let a clip keep its opened Player when the
      // row's contents shift around it.
      children: urls.map((u) {
        final filename = Uri.parse(u).queryParameters['filename'] ?? '';
        return ComfyUi.isVideo(filename)
            ? _VideoBubble(url: u, mediaExport: mediaExport, key: ValueKey(u))
            : _ImageBubble(
                url: u,
                mediaCache: mediaCache,
                mediaExport: mediaExport,
                key: ValueKey(u),
              );
      }).toList(),
    );
  }
}

/// Share / save-to-gallery bottom sheet for a generated media bubble.
/// Exports [url] remotely so sharing and saving use bounded downloads.
Future<void> _showMediaActions(
  BuildContext context,
  String url, {
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
    final uri = Uri.parse(url);
    Future<bool> confirm(MediaDownloadInfo info) =>
        _confirmMediaDownload(context, info);

    if (action == 'share') {
      await mediaExport.shareRemote(uri, confirmAfterHeaders: confirm);
      if (!context.mounted) return;
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
          child: const Text('Download'),
        ),
      ],
    ),
  );
  if (!context.mounted) return false;
  return accepted ?? false;
}

/// Small overlay button for [_showMediaActions], shared by _ImageBubble and
/// _VideoBubble so the two don't each style their own.
class _MediaActionButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _MediaActionButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: const Padding(
          padding: EdgeInsets.all(6),
          child: Icon(Icons.more_vert, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}

/// One generated image, resolved through [MediaCacheService] so a reopened
/// chat reads it off disk instead of re-fetching it from the LAN gateway
/// every time. Tappable to open full-screen with pinch-zoom.
///
/// This used to be a bare Image.network with no disk cache and no decode
/// bound — every reopen re-downloaded the file, and a 1536² PNG decoded to
/// ~9MB of bitmap, so a handful of them evicted Flutter's ImageCache and sent
/// the whole transcript into repeated decode churn while scrolling.
class _ImageBubble extends StatefulWidget {
  final String url;
  final MediaCachePort mediaCache;
  final MediaExportService mediaExport;
  const _ImageBubble({
    required this.url,
    required this.mediaCache,
    required this.mediaExport,
    super.key,
  });

  @override
  State<_ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<_ImageBubble> {
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
  void didUpdateWidget(_ImageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        !identical(oldWidget.mediaCache, widget.mediaCache)) {
      _resolve();
    }
  }

  void _resolve() {
    _fileFuture = widget.mediaCache.cache(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxW = media.size.width - 80;
    // cacheWidth is in physical pixels, so scale by DPR — decoding at the
    // logical width would look soft on any modern phone.
    final decodeWidth = (maxW * media.devicePixelRatio).round();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      constraints: BoxConstraints(maxWidth: maxW),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: FutureBuilder<File?>(
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
                  cacheWidth: decodeWidth,
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
                child: _MediaActionButton(
                  onPressed: () => _showMediaActions(
                    context,
                    widget.url,
                    isVideo: false,
                    mediaExport: widget.mediaExport,
                  ),
                ),
              ),
            ],
          );
        },
      ),
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

/// One generated video, streamed from ComfyUI's /view endpoint. Tap toggles
/// play/pause; initialized paused so clips don't all autoplay at once.
///
/// Backed by media_kit (libmp/FFmpeg): it software-decodes codecs Android's
/// hardware MediaCodec path rejects — HEVC/H.265, VP9, AV1, 10-bit
/// (yuv420p10le), and mkv/webm containers — which the previous ExoPlayer-based
/// video_player failed to initialize on, showing "video unavailable" for many
/// ComfyUI/WAN clips.
class _VideoBubble extends StatefulWidget {
  final String url;
  final MediaExportService mediaExport;
  const _VideoBubble({required this.url, required this.mediaExport, super.key});

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

/// Loads media_kit's native backend on first use.
///
/// This used to run unconditionally in main(), putting the shared-object load
/// in front of the first frame on every cold start — including the majority of
/// launches that never open a chat with a video in it. MediaKit.ensureInitialized
/// is itself idempotent; the flag just avoids the repeat call per bubble.
bool _mediaKitReady = false;
void ensureMediaKitInitialized() {
  if (_mediaKitReady) return;
  MediaKit.ensureInitialized();
  _mediaKitReady = true;
}

/// media_kit hardcodes `cache-on-disk: yes` for every Player (see
/// media_kit's native player real.dart) but never sets `cache-dir`, so on
/// Android mpv has nowhere to put its demuxer cache file and logs
///   lavf error: Failed to create file cache.
/// on every open, silently falling back to memory-only buffering -- fine for
/// short generated clips, but needlessly holds more in memory than intended
/// for longer ones. getTemporaryDirectory() is async but the path is fixed
/// for the life of the process, so fetch it once and reuse it.
Future<String>? _mpvCacheDirFuture;
Future<String> _mpvCacheDir() =>
    _mpvCacheDirFuture ??= getTemporaryDirectory().then((d) => d.path);

class _VideoBubbleState extends State<_VideoBubble> {
  // Both are assigned in initState, in this order, BEFORE the first _openSource().
  //
  // media_kit starts every Player with `--vid=no` ("to prevent redundant video
  // decoding"); attaching a VideoController is what flips it to `--vid=auto`.
  // These were previously `late final` field initializers, so the controller
  // was not constructed until build() first read it -- which only happens once
  // _ready is true, i.e. AFTER _player.open() had already run. Every clip was
  // therefore opened with video decoding switched off, and since generated
  // ComfyUI/WAN clips carry no audio track either, mpv selected no tracks at
  // all ("No video or audio streams selected"), leaving width/height null and
  // the bubble permanently black behind its play button.
  Player? _player;
  VideoController? _videoController;
  bool _ready = false;
  bool _failed = false;
  bool _playing = false;
  double _aspect = 16 / 9;

  final List<StreamSubscription<dynamic>> _subs = [];

  /// Bumped on every [_openSource]. An open that resolves after a newer one
  /// started must not flip this bubble to ready/failed for a clip that is no
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
    // Surface real decode/open failures instead of silently spinning forever.
    _subs.add(
      player.stream.error.listen((e) {
      debugPrint('[media_kit] video error for ${widget.url}: $e');
      if (mounted) setState(() => _failed = true);
      }),
    );
    _subs.add(
      player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
      }),
    );
    _subs.add(player.stream.width.listen((_) => _updateAspect()));
    _subs.add(player.stream.height.listen((_) => _updateAspect()));
    _openSource();
  }

  /// The transcript's row list is rebuilt from scratch on every refetch, and
  /// rows shift whenever a tool group or media row is inserted between
  /// bubbles. Because rows are unkeyed, Flutter matches by index and UPDATES
  /// this element rather than recreating it — so without this the State kept
  /// its already-opened Player and went on playing the previous clip under a
  /// row that now points at a different URL.
  @override
  void didUpdateWidget(_VideoBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _openSource();
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
      // Open paused so multiple clips in a transcript don't all autoplay.
      await player.open(Media(widget.url), play: false);
      if (!mounted || epoch != _openEpoch) return;
      setState(() => _ready = true);
    } catch (e) {
      debugPrint('[media_kit] open failed for ${widget.url}: $e');
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
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width - 80;
    final player = _player;
    final videoController = _videoController;
    Widget body;
    if (_failed || player == null || videoController == null) {
      body = const SizedBox(
        height: 100,
        child: Center(
          child: Text(
            'video unavailable',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    } else if (!_ready) {
      body = const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    } else {
      body = GestureDetector(
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
            // progress bar
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
                onPressed: () => _showMediaActions(
                  context,
                  widget.url,
                  isVideo: true,
                  mediaExport: widget.mediaExport,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      constraints: BoxConstraints(maxWidth: maxW),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.black,
      ),
      child: body,
    );
  }
}

/// Thin scrubbable progress bar for [_VideoBubble], mirroring the look of the
/// old VideoProgressIndicator (played/buffered/background tint) since
/// media_kit_video's default controls are replaced with [NoVideoControls].
class _VideoProgressBar extends StatelessWidget {
  final Player player;
  const _VideoProgressBar({required this.player});

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
