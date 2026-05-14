/// Role resolver registry mapping Wind UI W-component type names to ARIA roles.
///
/// Resolves roles by widget `runtimeType.toString()` so the package stays
/// decoupled from `package:fluttersdk_wind` at compile time.
///
/// ### Usage
/// ```dart
/// final resolver = RoleResolver();
/// resolver.resolve('WButton');  // 'button'
/// resolver.resolve('WInput');   // 'textbox'
/// resolver.resolve('Unknown');  // 'none'
///
/// // Register a custom mapping at runtime.
/// resolver.register('MyWidget', 'dialog');
/// ```
class RoleResolver {
  // Built-in defaults frozen at compile time. Keys are runtimeType.toString()
  // values of the 19 Wind UI W-classes catalogued in explore-wind-inventory.md.
  static const Map<String, String> _builtInDefaults = {
    'WButton': 'button',
    'WInput': 'textbox',
    'WText': 'text',
    'WDiv': 'group',
    'WAnchor': 'button',
    'WCheckbox': 'checkbox',
    'WIcon': 'image',
    'WImage': 'image',
    'WFormInput': 'textbox',
    'WSelect': 'combobox',
    'WFormSelect': 'combobox',
    'WSvg': 'image',
    'WPopover': 'none',
    'WDatePicker': 'textbox',
    'WFormDatePicker': 'textbox',
    'WFormCheckbox': 'checkbox',
    'WSpacer': 'none',
    'WBreakpoint': 'none',
    'WKeyboardActions': 'none',
  };

  // Runtime entries (overrides + dynamic registrations). Seeded from the
  // optional constructor parameter; built-ins are checked second.
  final Map<String, String> _runtime;

  /// Creates a resolver, optionally merging caller-supplied [overrides] that
  /// take precedence over the built-in defaults.
  RoleResolver({Map<String, String>? overrides})
      : _runtime = Map<String, String>.from(overrides ?? const {});

  /// Returns the ARIA role for [widgetTypeName].
  ///
  /// Resolution order: runtime entry (overrides + [register] calls)
  /// → built-in default → `'none'`.
  String resolve(String widgetTypeName) {
    return _runtime[widgetTypeName] ??
        _builtInDefaults[widgetTypeName] ??
        'none';
  }

  /// Adds or replaces a runtime mapping for [widgetTypeName] → [role].
  ///
  /// Takes precedence over the frozen built-in defaults for the same key.
  void register(String widgetTypeName, String role) {
    _runtime[widgetTypeName] = role;
  }
}
