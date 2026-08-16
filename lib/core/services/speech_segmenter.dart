// Splits a streaming assistant reply into speakable chunks at sentence
// boundaries, so call mode can start narrating before the generation has
// finished. The caller feeds in the accumulated (un-spoken) tail of the reply
// and gets back complete utterances plus whatever text is still incomplete.

/// Result of one segmentation pass: [chunks] are ready to speak, [remainder]
/// is the still-incomplete tail to keep accumulating.
class SpeechSegmentation {
  final List<String> chunks;
  final String remainder;

  const SpeechSegmentation(this.chunks, this.remainder);
}

const _terminators = {0x2E, 0x21, 0x3F, 0x2026}; // . ! ? …
const _closers = {0x22, 0x27, 0x29, 0x5D, 0x7D, 0x201D, 0x2019}; // " ' ) ] } ” ’

// Trailing words that take a period without ending a sentence. Single letters
// (initials like "J. R. R.") are handled separately.
const _abbreviations = <String>{
  'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'etc', 'inc',
  'ltd', 'co', 'dept', 'fig', 'approx', 'apt', 'al', 'eg', 'ie', 'no',
};

bool _isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

bool _isLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// True when the period at [index] closes an abbreviation rather than a
/// sentence — checked against [_abbreviations] plus bare initials.
bool _isAbbreviation(String s, int index) {
  var start = index;
  while (start > 0 && _isLetter(s.codeUnitAt(start - 1))) {
    start--;
  }
  final word = s.substring(start, index).toLowerCase();
  if (word.isEmpty) return false;
  if (word.length == 1) return true; // initial: "J. R. R. Tolkien"
  return _abbreviations.contains(word);
}

/// True when the period at [index] closes a list marker ("1.", "12.") rather
/// than a sentence — a digit run at the start of a line, optionally indented.
/// Doesn't fire mid-sentence ("Version 2.") since that digit run isn't at a
/// line start.
bool _isListMarker(String s, int index) {
  var start = index;
  while (start > 0 && _isDigit(s.codeUnitAt(start - 1))) {
    start--;
  }
  if (start == index) return false; // no digits before the period
  var lineStart = start;
  while (lineStart > 0 &&
      (s.codeUnitAt(lineStart - 1) == 0x20 ||
          s.codeUnitAt(lineStart - 1) == 0x09)) {
    lineStart--;
  }
  return lineStart == 0 || s.codeUnitAt(lineStart - 1) == 0x0A;
}

/// Offsets just past each sentence-ending punctuation run (including any
/// closing quote/bracket that trails it).
/// [scanFrom] skips a prefix already known to contain no boundary. The
/// lookback helpers still read the full string, so abbreviation and
/// list-marker detection are unaffected by where the scan starts.
/// [allowEndOfBuffer] accepts a terminator sitting at the very end of [s].
/// True for a complete string, but FALSE while the reply is still streaming:
/// mid-stream the next character has not arrived yet, and it is the character
/// that decides. "Open file." looks like a finished sentence right up until
/// the "png" lands.
List<int> _sentenceBoundaries(
  String s, {
  int scanFrom = 0,
  bool allowEndOfBuffer = true,
}) {
  final boundaries = <int>[];
  for (var i = scanFrom < 0 ? 0 : scanFrom; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x0A) {
      boundaries.add(i + 1);
      continue;
    }
    if (!_terminators.contains(c)) continue;

    var end = i + 1;
    while (end < s.length && _terminators.contains(s.codeUnitAt(end))) {
      end++;
    }
    while (end < s.length && _closers.contains(s.codeUnitAt(end))) {
      end++;
    }

    // Must be followed by whitespace or end-of-buffer. This also rejects
    // decimals ("3.14") and dotted identifiers ("file.png") for free -- but
    // only once the deciding character has actually arrived, hence
    // allowEndOfBuffer.
    if (end >= s.length) {
      if (!allowEndOfBuffer) continue;
    } else if (!_isWhitespace(s.codeUnitAt(end))) {
      continue;
    }
    if (c == 0x2E &&
        end == i + 1 &&
        (_isAbbreviation(s, i) || _isListMarker(s, i))) {
      continue;
    }

    boundaries.add(end);
    i = end - 1;
  }
  return boundaries;
}

/// Cuts [buffer] into speakable chunks at sentence boundaries.
///
/// A boundary is only used once the chunk it would close is at least
/// [minChunkChars] long; shorter candidates are skipped so a reply doesn't get
/// narrated one or two words at a time. Text after the last used boundary is
/// returned as [SpeechSegmentation.remainder].
/// [alreadyScanned] is the length of a prefix of [buffer] that a previous call
/// already examined and found no boundary in. Call mode runs this on EVERY
/// token, so rescanning the whole accumulated tail each time made the work
/// quadratic in the length of an unpunctuated passage. A small overlap is
/// re-examined because a boundary can be completed by newly arrived
/// characters -- "Hello." only counts once the following space arrives.
/// [isFinal] says whether [buffer] is the complete text. Pass false while
/// tokens are still arriving so a terminator at the end of the buffer is held
/// back until the next character confirms it really ends a sentence.
SpeechSegmentation segmentSpeech(
  String buffer, {
  int minChunkChars = 0,
  int alreadyScanned = 0,
  bool isFinal = true,
}) {
  const overlap = 8;
  final scanFrom = alreadyScanned <= overlap ? 0 : alreadyScanned - overlap;
  final chunks = <String>[];
  var start = 0;
  for (final boundary in _sentenceBoundaries(
    buffer,
    scanFrom: scanFrom,
    allowEndOfBuffer: isFinal,
  )) {
    // A boundary inside the re-scanned overlap may already have been consumed
    // by an earlier pass; `start` only ever moves forward, so skip it.
    if (boundary <= start) continue;
    if (boundary - start < minChunkChars) continue;
    final piece = buffer.substring(start, boundary).trim();
    if (piece.isNotEmpty) chunks.add(piece);
    start = boundary;
  }
  return SpeechSegmentation(chunks, buffer.substring(start));
}
