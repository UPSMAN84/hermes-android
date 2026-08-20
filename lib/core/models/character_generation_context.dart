import 'character.dart';

final class CharacterGenerationContext {
  CharacterGenerationContext({
    required this.sessionId,
    required this.characterName,
    required this.appearancePrompt,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.referenceImagePath,
  }) : createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc();

  factory CharacterGenerationContext.fromCard({
    required String sessionId,
    required CharacterCard card,
    required DateTime now,
  }) => CharacterGenerationContext(
    sessionId: sessionId,
    characterName: card.name,
    appearancePrompt: card.description,
    createdAt: now,
    updatedAt: now,
  );

  final String sessionId;
  final String characterName;
  final String appearancePrompt;
  final String? referenceImagePath;
  final DateTime createdAt;
  final DateTime updatedAt;

  CharacterGenerationContext copyWith({
    String? characterName,
    String? appearancePrompt,
    Object? referenceImagePath = _absent,
    DateTime? updatedAt,
  }) => CharacterGenerationContext(
    sessionId: sessionId,
    characterName: characterName ?? this.characterName,
    appearancePrompt: appearancePrompt ?? this.appearancePrompt,
    referenceImagePath: identical(referenceImagePath, _absent)
        ? this.referenceImagePath
        : referenceImagePath as String?,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'characterName': characterName,
    'appearancePrompt': appearancePrompt,
    'referenceImagePath': referenceImagePath,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory CharacterGenerationContext.fromJson(Map<String, Object?> json) {
    final createdAt = _date(json['createdAt']);
    return CharacterGenerationContext(
      sessionId: _string(json['sessionId']),
      characterName: _string(json['characterName']),
      appearancePrompt: _string(json['appearancePrompt']),
      referenceImagePath: _nullableString(json['referenceImagePath']),
      createdAt: createdAt,
      updatedAt: _date(json['updatedAt'], fallback: createdAt),
    );
  }
}

String composeGenerationPrompt({
  required String userPrompt,
  CharacterGenerationContext? context,
  required bool useContext,
}) {
  final prompt = userPrompt.trim();
  final appearance = useContext ? context?.appearancePrompt.trim() ?? '' : '';
  if (appearance.isEmpty) return prompt;
  if (prompt.isEmpty) return appearance;
  return '$appearance\n\n$prompt';
}

const Object _absent = Object();
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

String _string(Object? value) => value is String ? value : '';

String? _nullableString(Object? value) => value is String ? value : null;

DateTime _date(Object? raw, {DateTime? fallback}) {
  if (raw is String) {
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.toUtc();
  }
  return fallback?.toUtc() ?? _epoch;
}
