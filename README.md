# Trojan Horse

> A lightweight native application wrapper that gives HTML/JS apps direct
> access to the OS — without Electron's 200MB bloat, without an App Store,
> without Node.js.

---

## What It Is

Trojan Horse is a native shell that wraps web apps (HTML + CSS + JS) into
platform-native desktop applications. The web app is **identical on every
platform** — only the wrapper (~500 lines of native code per platform) changes.

```
[Native wrapper]  →  [WebKit/WebView]  →  [HTML/JS app]
                             ↑
                   window.spadra.* bridge
                   injected before page loads
```

The bridge gives your web app direct access to:
- The local filesystem (read, write, list, delete)
- Serial ports / hardware (Arduino, ESP32, T-Deck, etc.)
- OS notifications
- App launching
- Window title control

---

## Platforms

| Platform | Language | Engine       | Status |
|----------|----------|--------------|--------|
| macOS    | Swift    | WKWebView    | ✅ Built |
| Linux    | C++17    | WebKitGTK    | ✅ Built |
| Windows  | C++17    | WebView2     | ✅ Built |
| Android  | Kotlin   | android WebView | ✅ Companion mode |
| iOS      | Swift    | WKWebView    | ✅ Companion mode |

---

## Quick Start — Ubuntu / Debian Linux

### 1. Install dependencies

```bash
sudo apt install \
  libwebkit2gtk-4.1-dev \
  libgtk-3-dev \
  nlohmann-json3-dev \
  build-essential \
  pkg-config
```

### 2. Compile

```bash
g++ platforms/linux/main.cpp -o trojan-horse \
  $(pkg-config --cflags --libs webkit2gtk-4.1 gtk+-3.0) \
  -std=c++17 -lpthread
```

### 3. Set up your app directory

Place apps next to the binary:

```
trojan-horse
apps/
  home/
    index.html
    app.json
  claude/
    index.html
    app.json
  ghost_partition/
    index.html
    app.json
  wardrive_splitter/
    index.html
    app.json
phantom_api.py        ← if using Pisces Moon backend
venv/                 ← Python virtualenv (optional)
```

### 4. Run

```bash
./trojan-horse
```

The Home launcher appears. Click any tile to launch an app.

---

## Quick Start — macOS

Open `platforms/macos/` in Xcode. Build and run. The Swift source files are:

- `AppDelegate.swift` — window, WebView, API process management
- `BridgeHandler.swift` — native bridge dispatch
- `SerialManager.swift` — serial port I/O pipeline

---

## Included Apps

### 🏠 Home (`apps/home/`)
The app launcher. Reads `apps/*/app.json` and renders a tile grid.
This is the default app loaded on startup.

