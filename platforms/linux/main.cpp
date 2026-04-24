// Trojan Horse — Linux Wrapper
// WebKitGTK + GTK3
// Build: g++ main.cpp -o trojan-horse $(pkg-config --cflags --libs webkit2gtk-4.1 gtk+-3.0) -std=c++17
// Debian/Ubuntu deps: sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <string>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <thread>
#include <vector>
#include <deque>
#include <mutex>
#include <nlohmann/json.hpp>

namespace fs = std::filesystem;
using json = nlohmann::json;

// ─── GLOBALS ──────────────────────────────────────────────────────────────────

GtkWidget* g_window = nullptr;
WebKitWebView* g_webview = nullptr;
std::string g_apps_root;
pid_t g_api_pid = -1;

// Serial state
int g_serial_fd = -1;
bool g_serial_running = false;
std::deque<std::string> g_line_queue;
std::mutex g_queue_mutex;

// ─── BRIDGE JS ────────────────────────────────────────────────────────────────

const char* BRIDGE_JS = R"JS(
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
    platform: 'linux',
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
    _onSerialBatch: function(lines) { lines.forEach(l => _serialListeners.forEach(fn => { try{fn(l);}catch(e){} })); },
    _onSerial:      function(line)  { _serialListeners.forEach(fn => { try{fn(line);}catch(e){} }); },
    _onDisconnect:  function()      { _disconnectListeners.forEach(fn => { try{fn();}catch(e){} }); },
  };
  console.log('[TROJAN HORSE] Bridge ready. Platform: linux');
})();
)JS";

// ─── HELPERS ──────────────────────────────────────────────────────────────────

void js_callback(const std::string& cb, bool is_error, const std::string& value) {
    if (cb.empty() || !g_webview) return;
    std::string js;
    if (is_error) {
        js = "window._spadraCB('" + cb + "', \"" + value + "\", null)";
    } else {
        js = "window._spadraCB('" + cb + "', null, " + value + ")";
    }
    webkit_web_view_run_javascript(g_webview, js.c_str(), nullptr, nullptr, nullptr);
}

void js_str(const std::string& cb, const std::string& s) {
    std::string escaped;
    for (char c : s) {
        if (c == '"')  escaped += "\\\"";
        else if (c == '\\') escaped += "\\\\";
        else if (c == '\n') escaped += "\\n";
        else if (c == '\r') escaped += "\\r";
        else escaped += c;
    }
    js_callback(cb, false, "\"" + escaped + "\"");
}

// ─── SERIAL (POSIX termios) ────────────────────────────────────────────────────

#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#include <dirent.h>

std::vector<std::string> list_serial_ports() {
    std::vector<std::string> ports;
    DIR* dir = opendir("/dev");
    if (!dir) return ports;
    struct dirent* ent;
    while ((ent = readdir(dir))) {
        std::string name = ent->d_name;
        if (name.find("ttyUSB") == 0 || name.find("ttyACM") == 0 ||
            name.find("ttyS") == 0) {
            ports.push_back("/dev/" + name);
        }
    }
    closedir(dir);
    std::sort(ports.begin(), ports.end());
    return ports;
}

