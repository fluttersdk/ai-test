// ignore_for_file: avoid_implementing_value_types
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Login-form vendored fixture.
//
// Mirrors the magic_starter login view shape
// (references/magic_starter/lib/src/ui/views/auth/magic_starter_login_view.dart:91-180)
// WITHOUT importing package:magic, package:magic_starter, or
// package:fluttersdk_wind.
//
// Class-naming approach: top-level classes are literally named MagicForm,
// WFormInput, WButton, WAnchor, WText, WFormCheckbox so that
// widget.runtimeType.toString() returns those exact strings — matching what
// the projection's _collectElementInfo reads at runtime.
//
// Dart's Object.runtimeType is NOT overridable; the ONLY working approach is
// to declare top-level classes with the exact desired names. There is no
// import collision because this file explicitly does NOT import any of the
// real packages.
//
// The synthesizer's form-field resolution path reads:
//   1. widget.controller (a TextEditingController on WFormInput/WInput/WFormCheckbox)
//   2. MagicForm's formData.data.keys → formData[key] via reference equality
// This fixture reproduces both sides of that contract.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Fake MagicFormData — mirrors the public API contract the projection reads.
// ---------------------------------------------------------------------------

/// Fake form-data scope. Mirrors the public API of MagicFormData:
///   - `data` getter returning all field keys
///   - `[]` operator returning TextEditingController for text fields and
///     throwing AssertionError for non-text fields (matching the real class).
class MagicFormData {
  final TextEditingController _email;
  final TextEditingController _password;

  MagicFormData({
    required TextEditingController email,
    required TextEditingController password,
  })  : _email = email,
        _password = password;

  /// Returns all field entries including the bool remember_me entry.
  ///
  /// The projection walks data.keys to find a matching TextEditingController
  /// via reference equality. Bool fields (remember_me) throw AssertionError
  /// from the `[]` operator, which the projection catches and skips.
  Map<String, dynamic> get data => {
        'email': _email,
        'password': _password,
        'remember_me': false,
      };

  /// Returns the TextEditingController for text fields.
  ///
  /// Throws AssertionError for non-text fields (remember_me) to match the
  /// real MagicFormData behavior — the projection catches AssertionError and
  /// skips the key.
  TextEditingController operator [](String field) {
    if (field == 'email') return _email;
    if (field == 'password') return _password;
    // Non-text field (bool, etc.) — match real MagicFormData assertion.
    assert(
      false,
      'Text field "$field" not found. Use value<T>("$field") for non-text fields.',
    );
    throw AssertionError('Non-text field: $field');
  }
}

// ---------------------------------------------------------------------------
// Fake widget classes — top-level names match production runtimeType strings.
// ---------------------------------------------------------------------------

/// Fake MagicForm. Exposes a public `formData` field (matching the real
/// MagicForm's `final MagicFormData? formData`) so the projection can read
/// the form scope via dynamic dispatch: `(widget as dynamic).formData`.
class MagicForm extends StatelessWidget {
  final MagicFormData formData;
  final Widget child;

  const MagicForm({
    super.key,
    required this.formData,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => child;
}

/// Fake WFormInput. Exposes a public `controller` field (matching the real
/// WFormInput's TextEditingController parameter) so the projection can read
/// it via `(widget as dynamic).controller` and match it against formData
/// entries via reference equality.
class WFormInput extends StatelessWidget {
  final TextEditingController controller;
  final Widget child;

  const WFormInput({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // SizedBox so this widget produces its own RenderBox — the projection
    // emits mirrors for RenderBoxes, not composition-only elements.
    return SizedBox(
      width: 300,
      height: 56,
      child: child,
    );
  }
}

/// Fake WButton. The synthesizer dispatches on runtimeType == 'WButton'
/// and reads the first descendant WText.data as the label.
class WButton extends StatelessWidget {
  final Widget child;

  const WButton({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 48,
      child: child,
    );
  }
}

/// Fake WAnchor. The synthesizer dispatches on runtimeType == 'WAnchor'
/// and reads the first descendant WText.data as the label.
class WAnchor extends StatelessWidget {
  final Widget child;

  const WAnchor({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 32,
      child: child,
    );
  }
}

/// Fake WText. The projection's _extractText reads `(widget as dynamic).data`
/// (a public String field) to find the label for button/anchor testids.
class WText extends StatelessWidget {
  final String data;

  const WText(this.data, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(data);
  }
}

/// Fake WFormCheckbox. The synthesizer dispatches on runtimeType == 'WFormCheckbox'
/// and attempts to resolve the field name via controller reference equality.
/// Since remember_me is a bool field, the [] operator throws AssertionError
/// and the projection falls back to `unknown.wformcheckbox.<depth>`.
class WFormCheckbox extends StatelessWidget {
  final Widget? label;

  const WFormCheckbox({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      height: 32,
      child: label,
    );
  }
}

// ---------------------------------------------------------------------------
// Fixture builder
// ---------------------------------------------------------------------------

/// Builds a widget tree that mimics the magic_starter login form shape.
///
/// Tree structure mirrors
/// magic_starter_login_view.dart:89-185:
///   MagicForm
///     WFormInput (email)
///     WFormInput (password)
///     WFormCheckbox (remember_me) + WAnchor (forgot_password)
///     WButton (sign_in)
///     WAnchor (dont_have_account)
///
/// The fixture uses fake trans-key strings as text (e.g. 'auth.login_title')
/// so that snake-case slug output is predictable in assertions.
Widget buildLoginFormFixture() {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final formData = MagicFormData(
    email: emailController,
    password: passwordController,
  );

  return MagicForm(
    formData: formData,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Email field.
        WFormInput(
          controller: emailController,
          child: const Text('email field'),
        ),

        const SizedBox(height: 16),

        // 2. Password field.
        WFormInput(
          controller: passwordController,
          child: const Text('password field'),
        ),

        const SizedBox(height: 20),

        // 3. Remember-me checkbox + forgot-password link row.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const WFormCheckbox(
              label: WText('auth.remember_me'),
            ),
            const WAnchor(
              child: WText('auth.forgot_password'),
            ),
          ],
        ),

        const SizedBox(height: 24),

        // 4. Sign-in button.
        const WButton(
          child: WText('auth.login_title'),
        ),

        const SizedBox(height: 24),

        // 5. Register link.
        const WAnchor(
          child: WText('auth.dont_have_account'),
        ),
      ],
    ),
  );
}