### 🤖 Claude (`apps/claude/`)
A native desktop wrapper for [claude.ai](https://claude.ai).
Gives Ubuntu/Linux users a native Claude desktop app since no official
Linux client exists. Loads claude.ai directly in WebKit with persistent
login. See `apps/claude/README.md` for the direct-load patch (recommended).

**License note:** The Trojan Horse wrapper is MIT/AGPL-3.0. Claude itself
is Anthropic's service — your use is governed by Anthropic's Terms of
Service as normal. This wrapper is equivalent to a browser bookmark with
a native window.

### 🌙 Ghost Partition (`apps/ghost_partition/`)
SD card formatter and partition manager for Pisces Moon OS.
Creates a dual FAT32 layout with a hidden "Ghost Partition" accessible
to the T-Deck but invisible to consumer operating systems via MBR
byte-flip stealth. Requires `phantom_api.py` for format/stealth operations.

Backend: `ghost_partition_tool.py` + `ghost_partition_gui.py`

### 🛰 Wardrive Splitter (`apps/wardrive_splitter/`)
Splits large WiGLE-format wardrive CSV files into Smelter-ready chunks.
Runs entirely in-browser — no backend needed. Supports split by row count,
date, session, geographic grid, or filter-only mode. Full dedup and RSSI
filtering pipeline.

Backend: `wardrive_splitter.py` (Python CLI version also included)

---

## Writing Your Own App

An app is a folder containing at minimum:

**`app.json`**
```json
{
  "name": "My App",
  "description": "What it does",
  "icon": "🚀",
  "version": "1.0.0",
  "color": "#ff6600"
}
```

**`index.html`** — your entire app. HTML + CSS + JS, all in one file.

### URL-type apps (web wrappers)

To wrap an external URL, add a `"url"` field to `app.json`:
```json
{
  "name": "Claude",
  "icon": "🤖",
  "url": "https://claude.ai",
  "color": "#cc785c"
}
```
*(Requires the URL-app patch to the native wrapper — see `apps/claude/README.md`)*

---

## The Bridge API (`window.spadra.*`)

All methods return a Promise unless noted.

```javascript
// Detection
window.spadra.isNative        // true when running in Trojan Horse
window.spadra.platform        // "macos" | "linux" | "windows"
window.spadra.version         // "1.0.0"

// File System
window.spadra.readFile(path)            → Promise<string>
window.spadra.writeFile(path, content)  → Promise<"ok">
window.spadra.listDir(path)             → Promise<Array<{name, type, size}>>
window.spadra.deleteFile(path)          → Promise<"ok">
window.spadra.mkdir(path)               → Promise<"ok">

// Serial / Hardware
window.spadra.listPorts()               → Promise<string[]>
window.spadra.openSerial(port, baud)    → Promise<"ok">
window.spadra.writeSerial(data)         → Promise<"ok">
window.spadra.closeSerial()             → Promise<"ok">
window.spadra.onSerial(callback)        → void
window.spadra.onDisconnect(callback)    → void

// System
window.spadra.appInfo()                 → Promise<{platform, version, appsRoot, ...}>
window.spadra.launchApp(name)           → Promise<"ok">
window.spadra.setTitle(title)           → void  (fire-and-forget)
window.spadra.notify(title, body)       → Promise<"ok">
window.spadra.exit()                    → void  (fire-and-forget)
```

### Graceful degradation

Always check `window.spadra?.isNative` before using bridge calls.
Apps should fall back to browser-compatible behavior when running outside
the wrapper (e.g. file downloads instead of `writeFile`, no serial access):

```javascript
if (window.spadra?.isNative) {
  await window.spadra.writeFile(path, content);
} else {
  // Browser fallback
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([content]));
  a.download = filename;
  a.click();
}
```

---

## Directory Structure

```
trojan-horse/
├── README.md                    ← this file
├── platforms/
│   ├── linux/
│   │   ├── main.cpp             ← Linux wrapper (C++17 / WebKitGTK)
│   │   └── BUILD.md             ← Linux build instructions
│   └── macos/
│       ├── AppDelegate.swift    ← macOS app delegate
│       ├── BridgeHandler.swift  ← native bridge
│       ├── SerialManager.swift  ← serial port manager
│       └── Info.plist           ← macOS app metadata
├── apps/
│   ├── home/                    ← launcher (default app)
│   ├── claude/                  ← Claude AI desktop wrapper
│   ├── ghost_partition/         ← SD card partition manager
│   └── wardrive_splitter/       ← WiGLE CSV splitter
├── ghost_partition_tool.py      ← Ghost Partition CLI backend
├── ghost_partition_gui.py       ← Ghost Partition CustomTkinter GUI
└── wardrive_splitter.py         ← Wardrive splitter CLI
```

---

## License

Trojan Horse is licensed under the **GNU Affero General Public License v3.0
(AGPL-3.0)** with a **Contributor License Agreement (CLA)**.

**AGPL-3.0** means:
- You can use, modify, and distribute this software freely
- If you modify it and run it as a network service, you must release
  your modifications under the same license
- You must include the license and copyright notice in all copies

**CLA** means:
- Contributors grant the project maintainer the right to relicense
  contributions (e.g. for commercial licensing arrangements)
- This protects the ability to dual-license the project if needed

The full license text is available at:
https://www.gnu.org/licenses/agpl-3.0.txt

To obtain the LICENSE file:
```bash
wget https://www.gnu.org/licenses/agpl-3.0.txt -O LICENSE
```

**Included apps and tools** (Ghost Partition, Wardrive Splitter, Claude wrapper)
are also AGPL-3.0 unless otherwise noted in their respective directories.

**Claude itself** is not part of this project. Use of claude.ai is governed
by Anthropic's Terms of Service: https://www.anthropic.com/legal/terms

---

## Contributing

Pull requests welcome. By submitting a PR you agree to the CLA —
your contribution may be relicensed by the project maintainer under
terms compatible with AGPL-3.0.

---

*Trojan Horse — Your machine, your rules.*
*A Fluid Fortune project. v0.1.0-alpha*
