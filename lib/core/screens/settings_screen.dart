// Settings screen for model selection, theme toggle, and app info.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/connection_manager.dart';
import '../services/comfyui.dart';
import '../services/xtts_service.dart';
import '../../main.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SettingsScreen extends StatefulWidget {
  final SavedConnection connection;
  const SettingsScreen({required this.connection, super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late DashboardClient _client;
  Map<String, dynamic>? _modelInfo;
  Map<String, dynamic>? _modelOptions;
  bool _loading = true;
  String? _error;
  String? _successMsg;

  // Selected values
  String _selectedProvider = '';
  String _selectedModel = '';
  List<String> _providers = [];
  Map<String, List<Map<String, dynamic>>> _providerModels = {};

  @override
  void initState() {
    super.initState();
    _client = DashboardClient(
      host: widget.connection.host,
      port: widget.connection.dashboardPort,
      pathPrefix: widget.connection.dashboardPrefix ?? "",
      proxied: widget.connection.dashboardProxied,
      useHttps: widget.connection.useHttps,
      username: widget.connection.dashboardUsername,
      password: widget.connection.dashboardPassword,
    );
    _loadData();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait([
        _client.getModelInfo(),
        _client.getModelOptions(),
      ]);

      setState(() {
        _modelInfo = results[0];
        _modelOptions = results[1];
        _loading = false;
        _parseModelOptions();
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _parseModelOptions() {
    if (_modelOptions == null) return;

    final providers = _modelOptions!['providers'] as List<dynamic>? ?? [];
    _providers = [];
    _providerModels = {};

    for (final p in providers) {
      if (p is! Map<String, dynamic>) continue;
      final pMap = p;
      // Provider key is 'slug', not 'id'
      final providerId =
          (pMap['slug'] as String?) ?? (pMap['id'] as String?) ?? '';
      final rawModels = pMap['models'] as List<dynamic>? ?? [];
      if (providerId.isEmpty || rawModels.isEmpty) continue;

      _providers.add(providerId);
      // Models are strings (model IDs), not dicts
      // Convert to list of {'id': modelId, 'name': modelId} maps for dropdown
      _providerModels[providerId] = rawModels
          .map((m) {
            if (m is String) {
              return {'id': m, 'name': m};
            } else if (m is Map<String, dynamic>) {
              return m;
            }
            return <String, dynamic>{};
          })
          .where((m) => m['id'] != null && (m['id'] as String).isNotEmpty)
          .toList();
    }

    // Set initial selections from current model
    if (_modelInfo != null) {
      _selectedProvider = (_modelInfo!['provider'] as String?) ?? '';
      _selectedModel = (_modelInfo!['model'] as String?) ?? '';
    }
  }

  Future<void> _applyModel() async {
    if (_selectedProvider.isEmpty || _selectedModel.isEmpty) return;

    setState(() {
      _error = null;
      _successMsg = null;
    });

    try {
      await _client.setModel('main', _selectedProvider, _selectedModel);
      setState(() {
        _successMsg = 'Model set to $_selectedModel — applies to new sessions';
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _modelOptions == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                'Failed to load settings',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(onPressed: _loadData, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ---- Section: Model ----
        _buildSectionHeader('Model Selection'),
        if (_modelInfo != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.smart_toy,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Current Model',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_modelInfo!['model'] ?? '???'}  \nvia `${_modelInfo!['provider'] ?? '???'}`',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (_modelInfo!['effective_context_length'] != null &&
                      _modelInfo!['effective_context_length'] != 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Context: ${_modelInfo!['effective_context_length']} tokens',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),

        // Provider picker
        if (_providers.isNotEmpty) ...[
          _buildDropdown<String>(
            label: 'Provider',
            value:
                _selectedProvider.isNotEmpty &&
                    _providers.contains(_selectedProvider)
                ? _selectedProvider
                : null,
            items: _providers
                .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                .toList(),
            onChanged: (val) {
              setState(() {
                _selectedProvider = val!;
                // Reset model when switching providers
                final models = _providerModels[val];
                if (models != null && models.isNotEmpty) {
                  _selectedModel = models.first['id'] as String? ?? '';
                } else {
                  _selectedModel = '';
                }
              });
            },
          ),
          const SizedBox(height: 12),
        ],

        // Model picker
        if (_selectedProvider.isNotEmpty &&
            _providerModels.containsKey(_selectedProvider)) ...[
          _buildDropdown<String>(
            label: 'Model',
            value: _selectedModel,
            items: _providerModels[_selectedProvider]!.map((m) {
              final id = m['id'] as String? ?? '';
              final name = m['name'] as String? ?? id;
              return DropdownMenuItem(value: id, child: Text(name));
            }).toList(),
            onChanged: (val) {
              setState(() => _selectedModel = val!);
            },
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _applyModel,
              icon: const Icon(Icons.check),
              label: const Text('Apply Model'),
            ),
          ),
        ],
        const SizedBox(height: 16),

        // Success/error messages
        if (_successMsg != null)
          Card(
            color: Colors.green.shade900,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _successMsg!,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        if (_error != null && _modelOptions != null)
          Card(
            color: Colors.red.shade900,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.white)),
            ),
          ),

        const SizedBox(height: 16),

        // ---- Section: Theme ----
        _buildSectionHeader('Appearance'),
        _ThemeToggle(),
        const SizedBox(height: 8),
        _VerboseToggle(),
        const SizedBox(height: 16),

        const SizedBox(height: 16),

        // ---- Section: Voice ----
        _buildSectionHeader('Voice'),
        _VoicePicker(),
        const SizedBox(height: 8),
        _TtsParamsCard(),
        const SizedBox(height: 16),

        // ---- Section: Media ----
        _buildSectionHeader('Media'),
        _ComfyUrlField(),
        const SizedBox(height: 16),

        // ---- Section: Connection ----
        _buildSectionHeader('Connection'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoRow('Label', widget.connection.label),
                const SizedBox(height: 4),
                _infoRow('Host', widget.connection.host),
                const SizedBox(height: 4),
                _infoRow('Port', '${widget.connection.port}'),
                const SizedBox(height: 4),
                _infoRow('Base URL', widget.connection.baseUrl),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // ---- Section: About ----
        _buildSectionHeader('About'),
        _AboutCard(),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.grey,
            ),
          ),
        ),
        Expanded(child: Text(value, overflow: TextOverflow.ellipsis)),
      ],
    );
  }

  Widget _buildDropdown<T>({
    required String label,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      items: items,
      onChanged: onChanged,
    );
  }
}

/// About card that reads the real version from package_info_plus.
class _AboutCard extends StatefulWidget {
  @override
  State<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<_AboutCard> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      setState(() => _version = '${info.version}+${info.buildNumber}');
    } catch (_) {
      setState(() => _version = 'unknown');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hermes Agent for Android',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text('Version ${_version.isNotEmpty ? _version : '…'}'),
            const SizedBox(height: 8),
            const Text(
              'Browse and manage your Hermes Agent sessions from your phone. '
              'Connects to a Hermes dashboard running on your local network.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

/// Toggle for verbose mode — shows tool calls, thinking, and message metadata in chat.
class _VerboseToggle extends StatefulWidget {
  @override
  State<_VerboseToggle> createState() => _VerboseToggleState();
}

class _VerboseToggleState extends State<_VerboseToggle> {
  bool _verbose = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _verbose = prefs.getBool('verbose_mode') ?? false);
  }

  Future<void> _set(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('verbose_mode', value);
    setState(() => _verbose = value);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SwitchListTile(
        title: const Text('Verbose Mode'),
        subtitle: const Text('Show tool calls, thinking, and message metadata'),
        secondary: const Icon(Icons.terminal),
        value: _verbose,
        onChanged: _set,
      ),
    );
  }
}

class _ThemeToggle extends StatefulWidget {
  @override
  State<_ThemeToggle> createState() => _ThemeToggleState();
}

class _ThemeToggleState extends State<_ThemeToggle> {
  String _mode = 'system';

  @override
  void initState() {
    super.initState();
    _loadMode();
  }

  Future<void> _loadMode() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _mode = prefs.getString('theme_mode') ?? 'system');
  }

  Future<void> _setMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode);
    if (!mounted) return;
    setState(() => _mode = mode);
    final rootCtx = context.findAncestorStateOfType<HermesAppState>();
    rootCtx?.setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SegmentedButton<String>(
        segments: const [
          ButtonSegment(
            value: 'system',
            label: Text('System'),
            icon: Icon(Icons.brightness_auto, size: 18),
          ),
          ButtonSegment(
            value: 'dark',
            label: Text('Dark'),
            icon: Icon(Icons.dark_mode, size: 18),
          ),
          ButtonSegment(
            value: 'light',
            label: Text('Light'),
            icon: Icon(Icons.light_mode, size: 18),
          ),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => _setMode(s.first),
        style: ButtonStyle(visualDensity: VisualDensity.compact),
      ),
    );
  }
}

