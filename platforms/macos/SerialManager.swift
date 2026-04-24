import Foundation
import WebKit

class SerialManager {

    private var fd: Int32 = -1
    private var readThread: Thread?
    private var running = false
    private let queue = DispatchQueue(label: "serial.line.queue")
    private var lineBuffer: [String] = []
    private var timer: Timer?
    private weak var webView: WKWebView?
    private var byteBuffer = Data()

    // ── Port Listing ──────────────────────────────────────────────────────

    static func listPorts() -> [String] {
        let fm = FileManager.default
        let devs = (try? fm.contentsOfDirectory(atPath: "/dev")) ?? []
        let prefixes = ["cu.usbmodem", "cu.usbserial", "cu.wchusbserial",
                        "cu.SLAB_USBtoUART", "cu.usbmodem"]
        return devs
            .filter { name in prefixes.contains(where: { name.hasPrefix($0) }) }
            .map { "/dev/\($0)" }
            .sorted()
    }

    // ── Open / Close ──────────────────────────────────────────────────────

    func open(port: String, baud: Int32) throws {
        fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw BErr("Cannot open port \(port): \(String(cString: strerror(errno)))")
        }

        var tty = termios()
        tcgetattr(fd, &tty)
        cfmakeraw(&tty)
        cfsetispeed(&tty, speed_t(baud))
        cfsetospeed(&tty, speed_t(baud))
        tty.c_cc.16 = 1   // VMIN
        tty.c_cc.17 = 0   // VTIME
        tcsetattr(fd, TCSANOW, &tty)
        // Set blocking mode
        let flags = fcntl(fd, F_GETFL)
        fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }

    func close() {
        running = false
        timer?.invalidate()
        timer = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    func write(_ s: String) throws {
        guard fd >= 0 else { throw BErr("Port not open") }
        guard let data = s.data(using: .utf8) else { throw BErr("Encode error") }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        if written < 0 {
            throw BErr("Write error: \(String(cString: strerror(errno)))")
        }
    }

    // ── Three-Layer Read Pipeline ─────────────────────────────────────────
    // Layer 1: background thread reads bytes, assembles lines
    // Layer 2: thread-safe line queue (capped at 2000)
    // Layer 3: 16ms timer on main thread drains queue in one JS call

    func startReading(webView: WKWebView?) {
        self.webView = webView
        running = true

        // Layer 1: background read thread
        readThread = Thread {
            var buf = [UInt8](repeating: 0, count: 256)
            while self.running && self.fd >= 0 {
                let n = Darwin.read(self.fd, &buf, buf.count)
                if n > 0 {
                    self.byteBuffer.append(contentsOf: buf[..<n])
                    self.drainLines()
                } else if n == 0 {
                    // EOF / disconnect
                    self.handleDisconnect()
                    break
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        Thread.sleep(forTimeInterval: 0.001)
                        continue
                    }
                    break
                }
            }
        }
        readThread?.qualityOfService = .userInteractive
        readThread?.start()

        // Layer 3: 16ms drain timer on main thread
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
                self.flushToJS()
            }
        }
    }

    // Layer 1 helper: split byte buffer on newlines → push to queue
    private func drainLines() {
        while let idx = byteBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = byteBuffer[byteBuffer.startIndex..<idx]
            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                queue.sync {
                    if self.lineBuffer.count < 2000 {
                        self.lineBuffer.append(line)
                    }
                }
            }
            byteBuffer.removeSubrange(byteBuffer.startIndex...idx)
        }
    }

    // Layer 3: drain queue → single JS call
    private func flushToJS() {
        var lines: [String] = []
        queue.sync {
            lines = self.lineBuffer
            self.lineBuffer.removeAll(keepingCapacity: true)
        }
        guard !lines.isEmpty, let wv = webView else { return }
        do {
            let json = try JSONSerialization.data(withJSONObject: lines)
            let jsonStr = String(data: json, encoding: .utf8) ?? "[]"
            wv.evaluateJavaScript("window.spadra._onSerialBatch(\(jsonStr))", completionHandler: nil)
        } catch {}
    }

    private func handleDisconnect() {
        running = false
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("window.spadra._onDisconnect()", completionHandler: nil)
        }
    }
}
