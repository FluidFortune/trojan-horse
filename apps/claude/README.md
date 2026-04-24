# Claude — Trojan Horse App

A native desktop wrapper for [claude.ai](https://claude.ai) using the
Trojan Horse WebKit shell. No Electron. No Node.js. ~500 lines of native code.

---

## What This Is

This is a **Trojan Horse app** — an `index.html` + `app.json` that the
Trojan Horse native wrapper loads as a desktop application.

It gives you a native window around claude.ai with:
- Persistent login (WebKit session storage)
- Runs as its own app, separate from your browser
- Cmd+Tab / Alt+Tab to it independently
- OS dock/taskbar icon
- Minimal toolbar (New Chat, Reload, connection status)

**The license for this wrapper is MIT (same as Trojan Horse).**
Claude itself is Anthropic's service — your use of claude.ai is governed
by Anthropic's Terms of Service as normal.

---

## Two Modes

### Mode 1: iframe (default — `index.html`)
The included `index.html` wraps claude.ai in an iframe with a thin toolbar.
Works on all platforms. The Trojan Horse bridge (`window.spadra`) is available
to the wrapper page but **not** inside the claude.ai frame (cross-origin).

### Mode 2: Direct Load (recommended for Linux/macOS native builds)
For a cleaner experience, patch the Trojan Horse native wrapper to load
claude.ai directly — no iframe, no wrapper HTML, WebKit talks to claude.ai
natively. The bridge won't inject (CSP blocks it), but you get the full
claude.ai experience in a native window.

**Linux patch** — in `main.cpp`, replace the app load block:
```cpp
// Instead of loading apps/claude/index.html, load claude.ai directly
webkit_web_view_load_uri(g_webview, "https://claude.ai");
```

**macOS patch** — in `AppDelegate.swift`, replace `loadApp()`:
```swift
func loadApp() {
    if let url = URL(string: "https://claude.ai") {
        webView.load(URLRequest(url: url))
    }
}
```

Or make it app-aware — read `app.json` and if it contains `"url": "https://claude.ai"`,
load that URL directly instead of `index.html`. This makes URL-based apps a
first-class Trojan Horse app type.

---

## Install

```
apps/
  claude/
    index.html   ← this file
    app.json     ← metadata + icon for the launcher
```

Drop the `claude/` folder into your `apps/` directory next to the
Trojan Horse binary. It will appear in the Home launcher automatically.

---

## A Note on URL-Type Apps

This app pattern — a `app.json` that wraps an external URL — suggests a
natural extension to Trojan Horse:

```json
{
  "name": "Claude",
  "icon": "🤖",
  "url": "https://claude.ai",
  "color": "#cc785c"
}
```

If `url` is present and no `index.html` exists, Trojan Horse loads the URL
directly in its WebKit view. No wrapper HTML needed. The app is just a
bookmark with a native window.

This would make Trojan Horse useful for *any* web app — not just local ones.

---

## License

MIT. The Trojan Horse wrapper is yours. Claude is Anthropic's.
