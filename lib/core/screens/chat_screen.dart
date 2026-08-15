// Chat screen with real-time streaming via REST API.
// Uses REST endpoints: POST /api/sessions/{id}/chat and
// GET /api/sessions/{id}/messages.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../models/pending_chat_send.dart';
import '../services/speech_recognition_coordinator.dart';

import '../services/background_activity_service.dart';
import '../services/connection_manager.dart';
import '../services/comfyui.dart';
import '../services/tts_provider.dart';
import '../services/xtts_service.dart';
import '../utils/responsive.dart';
import 'call_screen.dart';
import 'media_gallery_screen.dart';
import 'skills_screen.dart';

class ChatScreen extends StatefulWidget {
  final SavedConnection connection;
  final Session session;

  const ChatScreen({
    required this.connection,
    required this.session,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
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
  // Only started when the app is backgrounded mid-generation (see
  // didChangeAppLifecycleState) — not on every send — so a normal
  // foreground send never shows the notification.
  bool _backgroundServiceActive = false;

  // Image attach (gallery picker) — one pending image per send, mirroring
  // Telegram's attach-then-caption flow.
  final ImagePicker _imagePicker = ImagePicker();
  Uint8List? _pickedImageBytes;
  String? _pickedImageMimeType;

  // Voice input / spoken replies
  final Object _speechOwner = Object();
  final SpeechRecognitionCoordinator _speechCoordinator =
      SpeechRecognitionCoordinator.instance;
  SpeechToText get _speechToText => _speechCoordinator.speech;
  late TtsProvider _xtts = XttsService(fallbackHost: widget.connection.host);
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

  // Scroll management
  final _scrollController = ScrollController();
  bool _showScrollToBottom = false;
  double _lastPixels = 0;
  static final Map<String, double> _savedPositions = {};

  // Streaming-token batching: coalesce onToken callbacks into periodic
  // setState flushes instead of rebuilding on every token. Mirrors the
  // gateway's own Telegram adapter text-batch delay (adapter.py
  // _flush_text_batch) — a short fixed delay smooths bursty output into a
  // steady cadence without the UI feeling laggy.
  static const _tokenFlushDelay = Duration(milliseconds: 120);
  final StringBuffer _pendingTokens = StringBuffer();
  Timer? _tokenFlushTimer;

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
    WidgetsBinding.instance.addObserver(this);
    _client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
      pathPrefix: widget.connection.gatewayPrefix ?? '',
    );
    _gateway = GatewayChatClient(_client);
    _fetchMessages();
    _loadVerboseMode();
    _initVoice();
    _loadComfyUrl();
    _initTtsProvider();
    _scrollController.addListener(_onScroll);
    _textController.addListener(_onTextChanged);
  }