bool open_serial(const std::string& port, int baud) {
    g_serial_fd = open(port.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (g_serial_fd < 0) return false;
    struct termios tty;
    tcgetattr(g_serial_fd, &tty);
    cfmakeraw(&tty);
    speed_t speed = B115200;
    if (baud == 9600)   speed = B9600;
    if (baud == 57600)  speed = B57600;
    if (baud == 921600) speed = B921600;
    cfsetispeed(&tty, speed);
    cfsetospeed(&tty, speed);
    tty.c_cc[VMIN]  = 1;
    tty.c_cc[VTIME] = 0;
    int flags = fcntl(g_serial_fd, F_GETFL);
    fcntl(g_serial_fd, F_SETFL, flags & ~O_NONBLOCK);
    tcsetattr(g_serial_fd, TCSANOW, &tty);
    return true;
}

// Three-layer serial pipeline
void serial_read_thread() {
    std::string buf;
    char tmp[256];
    while (g_serial_running && g_serial_fd >= 0) {
        ssize_t n = read(g_serial_fd, tmp, sizeof(tmp));
        if (n > 0) {
            buf.append(tmp, n);
            size_t pos;
            while ((pos = buf.find('\n')) != std::string::npos) {
                std::string line = buf.substr(0, pos);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                buf.erase(0, pos + 1);
                std::lock_guard<std::mutex> lock(g_queue_mutex);
                if (g_line_queue.size() < 2000) g_line_queue.push_back(line);
            }
        } else if (n == 0) {
            // disconnect
            g_serial_running = false;
            gdk_threads_add_idle([](gpointer) -> gboolean {
                webkit_web_view_run_javascript(g_webview,
                    "window.spadra._onDisconnect()", nullptr, nullptr, nullptr);
                return FALSE;
            }, nullptr);
            break;
        }
    }
}

gboolean serial_drain_timer(gpointer) {
    std::vector<std::string> lines;
    {
        std::lock_guard<std::mutex> lock(g_queue_mutex);
        while (!g_line_queue.empty()) {
            lines.push_back(g_line_queue.front());
            g_line_queue.pop_front();
        }
    }
    if (!lines.empty() && g_webview) {
        json arr = lines;
        std::string js = "window.spadra._onSerialBatch(" + arr.dump() + ")";
        webkit_web_view_run_javascript(g_webview, js.c_str(), nullptr, nullptr, nullptr);
    }
    return TRUE;
}

// ─── BRIDGE DISPATCH ──────────────────────────────────────────────────────────

void dispatch(const std::string& fn, const std::vector<std::string>& args, const std::string& cb) {
    std::thread([fn, args, cb]() {
        try {
            if (fn == "readFile") {
                std::ifstream f(args[0]);
                if (!f) throw std::runtime_error("Not found: " + args[0]);
                std::stringstream ss; ss << f.rdbuf();
                js_str(cb, ss.str());

            } else if (fn == "writeFile") {
                fs::path p(args[0]);
                fs::create_directories(p.parent_path());
                std::ofstream f(args[0]); f << args[1];
                js_callback(cb, false, "\"ok\"");

            } else if (fn == "listDir") {
                json arr = json::array();
                for (auto& e : fs::directory_iterator(args[0])) {
                    json item;
                    item["name"] = e.path().filename().string();
                    item["type"] = e.is_directory() ? "dir" : "file";
                    item["size"] = e.is_regular_file() ? (int)e.file_size() : 0;
                    arr.push_back(item);
                }
                js_callback(cb, false, arr.dump());

            } else if (fn == "deleteFile") {
                fs::remove(args[0]);
                js_callback(cb, false, "\"ok\"");

            } else if (fn == "mkdir") {
                fs::create_directories(args[0]);
                js_callback(cb, false, "\"ok\"");

            } else if (fn == "listPorts") {
                auto ports = list_serial_ports();
                js_callback(cb, false, json(ports).dump());

            } else if (fn == "openSerial") {
                int baud = args.size() > 1 ? std::stoi(args[1]) : 115200;
                if (!open_serial(args[0], baud)) throw std::runtime_error("Cannot open " + args[0]);
                g_serial_running = true;
                std::thread(serial_read_thread).detach();
                js_callback(cb, false, "\"ok\"");

            } else if (fn == "writeSerial") {
                if (g_serial_fd < 0) throw std::runtime_error("No port open");
                write(g_serial_fd, args[0].c_str(), args[0].size());
                js_callback(cb, false, "\"ok\"");

            } else if (fn == "closeSerial") {
                g_serial_running = false;
                if (g_serial_fd >= 0) { close(g_serial_fd); g_serial_fd = -1; }
                js_callback(cb, false, "\"ok\"");

            } else if (fn == "appInfo") {
                json info;
                info["platform"] = "linux";
                info["version"]  = "1.0.0";
                info["isNative"] = true;
                info["shell"]    = "trojan-horse";
                info["arch"]     = "x64";
                info["appsRoot"] = g_apps_root;
                info["app"]      = "phantom";
                js_callback(cb, false, info.dump());

            } else if (fn == "launchApp") {
                std::string path = "file://" + g_apps_root + "/" + args[0] + "/index.html";
                gdk_threads_add_idle([](gpointer data) -> gboolean {
                    auto* p = static_cast<std::string*>(data);
                    webkit_web_view_load_uri(g_webview, p->c_str());
                    delete p;
                    return FALSE;
                }, new std::string(path));
                js_callback(cb, false, "\"ok\"");

            } else if (fn == "notify") {
                std::string cmd = "notify-send \"" + (args.size()>0?args[0]:"") +
                                  "\" \"" + (args.size()>1?args[1]:"") + "\"";
                system(cmd.c_str());
                js_callback(cb, false, "\"ok\"");

            } else {
                js_callback(cb, "Unknown: " + fn, "null");
            }
        } catch (const std::exception& e) {
            js_callback(cb, e.what(), "null");
        }
    }).detach();
}

// ─── SIGNAL HANDLER ───────────────────────────────────────────────────────────

void on_message(WebKitUserContentManager*, WebKitJavascriptResult* result, gpointer) {
    JSCValue* val = webkit_javascript_result_get_js_value(result);
    char* str = jsc_value_to_string(val);
    if (!str) return;
    try {
        auto msg = json::parse(str);
        std::string fn = msg["fn"];
        std::string cb = msg.value("cb", "");
        std::vector<std::string> args;
        for (auto& a : msg["args"]) args.push_back(a.get<std::string>());

        if (fn == "setTitle") {
            gtk_window_set_title(GTK_WINDOW(g_window), args.empty() ? "" : args[0].c_str());
        } else if (fn == "exit") {
            gtk_main_quit();
        } else {
            dispatch(fn, args, cb);
        }
    } catch (...) {}
    g_free(str);
}

void start_phantom_api() {
    // Find phantom_api.py
    std::vector<std::string> candidates = {
        g_apps_root + "/../phantom_api.py",
        std::string(getenv("HOME") ? getenv("HOME") : "") + "/Developer/phantom/phantom_api.py",
    };
    std::string script;
    for (auto& c : candidates) {
        if (fs::exists(c)) { script = c; break; }
    }
    if (script.empty()) return;

    std::string scriptDir = fs::path(script).parent_path().string();
    std::string python = scriptDir + "/venv/bin/python3";
    if (!fs::exists(python)) python = "/usr/bin/python3";

    g_api_pid = fork();
    if (g_api_pid == 0) {
        chdir(scriptDir.c_str());
        execl(python.c_str(), "python3", script.c_str(), nullptr);
        exit(1);
    }
}

// ─── MAIN ─────────────────────────────────────────────────────────────────────

int main(int argc, char* argv[]) {
    gtk_init(&argc, &argv);

    // Find apps root
    char exePath[4096] = {};
    readlink("/proc/self/exe", exePath, sizeof(exePath));
    fs::path exeDir = fs::path(exePath).parent_path();
    g_apps_root = (exeDir / "apps").string();

    start_phantom_api();
    sleep(2); // Give API time to start

    // Window
    g_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(g_window), "The Phantom");
    gtk_window_set_default_size(GTK_WINDOW(g_window), 1280, 800);
    g_signal_connect(g_window, "destroy", G_CALLBACK(gtk_main_quit), nullptr);

    // WebView
    WebKitUserContentManager* manager = webkit_user_content_manager_new();
    webkit_user_content_manager_register_script_message_handler(manager, "spadra");
    g_signal_connect(manager, "script-message-received::spadra", G_CALLBACK(on_message), nullptr);

    WebKitUserScript* script = webkit_user_script_new(
        BRIDGE_JS, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, nullptr, nullptr);
    webkit_user_content_manager_add_script(manager, script);

    g_webview = WEBKIT_WEB_VIEW(webkit_web_view_new_with_user_content_manager(manager));
    gtk_container_add(GTK_CONTAINER(g_window), GTK_WIDGET(g_webview));

    // Load app
    std::string appPath = g_apps_root + "/phantom/index.html";
    if (fs::exists(appPath)) {
        webkit_web_view_load_uri(g_webview, ("file://" + appPath).c_str());
    } else {
        webkit_web_view_load_uri(g_webview, "http://localhost:8000/apps/phantom/");
    }

    // Serial drain timer (16ms = 60fps)
    g_timeout_add(16, serial_drain_timer, nullptr);

    gtk_widget_show_all(g_window);
    gtk_main();

    if (g_api_pid > 0) kill(g_api_pid, SIGTERM);
    return 0;
}
