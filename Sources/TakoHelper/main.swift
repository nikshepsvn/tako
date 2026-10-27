// Chromium helper process (renderer, GPU, utility). Copied into the app bundle five times by
// scripts/embed-cef.sh; CEF picks the process type from argv.
import CefKit

MainActor.assumeIsolated { CefRuntime.helperMain() }
