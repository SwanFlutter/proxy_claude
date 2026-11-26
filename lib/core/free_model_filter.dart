/// Heuristic + metadata based detection of free-to-use models.
///
/// Detection strategy (in order):
///  1. **Provider-level flag** — e.g. Groq and Google Gemini expose their
///     catalog behind a free tier, so the user can mark the whole provider
///     as free (`assumeProviderFree`).
///  2. **ID patterns** — OpenRouter's `:free` suffix and other common
///     conventions (`-free`, `free-tier`, standalone `free` token).
///  3. **Pricing metadata** — prompt & completion price both `<= 0`
///     (OpenRouter ships `pricing.prompt` / `pricing.completion` per model).
class FreeModelFilter {
  const FreeModelFilter._();

  static const List<String> _freeSuffixes = [
    ':free',
    '-free',
    '_free',
    '.free',
    '(free)',
  ];

  static const List<String> _freeSubstrings = [
    'free-tier',
    'freetier',
  ];

  static final RegExp _standaloneFree =
      RegExp(r'(?:^|[^a-z0-9])free(?:[^a-z0-9]|$)');

  static bool isFree({
    required String modelId,
    double? promptPrice,
    double? completionPrice,
    bool assumeProviderFree = false,
  }) {
    if (assumeProviderFree) return true;
    final id = modelId.toLowerCase().trim();
    for (final suffix in _freeSuffixes) {
      if (id.endsWith(suffix)) return true;
    }
    for (final s in _freeSubstrings) {
      if (id.contains(s)) return true;
    }
    if (_standaloneFree.hasMatch(id)) return true;
    if (promptPrice != null && completionPrice != null) {
      if (promptPrice <= 0 && completionPrice <= 0) return true;
    }
    return false;
  }
}