  /// Starts the background-keepalive foreground service only when the app is
  /// actually backgrounded (not merely inactive, e.g. a transient system
  /// dialog) while a generation is in flight — a normal foreground send never
  /// triggers it. Stops it again on resume; the send's own try/finally is the
  /// other stop path, covering a reply that finishes while still backgrounded.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _streaming && !_backgroundServiceActive) {
      _backgroundServiceActive = true;
      startBackgroundSendService();
    } else if (state == AppLifecycleState.resumed && _backgroundServiceActive) {
      _backgroundServiceActive = false;
      stopBackgroundSendService();
    }
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

  Future<void> _loadComfyUrl() async {
    final url = await ComfyUi.loadBaseUrl();
    if (!mounted) return;
    setState(() => _comfyBaseUrl = url);
  }

  Future<void> _loadVerboseMode() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _verboseMode = prefs.getBool('verbose_mode') ?? false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_backgroundServiceActive) {
      _backgroundServiceActive = false;
      stopBackgroundSendService();
    }
    // Stop any in-flight late-media poll from touching state after teardown.
    _mediaPollGen++;
    _savedPositions[widget.session.id] = _lastPixels;
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

  Future<void> _speakAssistantText(String text, {void Function()? onComplete}) async {
    final spokenText = text.trim();
    if (spokenText.isEmpty || !_voiceReplyEnabled) {
      onComplete?.call();
      return;
    }
    try {
      await _xtts.speak(spokenText, onComplete: onComplete);
    } catch (e) {
      onComplete?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('TTS failed: $e'),
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
    final speakable = XttsService.stripForSpeech(content);
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
          content: Text('Voice playback failed: $e'),
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
    final atBottom =
        _scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200;
    if (atBottom != !_showScrollToBottom && _streaming) {
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
    setState(() {
      if (_messages.isNotEmpty && _messages.last['role'] == 'assistant') {
        _messages.last['content'] = (_messages.last['content'] as String) + chunk;
      }
    });
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

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
    }
  }

  /// All generated-media URLs currently derivable from a message list — the
  /// same harvest the build() path uses (tool messages → filenames → view URL).
  Set<String> _mediaUrlsIn(List<Map<String, dynamic>> messages) {
    final urls = <String>{};
    for (final msg in messages) {
      if ((msg['role'] as String?) != 'tool') continue;
      final raw = (msg['content'] as String?) ?? '';
      for (final name in ComfyUi.extractMediaFilenames(raw)) {
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
    _toolMessages.clear();
    for (final msg in messages) {
      final role = (msg['role'] as String?) ?? '';
      if (role != 'tool') continue;

      final name = (msg['name'] as String?) ??
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
    _textController.selection = TextSelection.collapsed(
      offset: prompt.length,
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load models: $e')),
      );
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
        SnackBar(content: Text('Model set to $model — applies to new sessions')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not set model: $e')),
      );
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

    if (textOverride == null && _slashCommands.containsKey(text.toLowerCase())) {
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

    // Build conversation history for the SSE request. Must be chronological
    // (oldest first) and must only contain roles the model understands — a
    // raw 'tool' message would otherwise be sent as if the user typed the
    // tool's raw output, polluting subsequent replies.
    final history = <Map<String, dynamic>>[];
    for (final m in _messages) {
      final rawRole = m['role'];
      if (rawRole != 'user' && rawRole != 'assistant' && rawRole != 'agent') {
        continue;
      }
      final content = parseMessageContent(m['content']).text.trim();
      if (content.isEmpty) continue;
      history.add({
        'role': rawRole == 'agent' ? 'assistant' : rawRole,
        'content': content,
      });
    }

    // Keep the exact optimistic rows and attachment together so a failed
    // multimodal send can remove only its own UI rows and restore the draft.
    final pendingSend = PendingChatSend(
      text: text,
      imageBytes: _pickedImageBytes,
      imageMimeType: _pickedImageMimeType,
    );

    // Invalidate any in-flight late-media poll from the previous turn.
    _mediaPollGen++;
    setState(() {
      _sending = true;
      _streaming = true;
      _showScrollToBottom = false;
      pendingSend.appendOptimisticRows(_messages);
      _pickedImageBytes = null;
      _pickedImageMimeType = null;
      _liveMediaUrls.clear();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    // Accumulate tokens into the streaming placeholder
    _streamCancelToken = StreamCancelToken();
    try {
      await _gateway.sendMessageStreaming(
      message: text,
      sessionId: widget.session.id,
      history: history,
      imageDataUrls: pendingSend.imageDataUrls,
      cancelToken: _streamCancelToken,
      onToken: (token) {
        if (!mounted) return;
        _pendingTokens.write(token);
        _tokenFlushTimer ??= Timer(_tokenFlushDelay, _flushPendingTokens);
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
          setState(() {
            _messages = messages;
            _streaming = false;
            _sending = false;
            _showScrollToBottom = false;
            // The real message list now carries whatever _liveMediaUrls was
            // standing in for — drop it so nothing renders twice.
            _liveMediaUrls.clear();
          });
          // The image tool's result row may land just after this refetch;
          // poll briefly so a freshly generated image doesn't require leaving
          // and reopening the chat to appear.
          _pollForLateMedia();
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
                onComplete: _autoContinueEnabled ? _scheduleAutoContinue : null,
              );
            } else if (_autoContinueEnabled) {
              _scheduleAutoContinue();
            }
          } else if (_autoContinueEnabled) {
            // Voice reply is off, so there's no playback-finished signal to
            // wait on — just pace on a fixed delay instead.
            _scheduleAutoContinue();
          }
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _streaming = false;
            _sending = false;
          });
        }
      },
      onError: (error) {
        _tokenFlushTimer?.cancel();
        _tokenFlushTimer = null;
        _pendingTokens.clear();
        _streamCancelToken = null;
        if (!mounted) return;
        _handleSendError(pendingSend, error);
      },
      );
    } finally {
      // Covers the reply-finishes-while-backgrounded path; the resumed
      // branch of didChangeAppLifecycleState covers the other (app comes
      // back to the foreground before the reply is done).
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

  void _handleSendError(PendingChatSend pending, Object e) {
    setState(() {
      _sending = false;
      _streaming = false;
      _awaitingVoiceReply = false;
      pending.rollbackOptimisticRows(_messages);
      _pickedImageBytes = pending.imageBytes;
      _pickedImageMimeType = pending.imageMimeType;
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
          content: Text('Send failed: $e'),
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

    setState(() {
      final idx = toolCallId.isEmpty
          ? -1
          : _toolMessages.indexWhere(
              (m) => m['toolCallId'] == toolCallId,
            );
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

    if (done &&
        (tool == 'image_generate' || tool == 'video_generate')) {
      // Newer servers emit hermes.tool.progress with the rendered filename
      // directly in the SSE payload — render off that and skip polling.
      final filename = progress['filename']?.toString();
      if (filename != null && filename.isNotEmpty) {
        final url = ComfyUi.viewUrl(_comfyBaseUrl, filename);
        if (!_liveMediaUrls.contains(url)) {
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
      appBar: AppBar(
        title: Text(
          widget.session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(
              _autoContinueEnabled ? Icons.repeat_on : Icons.repeat,
            ),
            color: _autoContinueEnabled
                ? Theme.of(context).colorScheme.primary
                : null,
            tooltip: _autoContinueEnabled
                ? 'Auto-continue on — tap to stop'
                : 'Auto-continue: send another turn automatically after each reply',
            onPressed: _toggleAutoContinue,
          ),
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Image gallery',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MediaGalleryScreen(
                  messages: _messages,
                  comfyBaseUrl: _comfyBaseUrl,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.call),
            tooltip: 'Phone call mode',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CallScreen(
                  connection: widget.connection,
                  session: widget.session,
                ),
              ),
            ),
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
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: Responsive.isTablet(context) ? 800 : double.infinity,
          ),
          child: Column(
            children: [
              Expanded(child: _buildBody()),
              if (_showingSlashSuggestions) _buildSlashSuggestions(),
              _buildInputBar(),
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
              color: _listening ? Theme.of(context).colorScheme.error : null,
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
    setState(() {
      _pickedImageBytes = bytes;
      _pickedImageMimeType = mime;
    });
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
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

    // Build display list: consecutive tool messages grouped into cards,
    // interleaved with user/assistant bubbles. Images rendered by the ComfyUI
    // tool are detected by filename in the tool content and shown inline.
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
        // Harvest generated-image filenames from the raw tool content.
        final raw = (msg['content'] as String?) ?? '';
        for (final name in ComfyUi.extractMediaFilenames(raw)) {
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
    // getMessages() refetch — see _pollForLiveMedia.
    if (_streaming && _liveMediaUrls.isNotEmpty) {
      displayMessages.add(_liveMediaUrls.toList());
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: displayMessages.length,
      itemBuilder: (context, index) {
        final item = displayMessages[index];

        if (item is List<Map<String, dynamic>>) {
          return _ToolProgressCard(items: item, verbose: _verboseMode);
        }

        if (item is List<String>) {
          // Generated media (images/videos) extracted from tool results.
          return _MediaRow(urls: item);
        }

        final msg = item as Map<String, dynamic>;
        final role = (msg['role'] as String?) ?? 'assistant';
        final parsed = parseMessageContent(msg['content']);
        final isUser = role == 'user';

        return _MessageBubble(
          content: parsed.text,
          imageUrls: parsed.imageUrls,
          isUser: isUser,
          verbose: _verboseMode,
          metadata: msg,
          isSpeaking: _isSpeakingMessage(msg),
          onReplay: isUser ? null : () => _replayMessage(msg),
        );
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final List<String> imageUrls;
  final bool isUser;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final bool isSpeaking;
  final VoidCallback? onReplay;

  const _MessageBubble({
    required this.content,
    this.imageUrls = const [],
    required this.isUser,
    this.verbose = false,
    this.metadata = const {},
    this.isSpeaking = false,
    this.onReplay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Bubble colors
    final userBubbleColor = const Color(0xFFD4AF37);
    final assistantBubbleColor = isDark
        ? const Color(0xFF2A2A2A)
        : const Color(0xFFEAEAEA);
    final assistantTextColor = isDark ? Colors.white : Colors.black87;

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
                              ? Colors.white.withValues(alpha: 0.8)
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
                    .map((url) => _AttachedImage(url: url))
                    .toList(),
              ),
            ),
          // Message content
          if (content.isNotEmpty)
            MarkdownBody(
              data: content,
            styleSheet: MarkdownStyleSheet(
              p: (isUser
                  ? theme.textTheme.bodyMedium?.copyWith(color: Colors.white)
                  : theme.textTheme.bodyMedium?.copyWith(
                      color: assistantTextColor,
                    )),
              code: TextStyle(
                backgroundColor: (isUser ? Colors.white : Colors.black)
                    .withValues(alpha: 0.12),
                fontFamily: 'monospace',
                color: isUser ? Colors.white : null,
              ),
              a: TextStyle(
                color: isUser ? Colors.white70 : theme.colorScheme.primary,
              ),
              h1: isUser
                  ? theme.textTheme.headlineSmall?.copyWith(color: Colors.white)
                  : theme.textTheme.headlineSmall,
              h2: isUser
                  ? theme.textTheme.titleLarge?.copyWith(color: Colors.white)
                  : theme.textTheme.titleLarge,
              h3: isUser
                  ? theme.textTheme.titleMedium?.copyWith(color: Colors.white)
                  : theme.textTheme.titleMedium,
              blockquote: TextStyle(
                color: isUser ? Colors.white60 : Colors.grey,
                fontStyle: FontStyle.italic,
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isUser ? Colors.white38 : theme.colorScheme.primary,
                    width: 3,
                  ),
                ),
              ),
              em: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: Colors.white,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
              strong: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
            ),
          ),
          // Per-message TTS replay (assistant messages only).
          if (!isUser && onReplay != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(
                    isSpeaking ? Icons.stop_rounded : Icons.volume_up_rounded,
                  ),
                  tooltip: isSpeaking ? 'Stop' : 'Replay',
                  color: isDark ? Colors.white54 : Colors.black45,
                  onPressed: onReplay,
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

  const _ToolProgressCard({
    required this.items,
    this.verbose = false,
  });

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
      return content.isNotEmpty ? content.substring(0, content.length < 2 ? content.length : 2) : '\uD83D\uDD27';
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
          Text(
            emojis.join(' '),
            style: const TextStyle(fontSize: 13),
          ),
          if (active)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: fg,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// An image attached to a chat message (sent by the user, or echoed back by
/// the gateway from persisted history). Handles both `data:` URLs (the raw
/// bytes we just picked and haven't round-tripped through the server yet)
/// and `http(s)` URLs. Tappable to view full-screen.
class _AttachedImage extends StatelessWidget {
  final String url;
  const _AttachedImage({required this.url});

  Uint8List? get _dataBytes {
    if (!url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _dataBytes;
    final image = bytes != null
        ? Image.memory(bytes, fit: BoxFit.cover)
        : Image.network(url, fit: BoxFit.cover);

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(backgroundColor: Colors.black),
              body: SafeArea(
                child: Center(
                  child: InteractiveViewer(
                    child: bytes != null
                        ? Image.memory(bytes)
                        : Image.network(url),
                  ),
                ),
              ),
            ),
          ),
        ),
        child: SizedBox(width: 140, height: 140, child: image),
      ),
    );
  }
}

/// A column of generated media (images and/or videos) from tool results.
class _MediaRow extends StatelessWidget {
  final List<String> urls;
  const _MediaRow({required this.urls});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: urls.map((u) {
        final filename = Uri.parse(u).queryParameters['filename'] ?? '';
        return ComfyUi.isVideo(filename)
            ? _VideoBubble(url: u)
            : _ImageBubble(url: u);
      }).toList(),
    );
  }
}

/// One generated image, fetched from ComfyUI's /view endpoint. Tappable to
/// open full-screen with pinch-zoom.
class _ImageBubble extends StatelessWidget {
  final String url;
  const _ImageBubble({required this.url});

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width - 80;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      constraints: BoxConstraints(maxWidth: maxW),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: GestureDetector(
        onTap: () => _openFull(context),
        child: Image.network(
          url,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            final total = progress.expectedTotalBytes;
            return SizedBox(
              height: 160,
              child: Center(
                child: CircularProgressIndicator(
                  value: total != null && total > 0
                      ? progress.cumulativeBytesLoaded / total
                      : null,
                ),
              ),
            );
          },
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
    );
  }

  void _openFull(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black),
          body: SafeArea(
            child: Center(
              child: InteractiveViewer(child: Image.network(url)),
            ),
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
  const _VideoBubble({required this.url});

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  late final Player _player = Player();
  late final VideoController _videoController = VideoController(_player);
  bool _ready = false;
  bool _failed = false;
  bool _playing = false;
  double _aspect = 16 / 9;

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Surface real decode/open failures instead of silently spinning forever.
    _subs.add(_player.stream.error.listen((e) {
      debugPrint('[media_kit] video error for ${widget.url}: $e');
      if (mounted) setState(() => _failed = true);
    }));
    _subs.add(_player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    }));
    _subs.add(_player.stream.width.listen((_) => _updateAspect()));
    _subs.add(_player.stream.height.listen((_) => _updateAspect()));
    try {
      // Open paused so multiple clips in a transcript don't all autoplay.
      await _player.open(Media(widget.url), play: false);
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      debugPrint('[media_kit] open failed for ${widget.url}: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _updateAspect() {
    final w = _player.state.width;
    final h = _player.state.height;
    if (w != null && h != null && w > 0 && h > 0) {
      final next = w / h;
      if (next != _aspect && mounted) setState(() => _aspect = next);
    }
  }

  void _togglePlay() {
    _playing ? _player.pause() : _player.play();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width - 80;
    Widget body;
    if (_failed) {
      body = const SizedBox(
        height: 100,
        child: Center(
          child: Text('video unavailable', style: TextStyle(color: Colors.grey)),
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
                controller: _videoController,
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
              child: _VideoProgressBar(player: _player),
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
