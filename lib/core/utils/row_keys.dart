// Stable identity for transcript rows.
//
// The chat ListView needs keys for two reasons: so a stateful row keeps its
// element when the list shifts, and so a message can be located by identity
// for scroll-to-message. Keys are only worth having in a LAZY list when they
// come with a findChildIndexCallback — without one, a keyed child that moved
// index is discarded and rebuilt rather than reused (see
// test/list_element_reuse_test.dart), which is strictly worse than no keys.
//
// Requirements the scheme has to satisfy:
//
//  * Stable across a refetch. getMessages() returns brand-new map objects
//    every time, so anything derived from object identity (ObjectKey,
//    identityHashCode) changes on every refresh and rebuilds the whole
//    transcript — exactly what the display-list memoization exists to avoid.
//  * Unique. Duplicate keys among siblings throw in Flutter, and this app
//    genuinely produces identical messages: auto-continue sends the literal
//    text "Continue." over and over.
//  * Stable for the in-flight reply, whose content changes several times a
//    second while streaming.

/// FNV-1a, 32-bit, as 8 hex chars.
///
/// Dart's own `hashCode` is explicitly not stable across runs, and these keys
/// are compared against ones built in an earlier build of the same list, so a
/// fixed algorithm is required rather than merely convenient.
String stableContentHash(String s) {
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// Identity for one message row, before de-duplication.
///
/// Prefers a server-supplied [id] when there is one — nothing in the app
/// consumes a message id today, but if the gateway starts sending one this
/// picks it up and becomes exact instead of content-derived.
///
/// [streaming] marks the assistant reply currently being written into. Its
/// text changes on every token flush, so hashing it would hand the row a new
/// key several times a second and destroy the element (and its markdown
/// parse) each time. A fixed sentinel keeps it put for the life of the turn;
/// it settles onto a content key at the next refetch.
String messageRowKey({
  required String role,
  required String text,
  String? id,
  bool streaming = false,
}) {
  if (streaming) return 'm:streaming';
  if (id != null && id.isNotEmpty) return 'm:$id';
  return 'm:$role:${stableContentHash(text)}';
}

/// Key for a grouped run of tool-progress cards.
String toolRowKey(String? firstToolCallId) {
  final id = firstToolCallId ?? '';
  return id.isEmpty ? 't:group' : 't:$id';
}

/// Key for a row of generated media.
String mediaRowKey(String? firstUrl) => 'media:${firstUrl ?? ''}';

/// Makes [base] unique within one pass, recording occurrences in [seen].
///
/// The suffix is positional, so as long as row order is stable the same
/// logical row keeps the same suffix across rebuilds — two "Continue." turns
/// stay `…` and `…#1` rather than swapping.
String disambiguate(String base, Map<String, int> seen) {
  final n = seen[base] ?? 0;
  seen[base] = n + 1;
  return n == 0 ? base : '$base#$n';
}
