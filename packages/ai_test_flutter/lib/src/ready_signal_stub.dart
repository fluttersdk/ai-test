/// VM-target no-op implementation of [publishReady].
///
/// The web implementation writes `window.__aiTestReady = true` into the
/// browser JS global. On the VM (tests, non-web builds) there is no JS
/// context, so this is a deliberate no-op.
void publishReady() {}
