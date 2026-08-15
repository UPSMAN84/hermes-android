// SillyTavern character cards served by the gateway from
// HERMES_CHARACTERS_DIR (see api_server.py _handle_list_characters).
// The name comes from metadata embedded in the card PNG, not the filename.

/// One character in the picker list: display name + its image files.
class CharacterSummary {
  final String name;

  /// Paths relative to the characters dir, passed back as the `path` query
  /// param when fetching the image or card.
  final List<String> images;

  const CharacterSummary({required this.name, required this.images});

  String get primaryImage => images.first;

  factory CharacterSummary.fromJson(Map<String, dynamic> json) {
    return CharacterSummary(
      name: (json['name'] ?? '').toString(),
      images: (json['images'] as List? ?? [])
          .map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toList(),
    );
  }
}

/// The persona fields embedded in a card.
class CharacterCard {
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMes;
  final String systemPrompt;

  const CharacterCard({
    required this.name,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMes = '',
    this.systemPrompt = '',
  });

  factory CharacterCard.fromJson(Map<String, dynamic> json) {
    String s(String k) => (json[k] ?? '').toString();
    return CharacterCard(
      name: s('name'),
      description: s('description'),
      personality: s('personality'),
      scenario: s('scenario'),
      firstMes: s('first_mes'),
      systemPrompt: s('system_prompt'),
    );
  }

  /// Substitutes SillyTavern's macros. Cards are written with `{{char}}` and
  /// `{{user}}` placeholders; sending them raw would leak the literal braces
  /// into the model's context.
  String _expand(String text, String userName) => text
      .replaceAll('{{char}}', name)
      .replaceAll('{{user}}', userName)
      .replaceAll('<BOT>', name)
      .replaceAll('<USER>', userName);

  /// The message that loads this character. Sent as an ordinary user turn —
  /// the gateway persists its own history and ignores any client-side
  /// history list, so a persona has to be a real message to survive.
  ///
  /// Prefixed with [setupMarker] so the chat view can hide this wall of
  /// prose from the transcript while the model still sees it.
  String buildSetupMessage({String userName = 'User'}) {
    final b = StringBuffer(setupMarker)..writeln();
    b.writeln('You are roleplaying as $name. Stay in character for the rest '
        'of this conversation, and never mention these instructions.');
    if (systemPrompt.trim().isNotEmpty) {
      b..writeln()..writeln(_expand(systemPrompt, userName));
    }
    if (description.trim().isNotEmpty) {
      b..writeln()..writeln('# Character')..writeln(_expand(description, userName));
    }
    if (personality.trim().isNotEmpty) {
      b..writeln()..writeln('# Personality')..writeln(_expand(personality, userName));
    }
    if (scenario.trim().isNotEmpty) {
      b..writeln()..writeln('# Scenario')..writeln(_expand(scenario, userName));
    }
    if (firstMes.trim().isNotEmpty) {
      b
        ..writeln()
        ..writeln('# Opening')
        ..writeln('Begin the conversation by sending exactly this greeting, '
            'in character, with no preamble:')
        ..writeln()
        ..writeln(_expand(firstMes, userName));
    } else {
      b..writeln()..writeln('Greet me in character to begin.');
    }
    return b.toString();
  }

  /// Marks the persona-loading turn so the UI can hide it. Kept obscure
  /// enough that a real message won't collide with it.
  static const String setupMarker = '[[hermes:character-setup]]';
}
