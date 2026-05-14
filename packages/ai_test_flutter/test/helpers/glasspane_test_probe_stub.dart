/// VM-side no-op probe.
///
/// The web test path is gated by `kIsWeb`; this helper never runs there.
bool hostIsInsideGlassPaneShadowRoot(Object host) => false;
