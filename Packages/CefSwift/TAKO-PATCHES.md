# Tako's changes to vendored CefSwift

Upstream: https://github.com/Rajaniraiyn/CefSwift at `59cad64e124b8efdb6b2ee811963097bb6e689e8`.
Dropped: Examples, Tests, Plugins, the `cef-helper` target and docs (Tako bundles CEF with
`scripts/embed-cef.sh` and has its own helper target).

## Idle message pump (`CefMessagePump.swift`, `CefRuntime.swift`, browser factories)

Upstream polls `cef_do_message_loop_work()` at 30 Hz for as long as CEF is initialized, which
can't be undone because CEF can't be shut down and restarted in one process. The patch keeps
30 Hz while any browser exists or is being created, and after `CefRuntime.idleGrace` (10 s)
with none drops to a 1 s poll with 20% timer tolerance. Requests CEF makes through
`on_schedule_message_pump_work` are still honored right away (immediate work runs at once;
delayed work is clamped to the current poll interval). `CefRuntime.isPumpIdle` reports the state.

## Windowed browsers close completely (`BrowserClient.swift`, `do_close`)

Upstream returns false from `do_close`, which for a windowed browser makes CEF send
`performClose:` to the top-level window: in Tako that is the app's main window, which doesn't
close, so every closed pane left a half-closed browser behind (its page in `/json/list`, its
renderer, and a registered browser that kept the pump at 30 Hz). The patch returns true and
removes CEF's view from its superview, whose dealloc destroys the browser (`on_before_close`
then fires as usual). Browsers without a native view (OSR) still return false.