/// Voice settings backed by the XTTS-v2 server: server URL, speaker, and
/// language. Speakers and languages are fetched live from the server so the
/// dropdowns reflect what's actually installed.
class _VoicePicker extends StatefulWidget {
  @override
  State<_VoicePicker> createState() => _VoicePickerState();
}

class _VoicePickerState extends State<_VoicePicker> {
  final XttsService _xtts = XttsService();
  final TextEditingController _urlController = TextEditingController();

  List<String> _speakers = [];
  List<String> _languages = [];
  String? _selectedSpeaker;
  String _selectedLanguage = XttsPrefs.defaultLanguage;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _xtts.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final prefs = await SharedPreferences.getInstance();
    _urlController.text =
        prefs.getString(XttsPrefs.baseUrl) ?? XttsPrefs.defaultBaseUrl;
    _selectedSpeaker = prefs.getString(XttsPrefs.speaker);
    _selectedLanguage =
        prefs.getString(XttsPrefs.language) ?? XttsPrefs.defaultLanguage;

    try {
      final results = await Future.wait([
        _xtts.getSpeakers(baseUrlOverride: _urlController.text),
        _xtts.getLanguages(baseUrlOverride: _urlController.text),
      ]);
      if (!mounted) return;
      setState(() {
        _speakers = results[0];
        _languages = results[1];
        // Drop a stale saved speaker that the server no longer offers.
        if (_selectedSpeaker != null &&
            !_speakers.contains(_selectedSpeaker)) {
          _selectedSpeaker = null;
        }
        if (!_languages.contains(_selectedLanguage) && _languages.isNotEmpty) {
          _selectedLanguage = _languages.contains(XttsPrefs.defaultLanguage)
              ? XttsPrefs.defaultLanguage
              : _languages.first;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _saveUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = XttsService.normalizeBaseUrl(_urlController.text);
    await prefs.setString(XttsPrefs.baseUrl, normalized);
    _urlController.text = normalized;
    await _load();
  }

  Future<void> _setSpeaker(String? speaker) async {
    final prefs = await SharedPreferences.getInstance();
    if (speaker == null) {
      await prefs.remove(XttsPrefs.speaker);
    } else {
      await prefs.setString(XttsPrefs.speaker, speaker);
    }
    setState(() => _selectedSpeaker = speaker);
  }

  Future<void> _setLanguage(String? language) async {
    if (language == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(XttsPrefs.language, language);
    setState(() => _selectedLanguage = language);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // XTTS server URL + reload
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'XTTS server URL',
                      hintText: 'http://0.0.0.0:8020',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onSubmitted: (_) => _saveUrl(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Connect / reload voices',
                  onPressed: _loading ? null : _saveUrl,
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_error != null)
              Text(
                'Could not reach XTTS server:\n$_error',
                style: const TextStyle(color: Colors.orange),
              )
            else ...[
              // Speaker picker
              DropdownButtonFormField<String?>(
                initialValue: _selectedSpeaker,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Speaker',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('None (spoken replies off)'),
                  ),
                  ..._speakers.map(
                    (s) => DropdownMenuItem(
                      value: s,
                      child: Text(s, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: _setSpeaker,
              ),
              const SizedBox(height: 12),

              // Language picker
              DropdownButtonFormField<String>(
                initialValue: _languages.contains(_selectedLanguage)
                    ? _selectedLanguage
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Language',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                items: _languages
                    .map(
                      (l) => DropdownMenuItem(value: l, child: Text(l)),
                    )
                    .toList(),
                onChanged: _setLanguage,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// ComfyUI server URL — the app fetches generated images from its /view
/// endpoint. Defaults to the local bind; override with a LAN/Tailscale address
/// reachable from the phone.
class _ComfyUrlField extends StatefulWidget {
  @override
  State<_ComfyUrlField> createState() => _ComfyUrlFieldState();
}

class _ComfyUrlFieldState extends State<_ComfyUrlField> {
  final TextEditingController _urlController = TextEditingController();
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _urlController.text =
        prefs.getString(ComfyUiPrefs.baseUrl) ?? ComfyUiPrefs.defaultBaseUrl;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = ComfyUi.normalizeBaseUrl(_urlController.text);
    await prefs.setString(ComfyUiPrefs.baseUrl, normalized);
    _urlController.text = normalized;
    if (!mounted) return;
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'ComfyUI server URL',
                  hintText: 'http://0.0.0.0:8188',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  isDense: true,
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _save,
              icon: Icon(_saved ? Icons.check : Icons.save),
              label: Text(_saved ? 'Saved' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}

/// XTTS generation parameters (POST /set_tts_settings). Empty field = server
/// default. Applied before each spoken reply, so changes take effect next speak.
class _TtsParamsCard extends StatefulWidget {
  @override
  State<_TtsParamsCard> createState() => _TtsParamsCardState();
}

class _TtsParamsCardState extends State<_TtsParamsCard> {
  final _temp = TextEditingController();
  final _lengthPenalty = TextEditingController();
  final _repetitionPenalty = TextEditingController();
  final _topP = TextEditingController();
  final _topK = TextEditingController();
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_temp, _lengthPenalty, _repetitionPenalty, _topP, _topK]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _temp.text = _fmt(prefs.getDouble(XttsPrefs.temperature));
    _lengthPenalty.text = _fmt(prefs.getDouble(XttsPrefs.lengthPenalty));
    _repetitionPenalty.text = _fmt(prefs.getDouble(XttsPrefs.repetitionPenalty));
    _topP.text = _fmt(prefs.getDouble(XttsPrefs.topP));
    _topK.text = prefs.getInt(XttsPrefs.topK)?.toString() ?? '';
    if (mounted) setState(() {});
  }

  String _fmt(double? v) => v?.toString() ?? '';

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    double? d(String s) {
      final t = s.trim();
      if (t.isEmpty) return null;
      return double.tryParse(t);
    }

    final temp = d(_temp.text);
    final lp = d(_lengthPenalty.text);
    final rp = d(_repetitionPenalty.text);
    final tp = d(_topP.text);
    final tk = _topK.text.trim().isEmpty ? null : int.tryParse(_topK.text.trim());

    // Validate: non-empty but unparseable is an error.
    final bad = [
      if (_temp.text.trim().isNotEmpty && temp == null) 'temperature',
      if (_lengthPenalty.text.trim().isNotEmpty && lp == null) 'length_penalty',
      if (_repetitionPenalty.text.trim().isNotEmpty && rp == null)
        'repetition_penalty',
      if (_topP.text.trim().isNotEmpty && tp == null) 'top_p',
      if (_topK.text.trim().isNotEmpty && tk == null) 'top_k',
    ];

    if (bad.isNotEmpty) {
      setState(() => _error = 'Invalid number: ${bad.join(', ')}');
      return;
    }

    Future<void> setDouble(String key, double? v) async {
      if (v == null) {
        await prefs.remove(key);
      } else {
        await prefs.setDouble(key, v);
      }
    }

    await setDouble(XttsPrefs.temperature, temp);
    await setDouble(XttsPrefs.lengthPenalty, lp);
    await setDouble(XttsPrefs.repetitionPenalty, rp);
    await setDouble(XttsPrefs.topP, tp);
    if (tk == null) {
      await prefs.remove(XttsPrefs.topK);
    } else {
      await prefs.setInt(XttsPrefs.topK, tk);
    }

    if (!mounted) return;
    setState(() {
      _error = null;
      _saved = true;
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  Widget _field(String label, TextEditingController c, String hint) {
    return Expanded(
      child: TextField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          isDense: true,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Generation parameters',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              'Empty = server default. Applied before each reply.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _field('Temperature', _temp, '0.75'),
                const SizedBox(width: 8),
                _field('Length penalty', _lengthPenalty, '1.0'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _field('Repetition pen.', _repetitionPenalty, '5.0'),
                const SizedBox(width: 8),
                _field('Top P', _topP, '0.85'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _field('Top K', _topK, '50'),
                const SizedBox(width: 8),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _save,
                  icon: Icon(_saved ? Icons.check : Icons.save),
                  label: Text(_saved ? 'Saved' : 'Save'),
                ),
                if (_error != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}