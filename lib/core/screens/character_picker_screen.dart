// Grid of SillyTavern character cards served by the gateway. Picking one
// pops with the chosen CharacterSummary; the caller loads the persona and
// starts a fresh chat (see ChatScreen._pickCharacter).
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/character_voice_prefs.dart';
import '../services/chatterbox_service.dart';
import '../services/connection_manager.dart';
import '../services/tts_provider.dart';
import '../services/xtts_service.dart';
import '../widgets/cached_media_thumbnail.dart';

class CharacterPickerScreen extends StatefulWidget {
  final SavedConnection connection;
  const CharacterPickerScreen({required this.connection, super.key});

  @override
  State<CharacterPickerScreen> createState() => _CharacterPickerScreenState();
}

class _CharacterPickerScreenState extends State<CharacterPickerScreen> {
  late final ApiClient _client;
  List<CharacterSummary> _characters = [];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
      pathPrefix: widget.connection.gatewayPrefix ?? '',
    );
    _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final chars = await _client.getCharacters();
      if (!mounted) return;
      setState(() {
        _characters = chars;
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

  /// Assigns (or clears) a voice for [character], distinct from the app-wide
  /// XTTS/Chatterbox voice in Settings. Fetches the speaker/voice list from
  /// whichever backend is currently active in Settings -- the override is
  /// only meaningful for that backend, since XTTS speaker filenames and
  /// Chatterbox voice filenames are different sets (see CharacterVoicePrefs).
  Future<void> _setCharacterVoice(CharacterSummary character) async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString(ttsProviderPrefKey) ?? 'xtts';
    final current = await CharacterVoicePrefs.get(
      character.primaryImage,
      provider,
    );
    if (!mounted) return;

    List<String> voices;
    try {
      if (provider == 'chatterbox') {
        final svc = ChatterboxService(fallbackHost: widget.connection.host);
        voices = await svc.getVoices();
        svc.dispose();
      } else {
        final svc = XttsService(fallbackHost: widget.connection.host);
        voices = await svc.getSpeakers();
        svc.dispose();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not load voices: $e')));
      return;
    }
    if (!mounted) return;

    // '' is the "use the app-wide default" sentinel, distinct from null
    // (dialog dismissed / no change).
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Voice for ${character.name}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, ''),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: current == null ? const Icon(Icons.check, size: 18) : null,
                ),
                const Text('Use app default'),
              ],
            ),
          ),
          for (final v in voices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, v),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: current == v ? const Icon(Icons.check, size: 18) : null,
                  ),
                  Expanded(child: Text(v, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;

    await CharacterVoicePrefs.set(
      character.primaryImage,
      provider,
      selected.isEmpty ? null : selected,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          selected.isEmpty
              ? 'Voice cleared for ${character.name}'
              : 'Voice set for ${character.name}',
        ),
      ),
    );
  }

  List<CharacterSummary> get _visible {
    if (_query.trim().isEmpty) return _characters;
    final q = _query.toLowerCase();
    return _characters.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Characters (${_characters.length})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: 'Refresh',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search characters…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null && _characters.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                'Could not load characters',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_characters.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.person_outline,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'No characters found',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Put character card images in the folder your gateway’s '
                'HERMES_CHARACTERS_DIR points at.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final visible = _visible;
    if (visible.isEmpty) {
      return const Center(child: Text('No characters match that search'));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.72,
      ),
      itemCount: visible.length,
      itemBuilder: (context, i) => _CharacterTile(
        character: visible[i],
        client: _client,
        onTap: () => Navigator.pop(context, visible[i]),
        onSetVoice: () => _setCharacterVoice(visible[i]),
      ),
    );
  }
}

class _CharacterTile extends StatelessWidget {
  final CharacterSummary character;
  final ApiClient client;
  final VoidCallback onTap;
  final VoidCallback onSetVoice;

  const _CharacterTile({
    required this.character,
    required this.client,
    required this.onTap,
    required this.onSetVoice,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      // The tile owns the tap; the thumbnail's own tap-to-zoom
                      // would otherwise swallow it and open a viewer instead of
                      // selecting the character.
                      child: CachedMediaThumbnail(
                        url: client.characterImageUrl(character.primaryImage),
                        headers: client.authHeaders,
                        // Cards are full-res PNGs (up to 6MB / ~25MB decoded);
                        // decode at roughly tile width so a 70-card grid
                        // doesn't exhaust memory.
                        decodeWidth: 400,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Material(
                      color: Colors.black45,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onSetVoice,
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(
                            Icons.record_voice_over_outlined,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                character.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
