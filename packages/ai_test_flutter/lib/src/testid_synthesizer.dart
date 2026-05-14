import 'package:flutter/widgets.dart';

/// Synthesizes stable `data-testid` strings for Flutter widgets that carry no
/// explicit [Key] annotation.
///
/// Resolution order:
/// 1. [ValueKey<String>] on the widget wins unconditionally.
/// 2. Form-input widgets ([widgetTypeName] is `WFormInput`, `WInput`, or
///    `WFormCheckbox`) use the [formFieldName] → `input.<fieldName>`.
/// 3. Button widgets (`WButton`) use [extractedText] → `button.<snake>`.
/// 4. Anchor widgets (`WAnchor`) use [extractedText] → `link.<snake>`.
/// 5. Everything else falls back to `unknown.<typename>.<depth>`.
///
/// The fallback depth is derived from [Element.depth] — stable within a single
/// mount but NOT across full rebuilds. Only use it when no stable signal exists.
class TestidSynthesizer {
  /// Synthesizes a testid for the widget at [element].
  ///
  /// [widgetTypeName] — `element.widget.runtimeType.toString()`.
  /// [extractedText] — first text found in the widget's subtree.
  /// [formFieldName] — field key from the enclosing `MagicFormData` scope.
  /// [key] — the widget's raw key (any [Key] subtype or null).
  String synthesize(
    Element element, {
    String? widgetTypeName,
    String? extractedText,
    String? formFieldName,
    Object? key,
  }) {
    // 1. Explicit ValueKey<String> always wins.
    if (key is ValueKey<String>) {
      return key.value;
    }

    final typeName = widgetTypeName ?? 'unknown';

    // 2. Dispatch on widget type.
    switch (typeName) {
      case 'WFormInput':
      case 'WInput':
      case 'WFormCheckbox':
        if (formFieldName != null) {
          return 'input.$formFieldName';
        }

      case 'WButton':
        if (extractedText != null) {
          return 'button.${_snakeCase(extractedText)}';
        }

      case 'WAnchor':
        if (extractedText != null) {
          return 'link.${_snakeCase(extractedText)}';
        }
    }

    // 3. Unknown or unresolvable widget — use depth as a positional hint.
    return 'unknown.${typeName.toLowerCase()}.${element.depth}';
  }

  /// Public test hook so edge-case tests can exercise the helper directly
  /// without pumping a full widget tree.
  ///
  /// Production callers use [synthesize] exclusively; this method is
  /// `@visibleForTesting` in spirit but kept public to avoid `package:meta`
  /// import on the test side.
  static String snakeCaseForTesting(String text) => _snakeCase(text);
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Converts [text] to a URL-safe snake_case slug.
///
/// Algorithm:
/// 1. Lower-case the entire string.
/// 2. Remove apostrophes and other characters that should be stripped entirely
///    rather than replaced with an underscore (e.g. "Don't" → "dont").
/// 3. Replace every remaining non-alphanumeric run with a single underscore.
/// 4. Trim any leading or trailing underscores produced by step 3.
String _snakeCase(String text) {
  // 1. Lower-case.
  var result = text.toLowerCase();

  // 2. Strip apostrophes (and other quote-like chars) so "don't" → "dont",
  //    not "don_t".
  result = result.replaceAll(RegExp(r"[''']"), '');

  // 3. Replace non-alphanumeric runs with a single underscore.
  result = result.replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  // 4. Trim leading / trailing underscores.
  result = result.replaceAll(RegExp(r'^_+|_+$'), '');

  return result;
}
