import Cocoa
import WebKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    var webView: WKWebView!
    var bridgeHandler: BridgeHandler!
    var apiProcess: Process?
    var apiReady = false
    var startupTimer: Timer?
    var retryCount = 0

    // ── App Launch ────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildWebView()
        showSplash()
        startPhantomAPI()
    }

    // ── Window ────────────────────────────────────────────────────────────

    func buildWindow() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let winRect = NSRect(
            x: screen.midX - 640,
            y: screen.midY - 400,
            width: 1280,
            height: 800
        )
        window = NSWindow(
            contentRect: winRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "The Phantom"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 900, height: 600)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── WebView ───────────────────────────────────────────────────────────

    func buildWebView() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()

        bridgeHandler = BridgeHandler()
        userContent.add(bridgeHandler, name: "spadra")

        let userScript = WKUserScript(
            source: bridgeJS(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContent.addUserScript(userScript)
        config.userContentController = userContent
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = bridgeHandler
        bridgeHandler.webView = webView
        bridgeHandler.window = window

        window.contentView = webView
    }

    // ── Splash Screen (shown while API boots) ─────────────────────────────

    func showSplash() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          body {
            background: #080c10;
            color: #c8d8e8;
            font-family: 'Courier New', monospace;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            height: 100vh;
            gap: 24px;
          }
          h1 { font-size: 2em; color: #e05a00; letter-spacing: 6px; }
          #msg { font-size: 0.75em; color: #4a6070; letter-spacing: 2px; }
          .dot { animation: blink 1.2s infinite; }
          .dot:nth-child(2) { animation-delay: 0.2s; }
          .dot:nth-child(3) { animation-delay: 0.4s; }
          @keyframes blink { 0%,100%{opacity:0.2} 50%{opacity:1} }
        </style>
        </head>
        <body>
          <h1>👻 THE PHANTOM</h1>
          <div id="msg">
            STARTING ENGINE
            <span class="dot">.</span>
            <span class="dot">.</span>
            <span class="dot">.</span>
          </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // ── API Process Management ─────────────────────────────────────────────

    func startPhantomAPI() {
        // Find python3 and phantom_api.py relative to the app bundle
        let bundle = Bundle.main
        let resourcePath = bundle.resourcePath ?? ""

        // Candidate locations for phantom_api.py
        let appDir = bundle.bundleURL
            .deletingLastPathComponent()  // MacOS/
            .deletingLastPathComponent()  // Contents/
            .deletingLastPathComponent()  // .app/
            .path

        let candidates = [
            "\(resourcePath)/phantom_api.py",
            "\(appDir)/phantom_api.py",
            "\(FileManager.default.currentDirectoryPath)/phantom_api.py",
            "\(NSHomeDirectory())/Developer/phantom/phantom_api.py",
        ]

        guard let apiScript = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            showError("Cannot find phantom_api.py.\nExpected next to TrojanHorse.app or in ~/Developer/phantom/")
            return
        }

        let scriptDir = (apiScript as NSString).deletingLastPathComponent

        // Find python3 in venv first, then system
        let pythonCandidates = [
            "\(scriptDir)/venv/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]

        guard let python = pythonCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            showError("Cannot find python3.\nInstall Python 3 via Homebrew: brew install python")
            return
        }

        // Launch the API server
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [apiScript]
        process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PHANTOM_PORT": "8000",
            "PYTHONUNBUFFERED": "1",
        ]) { _, new in new }

        // Pipe output to console (visible in Xcode debug area)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                NSLog("[Phantom API] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if proc.terminationStatus != 0 {
                    self?.showError("The Phantom API crashed (exit \(proc.terminationStatus)).\nCheck Console.app for details.")
                }
            }
        }

        do {
            try process.run()
            apiProcess = process
            NSLog("[TrojanHorse] API started (PID %d)", process.processIdentifier)
            waitForAPI()
        } catch {
            showError("Failed to start phantom_api.py:\n\(error.localizedDescription)")
        }
    }

    // ── Wait for API to become ready ──────────────────────────────────────

    func waitForAPI() {
        retryCount = 0
        startupTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.pingAPI { ready in
                if ready {
                    timer.invalidate()
                    self.loadApp()
                } else {
                    self.retryCount += 1
                    if self.retryCount > 30 {   // 12 seconds max
                        timer.invalidate()
                        self.showError("The Phantom API failed to start after 12 seconds.\nCheck that all dependencies are installed:\n  pip install fastapi uvicorn")
                    }
                }
            }
        }
    }

    func pingAPI(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://localhost:8000/api/status") else {
            completion(false); return
        }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                completion(ok)
            }
        }
        task.resume()
    }

    // ── Load the actual app once API is up ────────────────────────────────

    func loadApp() {
        NSLog("[TrojanHorse] API ready. Loading app.")

        // Try local file first (fastest, no HTTP round-trip for assets)
        let bundle = Bundle.main
        let resourcePath = bundle.resourcePath ?? ""
        let appDir = bundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path

        let localCandidates = [
            "\(resourcePath)/apps/phantom/index.html",
            "\(appDir)/apps/phantom/index.html",
            "\(NSHomeDirectory())/Developer/phantom/apps/phantom/index.html",
        ]

        if let localPath = localCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let url = URL(fileURLWithPath: localPath)
            bridgeHandler.appsRoot = url
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            webView.loadFileURL(
                url,
                allowingReadAccessTo: url
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        } else {
            // Fall back to API-served version
            if let url = URL(string: "http://localhost:8000/apps/phantom/") {
                webView.load(URLRequest(url: url))
            }
        }
    }

    // ── Error Display ─────────────────────────────────────────────────────

    func showError(_ message: String) {
        let safe = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")

        let html = """
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          body {
            background:#080c10; color:#c8d8e8;
            font-family:'Courier New',monospace;
            display:flex; flex-direction:column;
            align-items:center; justify-content:center;
            height:100vh; gap:20px; padding:40px; text-align:center;
          }
          h1 { color:#c0392b; font-size:1.2em; letter-spacing:3px; }
          p { color:#7a9ab0; font-size:0.8em; line-height:1.8; max-width:500px; }
          code { color:#e05a00; }
        </style></head><body>
          <h1>⚠ STARTUP ERROR</h1>
          <p>\(safe.replacingOccurrences(of: "\n", with: "<br>"))</p>
        </body></html>
        """
        DispatchQueue.main.async {
            self.webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // ── Teardown ──────────────────────────────────────────────────────────

    func applicationWillTerminate(_ notification: Notification) {
        startupTimer?.invalidate()
        bridgeHandler?.cleanup()

        // Cleanly terminate the API process
        if let proc = apiProcess, proc.isRunning {
            NSLog("[TrojanHorse] Stopping Phantom API (PID %d)", proc.processIdentifier)
            proc.terminate()
            proc.waitUntilExit()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        return true
    }

    // ── Bridge JS ─────────────────────────────────────────────────────────

    func bridgeJS() -> String {
        return """
        (function() {
          'use strict';
          if (window.spadra) return;

          const _pending = {};
          let _cbCounter = 0;
          const _serialListeners = [];
          const _disconnectListeners = [];

          window._spadraCB = function(id, err, result) {
            const p = _pending[id];
            if (!p) return;
            delete _pending[id];
            if (err) p.reject(new Error(err));
            else     p.resolve(result);
          };

          function _call(fn, ...args) {
            return new Promise((resolve, reject) => {
              const cb = 'cb_' + (++_cbCounter);
              _pending[cb] = { resolve, reject };
              window.webkit.messageHandlers.spadra.postMessage(
                JSON.stringify({ fn, args: args.map(a => String(a ?? '')), cb })
              );
            });
          }

          window.spadra = {
            isNative: true,
            platform: 'macos',
            version:  '1.0.0',

            readFile:    (path)          => _call('readFile', path),
            writeFile:   (path, content) => _call('writeFile', path, content),
            listDir:     (path)          => _call('listDir', path).then(JSON.parse),
            deleteFile:  (path)          => _call('deleteFile', path),
            mkdir:       (path)          => _call('mkdir', path),

            listPorts:   ()              => _call('listPorts').then(JSON.parse),
            openSerial:  (port, baud)    => _call('openSerial', port, String(baud)),
            writeSerial: (data)          => _call('writeSerial', data),
            closeSerial: ()              => _call('closeSerial'),
            onSerial:    (fn)            => { _serialListeners.push(fn); },
            onDisconnect:(fn)            => { _disconnectListeners.push(fn); },

            appInfo:     ()              => _call('appInfo').then(JSON.parse),
            launchApp:   (name)          => _call('launchApp', name),
            setTitle:    (title)         => {
              window.webkit.messageHandlers.spadra.postMessage(
                JSON.stringify({ fn:'setTitle', args:[title], cb:'' })
              );
            },
            notify:      (t, b)          => _call('notify', t, b),
            exit:        ()              => {
              window.webkit.messageHandlers.spadra.postMessage(
                JSON.stringify({ fn:'exit', args:[], cb:'' })
              );
            },

            _onSerialBatch: function(lines) {
              for (let i = 0; i < lines.length; i++) {
                const line = lines[i];
                _serialListeners.forEach(fn => { try { fn(line); } catch(e){} });
              }
            },
            _onSerial: function(line) {
              _serialListeners.forEach(fn => { try { fn(line); } catch(e){} });
            },
            _onDisconnect: function() {
              _disconnectListeners.forEach(fn => { try { fn(); } catch(e){} });
            },
          };

          console.log('[TROJAN HORSE] Bridge ready. Platform: macos');
        })();
        """
    }
}
