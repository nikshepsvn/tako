# Tako's changes to vendored CefSwift

Upstream: https://github.com/Rajaniraiyn/CefSwift at `59cad64e124b8efdb6b2ee811963097bb6e689e8`.
Dropped: Examples, Tests, Plugins, the `cef-helper` target and docs (Tako bundles CEF with
`scripts/embed-cef.sh` and has its own helper target).

## Windowed browsers close completely (`BrowserClient.swift`, `do_close`)

Upstream returns false from `do_close`, which for a windowed browser makes CEF send
`performClose:` to the top-level window: in Tako that is the app's main window, which doesn't
close, so every closed pane left a half-closed browser behind (its page in `/json/list`, its
renderer, and a registered browser that kept the pump at 30 Hz). The patch returns true and
removes CEF's view from its superview, whose dealloc destroys the browser (`on_before_close`
then fires as usual). Browsers without a native view (OSR) still return false.
