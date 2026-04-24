import Cocoa
import WebKit
import UserNotifications

class BridgeHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    weak var webView: WKWebView?
    weak var window: NSWindow?
    var appsRoot: String = ""
    var serialManager: SerialManager?

    // ── WKScriptMessageHandler ─────────────────────────────────────────────

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let msg  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fn   = msg["fn"] as? String
        else { return }

        let args = msg["args"] as? [String] ?? []
        let cb   = msg["cb"]   as? String   ?? ""

        // Fire-and-forget calls (no callback)
        if cb.isEmpty {
            switch fn {
            case "setTitle":
                DispatchQueue.main.async { self.window?.title = args.first ?? "" }
            case "exit":
                DispatchQueue.main.async { NSApp.terminate(nil) }
            default: break
            }
            return
        }

        // Dispatch to handlers
        DispatchQueue.global(qos: .userInitiated).async {
            self.dispatch(fn: fn, args: args, cb: cb)
        }
    }

    func dispatch(fn: String, args: [String], cb: String) {
        do {
            switch fn {
            case "readFile":
                guard let path = args.first else { throw BErr("readFile: missing path") }
                let content = try String(contentsOfFile: path, encoding: .utf8)
                callback(cb, result: self.jsStr(content))

            case "writeFile":
                guard args.count >= 2 else { throw BErr("writeFile: missing args") }
                let path = args[0], content = args[1]
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                callback(cb, result: "\"ok\"")

            case "listDir":
                guard let path = args.first else { throw BErr("listDir: missing path") }
                let entries = try Self.listDirectory(path: path)
                let json = try JSONSerialization.data(withJSONObject: entries)
                callback(cb, result: String(data: json, encoding: .utf8) ?? "[]")

            case "deleteFile":
                guard let path = args.first else { throw BErr("deleteFile: missing path") }
                try FileManager.default.removeItem(atPath: path)
                callback(cb, result: "\"ok\"")

            case "mkdir":
                guard let path = args.first else { throw BErr("mkdir: missing path") }
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                callback(cb, result: "\"ok\"")

            case "listPorts":
                let ports = SerialManager.listPorts()
                let json = try JSONSerialization.data(withJSONObject: ports)
                callback(cb, result: String(data: json, encoding: .utf8) ?? "[]")

            case "openSerial":
                guard args.count >= 2 else { throw BErr("openSerial: missing args") }
                let port = args[0]
                let baud = Int32(args[1]) ?? 115200
                serialManager = SerialManager()
                try serialManager!.open(port: port, baud: baud)
                serialManager!.startReading(webView: webView)
                callback(cb, result: "\"ok\"")

            case "writeSerial":
                guard let data = args.first, let sm = serialManager else {
                    throw BErr("writeSerial: no open port")
                }
                try sm.write(data)
                callback(cb, result: "\"ok\"")

            case "closeSerial":
                serialManager?.close()
                serialManager = nil
                callback(cb, result: "\"ok\"")

            case "appInfo":
                let info: [String: Any] = [
                    "platform": "macos",
                    "version":  "1.0.0",
                    "isNative": true,
                    "shell":    "trojan-horse",
                    "arch":     "arm64",
                    "appsRoot": self.appsRoot,
                    "app":      "phantom",
                ]
                let json = try JSONSerialization.data(withJSONObject: info)
                callback(cb, result: String(data: json, encoding: .utf8) ?? "{}")

            case "launchApp":
                guard let name = args.first else { throw BErr("launchApp: missing name") }
                let newPath = "\(self.appsRoot)/\(name)/index.html"
                let url = URL(fileURLWithPath: newPath)
                DispatchQueue.main.async {
                    self.webView?.loadFileURL(
                        url,
                        allowingReadAccessTo: url.deletingLastPathComponent().deletingLastPathComponent()
                    )
                }
                callback(cb, result: "\"ok\"")

            case "notify":
                let title = args.count > 0 ? args[0] : "The Phantom"
                let body  = args.count > 1 ? args[1] : ""
                Self.sendNotification(title: title, body: body)
                callback(cb, result: "\"ok\"")

            default:
                throw BErr("Unknown function: \(fn)")
            }
        } catch {
            callbackError(cb, error: error.localizedDescription)
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    func callback(_ cb: String, result: String) {
        let js = "window._spadraCB('\(cb)', null, \(result))"
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func callbackError(_ cb: String, error: String) {
        let escaped = error.replacingOccurrences(of: "\"", with: "\\\"")
        let js = "window._spadraCB('\(cb)', \"\(escaped)\", null)"
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func jsStr(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    static func listDirectory(path: String) throws -> [[String: Any]] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: path)
        return contents.compactMap { name -> [String: Any]? in
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            var size = 0
            if !isDir.boolValue,
               let attrs = try? fm.attributesOfItem(atPath: full) {
                size = (attrs[.size] as? Int) ?? 0
            }
            return [
                "name": name,
                "type": isDir.boolValue ? "dir" : "file",
                "size": size,
            ]
        }
    }

    static func sendNotification(title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body  = body
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }
    }

    // ── WKNavigationDelegate ───────────────────────────────────────────────

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Update window title from page title
        if let title = webView.title, !title.isEmpty {
            window?.title = title
        }
    }

    func cleanup() {
        serialManager?.close()
    }
}

// ── Error Helper ──────────────────────────────────────────────────────────────

struct BErr: Error, LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}
