import AppKit
import Carbon.HIToolbox
import CryptoKit
import Network
import WebKit

/// English literals are the fallback when no localization is available.
private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// A JSON string literal keeps translations safe inside the page user script.
private func jsString(_ value: String) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

/// One always-on-top window per window id.
final class Slot {
    let id: String
    let window: NSWindow
    let webView: WKWebView
    let owner: String
    let profile: String?
    var urlString: String
    var pageTitle: String
    var fit: Bool
    var mobile: Bool
    var naturalWidth: Double
    /// Set by ⌘+/⌘-/⌘0; overrides auto-fit until "Fit to Width" is used.
    var manualZoom: Double?
    /// False hides the 28pt drag strip so the top area receives page events
    /// (toggle from the context menu; ⌥-drag still moves the window).
    var dragBarEnabled: Bool
    /// Non-nil while the last navigation failed (DNS, refused, missing file…).
    /// Rendered as a native overlay; surfaced in state.json so agents can see
    /// the failure instead of staring at a blank window.
    var loadError: String?
    /// The native overlay shown while `loadError != nil`.
    var errorOverlay: NSView?

    init(
        id: String,
        window: NSWindow,
        webView: WKWebView,
        owner: String,
        profile: String?,
        urlString: String,
        fit: Bool,
        mobile: Bool,
        dragBarEnabled: Bool = true
    ) {
        self.id = id
        self.window = window
        self.webView = webView
        self.owner = owner
        self.profile = profile
        self.urlString = urlString
        self.pageTitle = ""
        self.fit = fit
        self.mobile = mobile
        self.naturalWidth = 0
        self.manualZoom = nil
        self.dragBarEnabled = dragBarEnabled
        self.loadError = nil
        self.errorOverlay = nil
    }
}

private let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

/// WKWebView's default UA omits the "Safari" token, so some sites (e.g. Baidu
/// desktop) serve an empty anti-bot page. Use a regular Safari UA instead.
private let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

/// A WKWebView that lets the user move its window: hold Option (⌥) and drag
/// anywhere on the page. Plain drags go to the page as usual.
final class DraggableWebView: WKWebView {
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), let window {
            window.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

/// Transparent strip pinned to the top of the window. It exists so that
/// dragging the (invisible) title bar area is reliable: with a full-size
/// WKWebView the title bar's own hit region is inconsistent.
final class DragBarView: NSView {
    static let height: CGFloat = 28

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// Static HTTP server for local directories (127.0.0.1 only). Lets pages in
/// arowser windows use fetch/XHR — WebKit treats file:// pages as opaque
/// origins and blocks all of those. Mounts and the port persist in
/// serve.json so URLs survive app restarts; the listener dies with the app
/// (same lifecycle as the windows themselves).
///
/// Threading: all mutable state is guarded by `lock`; listener callbacks run
/// on `queue`. Never call `locked` while holding the lock.
final class DirServer {
    static let shared = DirServer()
    private let queue = DispatchQueue(label: "arowser.serve")
    private let lock = NSLock()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var preferredPort: UInt16 = 8977
    /// mount id -> absolute directory path (standardized).
    private var mounts: [String: String] = [:]
    private var configURL: URL?
    private let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8", "geojson": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp",
        "ico": "image/x-icon", "bmp": "image/bmp", "avif": "image/avif",
        "txt": "text/plain; charset=utf-8", "md": "text/plain; charset=utf-8",
        "log": "text/plain; charset=utf-8",
        "csv": "text/csv; charset=utf-8", "tsv": "text/tab-separated-values",
        "xml": "application/xml", "pdf": "application/pdf",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "mp4": "video/mp4", "webm": "video/webm", "mp3": "audio/mpeg",
        "wav": "audio/wav", "wasm": "application/wasm",
    ]

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Loads serve.json (port + mounts). Call once at app start.
    func restore(configDir: URL) {
        let url = configDir.appendingPathComponent("serve.json")
        let loaded: [String: Any]? = {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }()
        var restoredMounts: [String: String] = [:]
        locked {
            configURL = url
            if let p = loaded?["port"] as? Int, p > 0, p < 65536 { preferredPort = UInt16(p) }
            if let m = loaded?["mounts"] as? [String: String] { mounts = m; restoredMounts = m }
        }
        // Start listening as soon as any mount is restored: restored windows
        // load http://127.0.0.1:<port>/<id>/ URLs directly, and nothing else
        // would bring the listener up (the serve ACTION is lazy). Without
        // this, a restart + `show` of a served page hits ECONNREFUSED
        // (NSURLErrorDomain -1004, seen with a served dashboard 2026-11-12).
        if !restoredMounts.isEmpty {
            ensureRunning()
        }
    }

    /// Default serve.json location (Application Support/arowser).
    private func applicationSupportDefault() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("arowser", isDirectory: true)
            .appendingPathComponent("serve.json")
    }

    private func persistLocked() {
        guard let configURL else { return }
        let obj: [String: Any] = [
            "port": Int(port == 0 ? preferredPort : port),
            "mounts": mounts,
        ]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return }
        do {
            try data.write(to: configURL, options: .atomic)
        } catch {
            // Serve persistence is best-effort; mounts still work this run.
        }
    }

    /// Starts the listener if it isn't running. Binds 127.0.0.1 only, on the
    /// preferred port; if that port is taken, rebinds on an ephemeral port
    /// (recorded so `serve.json` self-corrects for next boot).
    func ensureRunning() {
        let shouldStart: Bool = locked {
            if listener != nil { return false }
            let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: preferredPort) ?? .any
            )
            guard let listener = try? NWListener(using: params) else { return false }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.locked {
                        if let p = listener.port?.rawValue, p != 0 {
                            self.port = p
                            self.preferredPort = p
                        }
                        self.persistLocked()
                    }
                case .failed:
                    let rebind: Bool = self.locked {
                        guard listener === self.listener, self.preferredPort != 0 else { return false }
                        self.preferredPort = 0
                        self.listener = nil
                        return true
                    }
                    if rebind {
                        listener.cancel()
                        self.ensureRunning()
                    }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
            return true
        }
        _ = shouldStart
    }

    /// Registers a directory; idempotent per directory. Returns the mount id
    /// (differs from the request on collision) and the full URL. Waits briefly
    /// for the listener to report its bound port.
    func mount(_ dir: String, requestedID: String?) -> (id: String, url: String)? {
        // Self-heal if restore hasn't run yet (cold-start URL dispatch can
        // beat didFinishLaunching; see applicationWillFinishLaunching).
        if configURL == nil {
            locked { configURL = applicationSupportDefault() }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        let abs = URL(fileURLWithPath: dir).standardizedFileURL.path
        let result: (String, UInt16) = locked {
            if let existing = mounts.first(where: { $0.value == abs })?.key {
                return (existing, port)
            }
            let base = sanitizeID(
                (requestedID?.isEmpty == false) ? requestedID! : URL(fileURLWithPath: abs).lastPathComponent
            ) + "-" + suffix(of: abs)
            var id = base
            var n = 2
            while mounts[id] != nil { id = "\(base)-\(n)"; n += 1 }
            mounts[id] = abs
            return (id, port)
        }
        ensureRunning()
        // Port arrives asynchronously via .ready (always for ephemeral binds,
        // effectively immediately for explicit binds).
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            let p = locked { port }
            if p != 0 { return (result.0, "http://127.0.0.1:\(p)/\(result.0)/") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    /// Serve-mount URL for an already-registered mount id (used when the CLI
    /// resolves an `open <dir> --serve` whose dir was mounted before).
    func url(forMountID id: String) -> String? {
        locked {
            guard mounts[id] != nil, port != 0 else { return nil }
            return "http://127.0.0.1:\(port)/\(id)/"
        }
    }

    var mountList: [String: String] { locked { mounts } }

    private func sanitizeID(_ raw: String) -> String {
        let cleaned = raw.map { c -> Character in
            (c.isLetter || c.isNumber || c == "-" || c == "_") ? c : "-"
        }.prefix(40)
        return cleaned.isEmpty ? "dir" : String(cleaned)
    }

    /// Short stable suffix (FNV-1a) so same-named dirs from different
    /// parents get distinct mount ids.
    private func suffix(of path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in path.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%04x", UInt32(truncatingIfNeeded: hash & 0xffff))
    }

    // MARK: HTTP

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf += data }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(conn, requestHead: String(data: buf[..<range.lowerBound], encoding: .utf8) ?? "")
                return
            }
            if error == nil, !done, buf.count < 16384 {
                self.receiveRequest(conn, buffer: buf)
            } else {
                conn.cancel()
            }
        }
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let lines = requestHead.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return fail(conn, 400, "bad request") }
        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])
        guard method == "GET" || method == "HEAD" else { return fail(conn, 405, "method not allowed") }

        // DNS-rebinding protection: only localhost origins may talk to us.
        let portNow = locked { port }
        var host = ""
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("host:") { host = lower.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        }
        let hostOK = host == "127.0.0.1" || host == "localhost"
            || host == "127.0.0.1:\(portNow)" || host == "localhost:\(portNow)"
        guard hostOK else { return fail(conn, 403, "forbidden host") }

        let pathOnly = rawPath.split(separator: "?")[0].split(separator: "#")[0]
        guard let decoded = String(pathOnly).removingPercentEncoding else {
            return fail(conn, 400, "bad encoding")
        }
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let mountID = segments.first,
              let root = locked({ mounts[mountID] })
        else { return fail(conn, 404, "not found") }
        var target = URL(fileURLWithPath: root)
        for seg in segments.dropFirst() where seg != "." { target.appendPathComponent(seg) }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            return fail(conn, 404, "not found")
        }
        if isDir.boolValue { target.appendPathComponent("index.html") }
        guard FileManager.default.fileExists(atPath: target.path)
        else { return fail(conn, 404, "not found") }

        // `..` segments and symlinks must not escape the mounted root.
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let resolved = target.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(resolvedRoot + "/")
        else { return fail(conn, 403, "path escapes mount") }

        guard let data = try? Data(contentsOf: target) else { return fail(conn, 404, "not found") }
        let ext = target.pathExtension.lowercased()
        let type = mimeTypes[ext] ?? "application/octet-stream"
        var head = "HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\n"
        head += "Content-Type: \(type)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + (method == "HEAD" ? Data() : data), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func fail(_ conn: NWConnection, _ status: Int, _ reason: String) {
        let body = Data("\(reason)\n".utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
        head += "Content-Type: text/plain\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, WKNavigationDelegate, WKUIDelegate {
    private var slots: [String: Slot] = [:]
    private var stateURL: URL?
    private var ackDir: URL?
    private var cascadeStep = 0
    private var pendingFit: [String: DispatchWorkItem] = [:]
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var historyHotKeyRef: EventHotKeyRef?

    // MARK: - Session restore & window history

    /// The ⌘Q-confirmed snapshot lives in session.json (NOT state.json —
    /// that stays a live mirror and gets rewritten by any launch-time GURL
    /// before restore could read it). Pending restore fires 1.2s after
    /// launch unless an open/show/restore action arrives first (an agent
    /// cold-launching the app must not resurrect a user's old session).
    private var pendingRestore: DispatchWorkItem?
    private var sessionURL: URL?

    /// True once applicationShouldTerminate said .terminateNow. windowWillClose
    /// fires per window during teardown and would otherwise empty state.json
    /// slot by slot, destroying the very snapshot restore needs.
    private var isTerminating = false

    /// Closed-window history (most recent first), pruned to historyHours and
    /// capped. Powers the ⌃⌥⌘K history picker; private windows never enter.
    private var historyEntries: [[String: Any]] = []
    private var historyURL: URL?
    private static let historyMaxEntries = 200

    /// Find-in-page engine injected into every page (⌘F). The bar UI and the
    /// search live in the page; menu actions drive the tiny `__arowserFind`
    /// JS API. Highlights use the CSS Custom Highlight API so page DOM is
    /// never mutated (safe for React/Vue apps); the bar itself is rendered in
    /// a closed shadow root so page CSS can't touch it. Main frame only.
    private static let findBarScript = #"""
    (() => {
      if (window.__arowserFind) return;
      const FIND_PLACEHOLDER = \#(jsString(L("Find…")));
      const PREVIOUS_TITLE = \#(jsString(L("Previous (Shift+Enter)")));
      const NEXT_TITLE = \#(jsString(L("Next (Enter)")));
      const CLOSE_TITLE = \#(jsString(L("Close (Esc)")));
      const NO_MATCH = \#(jsString(L("No results")));
      const MAX = 2000;
      const host = document.createElement('div');
      host.style.cssText = 'all:initial;position:fixed;top:32px;right:12px;z-index:2147483647;';
      const root = host.attachShadow({mode: 'closed'});
      root.innerHTML = `
        <style>
          .bar{display:flex;align-items:center;gap:6px;padding:6px 8px;border-radius:8px;
               background:rgba(30,30,46,.92);color:#cdd6f4;
               font:12px/1.2 -apple-system,'PingFang SC',system-ui,sans-serif;
               box-shadow:0 4px 16px rgba(0,0,0,.35)}
          input{width:180px;padding:3px 6px;border:none;border-radius:5px;outline:none;
                background:#313244;color:#cdd6f4;font:inherit}
          .nores input{background:#57314a}
          .count{min-width:52px;text-align:center;color:#7f849c;white-space:nowrap}
          button{border:none;background:transparent;color:#cdd6f4;border-radius:5px;
                 width:22px;height:20px;font:12px/1 sans-serif;cursor:pointer;padding:0}
          button:hover{background:#45475a}
        </style>
        <div class="bar">
          <input type="text" placeholder="" spellcheck="false">
          <span class="count"></span>
          <button data-act="prev" title="">&#9650;</button>
          <button data-act="next" title="">&#9660;</button>
          <button data-act="close" title="">&#10005;</button>
        </div>`;
      const bar = root.querySelector('.bar');
      const input = root.querySelector('input');
      const count = root.querySelector('.count');
      input.placeholder = FIND_PLACEHOLDER;
      root.querySelector('[data-act="prev"]').title = PREVIOUS_TITLE;
      root.querySelector('[data-act="next"]').title = NEXT_TITLE;
      root.querySelector('[data-act="close"]').title = CLOSE_TITLE;

      // ::highlight() styles must live in the page document (highlights paint
      // on page content); script-inserted <style> is not CSP-blocked.
      const pageStyle = document.createElement('style');
      pageStyle.textContent =
        '::highlight(arowser-find-others){background-color:rgba(255,196,0,.35)}' +
        '::highlight(arowser-find-active){background-color:rgba(0,140,255,.45)}';
      (document.head || document.documentElement).appendChild(pageStyle);

      const supported = 'highlights' in CSS && typeof Highlight !== 'undefined';
      let ranges = [], idx = -1, total = 0, capped = false, timer = 0, visible = false;

      function clearPaint() {
        if (!supported) return;
        CSS.highlights.delete('arowser-find-others');
        CSS.highlights.delete('arowser-find-active');
      }

      function paint() {
        if (!supported) return;
        clearPaint();
        if (!ranges.length) return;
        const others = [];
        for (let i = 0; i < ranges.length; i++) if (i !== idx) others.push(ranges[i]);
        CSS.highlights.set('arowser-find-others', new Highlight(...others));
        if (idx >= 0) CSS.highlights.set('arowser-find-active', new Highlight(ranges[idx]));
      }

      function collect() {
        ranges = []; idx = -1; total = 0; capped = false;
        const q = input.value;
        if (!q || !document.body) return;
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode(n) {
            const t = n.parentNode && n.parentNode.nodeName;
            if (t === 'SCRIPT' || t === 'STYLE' || t === 'NOSCRIPT' || t === 'TEMPLATE') return NodeFilter.FILTER_REJECT;
            return n.nodeValue ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          }
        });
        const nodes = [];
        while (walker.nextNode()) nodes.push(walker.currentNode);
        if (!nodes.length) return;
        const lower = q.toLowerCase();
        const starts = new Array(nodes.length);
        let buf = '';
        for (let i = 0; i < nodes.length; i++) { starts[i] = buf.length; buf += nodes[i].nodeValue.toLowerCase(); }
        let ni = 0;  // matches advance monotonically, so the node pointer only moves forward
        const at = (pos) => {
          while (ni + 1 < nodes.length && starts[ni + 1] <= pos) ni++;
          return { n: nodes[ni], off: pos - starts[ni] };
        };
        let pos = 0;
        while (true) {
          const i = buf.indexOf(lower, pos);
          if (i === -1) break;
          total++;
          if (ranges.length < MAX) {
            const s = at(i), e = at(i + lower.length);
            try {
              const r = document.createRange();
              r.setStart(s.n, s.off);
              r.setEnd(e.n, e.off);
              ranges.push(r);
            } catch (err) { total--; }
          } else {
            capped = true;
          }
          pos = i + lower.length;
        }
      }

      function render() {
        bar.classList.toggle('nores', !!input.value && ranges.length === 0);
        if (!input.value) { count.textContent = ''; return; }
        count.textContent = ranges.length === 0 ? NO_MATCH
          : (idx + 1) + '/' + ranges.length + (capped ? '+' : '');
      }

      function reveal() {
        const r = ranges[idx];
        if (!r) return;
        try {
          const rect = r.getBoundingClientRect();
          if (rect.top < 40 || rect.bottom > innerHeight - 40)
            window.scrollBy(0, rect.top - innerHeight * 0.4);
        } catch (err) {}
      }

      function step(d) {
        if (!ranges.length) return;
        idx = (idx + d + ranges.length) % ranges.length;
        paint(); reveal(); render();
      }

      function search() {
        collect();
        if (ranges.length) idx = 0;
        paint(); reveal(); render();
      }

      function show(q) {
        if (q !== undefined && q !== null) input.value = q;
        if (!visible) {
          visible = true;
          host.style.display = 'block';
          if (input.value) search(); else render();
        }
        setTimeout(() => { input.focus(); if (input.value) input.select(); }, 0);
      }

      function hide() {
        visible = false;
        host.style.display = 'none';
        clearPaint();
        ranges = []; idx = -1;
        input.blur();
      }

      function next() { show(); if (ranges.length) step(1); }
      function prev() { show(); if (ranges.length) step(-1); }

      input.addEventListener('input', () => {
        clearTimeout(timer);
        timer = setTimeout(search, 120);
      });
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
          e.preventDefault(); e.stopPropagation();
          e.shiftKey ? prev() : next();
        } else if (e.key === 'Escape') {
          e.preventDefault(); e.stopPropagation();
          hide();
        }
      });
      root.addEventListener('mousedown', (e) => {
        const b = e.composedPath().find((n) => n.dataset && n.dataset.act);
        if (b) {
          e.preventDefault();
          if (b.dataset.act === 'close') hide();
          else if (b.dataset.act === 'next') next();
          else prev();
        }
      });

      host.style.display = 'none';
      (document.body || document.documentElement).appendChild(host);
      window.__arowserFind = { show, hide, next, prev };
    })();
    """#

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // .regular since 2026-11-13 (was .accessory/LSUIElement): the app
        // shows a Dock icon and participates in ⌘Tab, giving sunken Unfloat
        // windows the standard recovery channels. Windows are still addressed
        // by id/hotkeys; the Dock icon click is wired to the pickers (see
        // applicationShouldHandleReopen).
        NSApp.setActivationPolicy(.regular)
        prepareDirectories()
        // Must run BEFORE any URL event can be handled: macOS dispatches the
        // cold-start GURL AppleEvent while didFinishLaunching is still on the
        // stack (measured: serve arrived 25ms before line 607 used to run),
        // so initializing serve state there lost the race every cold serve.
        DirServer.shared.restore(configDir: applicationSupportDir())
        loadHistory()
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌘+ (⌘⇧=) / ⌘- / ⌘0. The menu owns "+", "-", "0"; this monitor also
        // catches the unshifted ⌘= form of "zoom in".
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers ?? "" {
            case "=":
                self.zoomIn(nil)
                return nil
            case "-":
                self.zoomOut(nil)
                return nil
            case "0":
                self.zoomReset(nil)
                return nil
            default:
                return event
            }
        }
        // Right-click context menu. WKWebView's internal view consumes
        // rightMouseDown below us in the responder chain (and modern macOS
        // WebKit exposes no delegate API to customize its menu), so we
        // intercept at the app level before dispatch and show our own menu.
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self,
                  let window = event.window,
                  let slot = self.slots.values.first(where: { $0.window === window })
            else { return event }
            let point = window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
            // The top 28pt drag strip keeps its own behavior unless it is
            // disabled; only take right-clicks over the page area.
            let inDragStrip = point.y > (window.contentView?.bounds.height ?? 0) - 28
            if inDragStrip && slot.dragBarEnabled { return event }
            self.presentContextMenu(for: slot.webView, event: event)
            return nil
        }
        registerGlobalHotKey()
        installStatusItem()
        writeState()
        maybeRestoreSession()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCookieMirrors()
        }
    }

    // MARK: - Global hotkey (default ⌃⌥⌘L) window picker

    private static let hotKeySignature: OSType = 0x61_72_6F_77 // 'arow'

    /// Default picker hotkey: ⌃⌥⌘L. Override via
    /// ~/Library/Application Support/arowser/settings.json {"hotkey": "ctrl+opt+cmd+P"}
    /// (modifiers ctrl/opt/cmd/shift + one letter or digit), then restart.
    private static let defaultHotKey = (
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    private static let ansiKeyCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1,
        "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
        "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    /// Parses "ctrl+opt+cmd+l" style specs; nil on anything unrecognised.
    private static func parseHotKey(_ text: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers = 0
        var keyCode: Int?
        for part in text.lowercased().split(whereSeparator: { "+- ".contains($0) }) {
            switch part {
            case "ctrl", "control": modifiers |= controlKey
            case "opt", "option", "alt": modifiers |= optionKey
            case "cmd", "command": modifiers |= cmdKey
            case "shift": modifiers |= shiftKey
            default:
                guard part.count == 1, let code = ansiKeyCodes.first(where: { $0.key == part.first })?.value else {
                    return nil
                }
                keyCode = code
            }
        }
        guard let keyCode, modifiers != 0 else { return nil }
        return (UInt32(keyCode), UInt32(modifiers))
    }

    /// Parsed settings.json content, or nil when absent/unreadable.
    private func settingsObject() -> [String: Any]? {
        guard let stateURL,
              let data = try? Data(contentsOf: stateURL.deletingLastPathComponent()
                  .appendingPathComponent("settings.json"))
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func configuredHotKey() -> (keyCode: UInt32, modifiers: UInt32) {
        if let text = settingsObject()?["hotkey"] as? String,
           let parsed = Self.parseHotKey(text) {
            return parsed
        }
        return Self.defaultHotKey
    }

    /// Default history picker hotkey: ⌃⌥⌘K. Override via
    /// {"historyHotkey": "ctrl+opt+cmd+J"} in settings.json.
    private static let defaultHistoryHotKey = (
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    private func configuredHistoryHotKey() -> (keyCode: UInt32, modifiers: UInt32) {
        if let text = settingsObject()?["historyHotkey"] as? String,
           let parsed = Self.parseHotKey(text) {
            return parsed
        }
        return Self.defaultHistoryHotKey
    }

    /// Auto session restore after a confirmed ⌘Q quit. Kill switch:
    /// {"sessionRestore": false} in settings.json.
    private func sessionRestoreEnabled() -> Bool {
        if let flag = settingsObject()?["sessionRestore"] as? Bool { return flag }
        return true
    }

    /// History retention in hours (default 24). 0 keeps entries until the
    /// count cap regardless of age. {"historyHours": 48} in settings.json.
    private func configuredHistoryHours() -> Double {
        if let hours = settingsObject()?["historyHours"] as? Double { return hours }
        return 24
    }

    /// Carbon hotkeys need no Accessibility permission, matching the rest of
    /// the control plane. id 1 opens the live-window picker (⌃⌥⌘L), id 2 the
    /// closed-window history picker (⌃⌥⌘K).
    private func registerGlobalHotKey() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard hotKeyID.signature == AppDelegate.hotKeySignature else { return noErr }
            let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            switch hotKeyID.id {
            case 1: app.showWindowPicker()
            case 2: app.showHistoryPicker()
            default: break
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(
            configuredHotKey().keyCode,
            configuredHotKey().modifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        ) == noErr { hotKeyRef = ref }
        var historyRef: EventHotKeyRef?
        if RegisterEventHotKey(
            configuredHistoryHotKey().keyCode,
            configuredHistoryHotKey().modifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: 2),
            GetApplicationEventTarget(),
            0,
            &historyRef
        ) == noErr { historyHotKeyRef = historyRef }
    }

    /// Shared window list (● visible, ○ hidden, visible first) used by both
    /// the ⌃⌥⌘L picker and the context menu's "Windows" submenu.
    private func windowListMenu(includeHideHint: Bool = true) -> NSMenu {
        let menu = NSMenu(title: "Windows")
        let ordered = slots.values.sorted {
            if $0.window.isVisible != $1.window.isVisible { return $0.window.isVisible }
            return $0.window.title < $1.window.title
        }
        for slot in ordered {
            let mark = slot.window.isVisible ? "●" : "○"
            var label = "\(mark)  \(slot.window.title)"
            if !slot.pageTitle.isEmpty, slot.pageTitle != slot.window.title {
                label += " · \(slot.pageTitle)"
            }
            if let host = URL(string: slot.urlString)?.host,
               !host.isEmpty, host != slot.window.title, !label.contains(host) {
                label += " · \(host)"
            }
            let item = NSMenuItem(
                title: label,
                action: #selector(togglePickedWindow(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = slot.id
            item.toolTip = "toggle show/hide\n\(slot.id)\n\(slot.urlString)\nowner: \(slot.owner)"
            menu.addItem(item)
        }
        // While the menu is tracking, keyboard events go to the menu and the
        // Carbon global hotkey never fires. An item carrying the same combo
        // as its keyEquivalent lets the hotkey close the picker (toggle).
        // The status-bar submenu omits this hint (no hotkey context there).
        if includeHideHint {
            menu.addItem(.separator())
            let hideItem = NSMenuItem(
                title: "Hide Picker",
                action: #selector(pickerHideAction(_:)),
                keyEquivalent: "l"
            )
            hideItem.target = self
            hideItem.keyEquivalentModifierMask = [.command, .control, .option]
            menu.addItem(hideItem)
        }
        return menu
    }

    /// Selecting "Hide Picker" just lets the menu close (selection dismisses
    /// it); the action exists so the item stays enabled and matchable.
    @objc private func pickerHideAction(_ sender: NSMenuItem) {}

    // MARK: - Menu bar status item (常驻入口)

    /// Persistent ⌘-bar entry (2026-11-13): window switching + history, the
    /// two picker capabilities as ordinary submenus. {"statusItem": false} in
    /// settings.json removes it (restart to apply). SF Symbol renders as a
    /// template image, so it adapts to dark/light menu bars with no assets.
    private var statusItem: NSStatusItem?

    private func statusItemEnabled() -> Bool {
        if let flag = settingsObject()?["statusItem"] as? Bool { return flag }
        return true
    }

    private func installStatusItem() {
        guard statusItemEnabled(), statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = statusBarImage()
        }
        let menu = NSMenu(title: "arowser")
        menu.delegate = self  // rebuilt on every open (slots/history change)
        item.menu = menu
        statusItem = item
    }

    /// Menu bar glyph (2026-11-13, "02-panel"): custom template
    /// image from the bundle — front window + title-bar stub, matching the
    /// 01-float app icon language. Pure black + alpha; isTemplate lets the
    /// system color it for dark/light bars. Falls back to the SF Symbol if
    /// the asset is missing (e.g. stale bundle).
    private func statusBarImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "statusbar-template", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else {
            let fallback = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "arowser")
            fallback?.isTemplate = true
            return fallback
        }
        // 16pt logical size; register the 16px legacy rep so non-retina bars
        // get a native-resolution copy.
        if let legacyURL = Bundle.main.url(forResource: "statusbar-template-legacy", withExtension: "png"),
           let legacy = NSImage(contentsOf: legacyURL),
           let rep = legacy.representations.first {
            rep.size = NSSize(width: 16, height: 16)
            image.addRepresentation(rep)
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    /// Rebuild the status menu each time it opens — live windows and history
    /// change between opens. Submenus reuse the picker actions, so picking
    /// from the status bar behaves exactly like the hotkey pickers.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let windowsItem = NSMenuItem(title: L("Windows"), action: nil, keyEquivalent: "")
        windowsItem.submenu = windowListMenu(includeHideHint: false)
        menu.addItem(windowsItem)
        let historyItem = NSMenuItem(title: L("History"), action: nil, keyEquivalent: "")
        let history = NSMenu(title: L("History"))
        fillHistoryEntries(into: history, includeHeader: false)
        historyItem.submenu = history
        menu.addItem(historyItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit arowser"), action: #selector(statusQuit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Quit from the status menu is a human gesture: the ⌘Q confirmation
    /// applies (skipQuitConfirm stays false).
    @objc private func statusQuit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    /// Non-nil while the picker menu is tracking; lets the hotkey toggle it.
    private var pickerMenu: NSMenu?

    /// Set when the user picked a window from a menu; the picker's cleanup
    /// only deactivates the app when nothing was picked.
    private var pickerPicked = false

    /// Bumped on every picker session; lets a superseded session's delayed
    /// cleanup stand down instead of tearing down the new session's anchor.
    private var pickerGeneration = 0

    /// Persistent transparent anchor window for the picker. Created lazily,
    /// parked offscreen between uses, NEVER closed while the app runs:
    /// destroying menu-adjacent windows inside (or one tick after) the Carbon
    /// handler over-releases tracking-session leftovers and segfaults
    /// (crashes 2026-11-09, objc_release in autoreleasePoolPop).
    private var pickerHelper: NSWindow?

    private func pickerAnchorWindow() -> NSWindow {
        if let helper = pickerHelper { return helper }
        let helper = NSWindow(
            contentRect: NSRect(x: -100, y: -100, width: 40, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        helper.isOpaque = false
        helper.backgroundColor = .clear
        helper.level = .statusBar
        helper.ignoresMouseEvents = true
        helper.collectionBehavior = [.canJoinAllSpaces]
        pickerHelper = helper
        return helper
    }

    /// Hotkey-triggered window picker. Pops a keyboard-navigable list of all
    /// windows (● visible, ○ hidden) at a FIXED spot on the main screen;
    /// Enter/click shows and activates the chosen one, Esc dismisses.
    /// Triggering the hotkey again while open closes it (toggle).
    func showWindowPicker() {
        if closeOpenPickers() { return }
        guard !slots.isEmpty else { return }
        let menu = windowListMenu()
        pickerMenu = menu
        pickerPicked = false
        pickerGeneration += 1
        let generation = pickerGeneration

        // Fixed anchor: center of the main screen's visible area (slightly
        // above middle so it reads like a switcher, not a context menu).
        // The menu must NOT depend on any arowser window: with all windows
        // hidden (orderOut) or on another Space, anchoring to a slot window
        // leaves the tracking session on an invisible surface and eats keys.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // popUp(positioning:) puts the menu's top-left at the anchor; shift
        // left by half the menu width to center it on screen.
        let anchor = NSPoint(
            x: visible.midX - menu.size.width / 2,
            y: visible.midY + visible.height * 0.15)
        let helper = pickerAnchorWindow()
        helper.setFrameOrigin(anchor)
        helper.orderFrontRegardless()
        defer {
            pickerMenu = nil
            let picked = pickerPicked
            DispatchQueue.main.async {
                _ = menu  // release menu after the tracking pool has drained
                guard generation == self.pickerGeneration else { return }
                helper.orderOut(nil)
                // Give focus back when the picker was dismissed without a
                // pick; the pick path re-activates on its own.
                if !picked { NSApp.deactivate() }
            }
        }

        // The hotkey fires while the user's own app is frontmost; without
        // activating, keyboard events (toggle, arrows, Return, Esc) keep going
        // to that app and never reach the menu.
        NSApp.activate(ignoringOtherApps: true)
        guard let view = helper.contentView else { return }
        menu.popUp(positioning: nil, at: .zero, in: view)
    }

    /// Picker / Windows-submenu item, three-way semantics (2026-11-13):
    /// hidden → show and activate; visible but NOT key (e.g. sunk behind
    /// other apps after Unfloat) → raise and activate; visible AND key
    /// (already focused) → hide, the original toggle. This gives a sunken
    /// window a one-press recovery path — with plain toggle, picking it
    /// first HIDES it (orderOut), which reads as "it vanished" and needs a
    /// second press to come back.
    @objc private func togglePickedWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let slot = slots[id] else { return }
        if slot.window.isVisible {
            if slot.window.isKeyWindow {
                // Focused → hide. pickerPicked stays false so the picker's
                // cleanup hands focus back to the user's frontmost app.
                slot.window.orderOut(nil)
                writeState()
                return
            }
            // Visible but not focused (buried/sunk) → raise + activate.
        }
        // Show/raise path. The picker fires from a global hotkey while
        // another app is frontmost; activating here keeps focus on the
        // chosen window (needed for ⌘H etc). Menu dismissal restores the
        // previous app's focus, so re-assert once after the tracking
        // session has unwound.
        pickerPicked = true
        NSApp.activate(ignoringOtherApps: true)
        slot.window.makeKeyAndOrderFront(nil)
        writeState()
        let window = slot.window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            self?.writeState()
        }
    }

    /// ⌘H — hide the current (focused) window only; the app and other
    /// windows stay. Re-show via ⌥⌘A picker, CLI `show`, or a new open.
    @objc private func hideCurrentWindow(_ sender: Any?) {
        guard let slot = activeSlot() else { return }
        slot.window.orderOut(nil)
        writeState()
    }

    // MARK: - History picker (⌃⌥⌘K)

    /// Non-nil while the history menu is tracking. Separate menu from the
    /// live picker; either hotkey dismisses whichever one is open.
    private var historyMenu: NSMenu?

    /// Cancels whichever picker menu is currently tracking. Returns true when
    /// one was open — callers treat their hotkey as a toggle and bail.
    @discardableResult
    private func closeOpenPickers() -> Bool {
        var wasOpen = false
        if let open = pickerMenu {
            open.cancelTracking()
            pickerMenu = nil
            // Release menus after the current autorelease pool has drained
            // (releasing them inside the Carbon handler over-releases
            // tracking-session leftovers — crashes 2026-11-09).
            DispatchQueue.main.async { _ = open }
            wasOpen = true
        }
        if let open = historyMenu {
            open.cancelTracking()
            historyMenu = nil
            DispatchQueue.main.async { _ = open }
            wasOpen = true
        }
        return wasOpen
    }

    /// ⌃⌥⌘K picker over recently closed windows (historyHours retention).
    /// Picking an entry reopens it under its original id — old agent ids keep
    /// addressing the window; if that id is somehow still alive it's just
    /// fronted. Same anchor/activate/toggle machinery as the live picker.
    func showHistoryPicker() {
        if closeOpenPickers() { return }
        let menu = NSMenu(title: "History")
        let hideItem = NSMenuItem(
            title: L("Close History"),
            action: #selector(pickerHideAction),
            keyEquivalent: ""
        )
        hideItem.target = self
        hideItem.keyEquivalent = "k"
        hideItem.keyEquivalentModifierMask = [.command, .control, .option]
        menu.addItem(hideItem)
        menu.addItem(.separator())
        fillHistoryEntries(into: menu, includeHeader: true)
        historyMenu = menu
        pickerPicked = false
        pickerGeneration += 1
        let generation = pickerGeneration

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = NSPoint(
            x: visible.midX - menu.size.width / 2,
            y: visible.midY + visible.height * 0.15
        )
        let helper = pickerAnchorWindow()
        helper.setFrameOrigin(anchor)
        helper.orderFrontRegardless()
        defer {
            historyMenu = nil
            let picked = pickerPicked
            DispatchQueue.main.async {
                _ = menu
                guard generation == self.pickerGeneration else { return }
                helper.orderOut(nil)
                if !picked { NSApp.deactivate() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        guard let view = helper.contentView else { return }
        menu.popUp(positioning: nil, at: .zero, in: view)
    }

    /// History entry items shared by the ⌃⌥⌘K picker and the status-bar
    /// 历史 submenu. includeHeader adds the "recent N hours empty" placeholder
    /// wording (the picker's header row is added by its caller).
    private func fillHistoryEntries(into menu: NSMenu, includeHeader: Bool) {
        if includeHeader, historyEntries.isEmpty {
            let empty = NSMenuItem(
                title: LF("No closed windows in the last %d hours", Int(configuredHistoryHours())),
                action: nil, keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in historyEntries {
            let pageTitle = (entry["pageTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entry["url"] as? String ?? "")
            var text = pageTitle.count > 40 ? String(pageTitle.prefix(40)) + "…" : pageTitle
            if let closed = closedAt(entry) { text += " — \(relativeTime(closed))" }
            let profile = entry["profile"] as? String ?? "default"
            if profile != "default" { text += " ·\(profile)" }
            let item = NSMenuItem(title: text, action: #selector(historyPickAction), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            menu.addItem(item)
        }
    }

    /// History picker selection: reopen under the original id, or front the
    /// window when that id is still alive.
    @objc private func historyPickAction(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? [String: Any],
              let id = entry["id"] as? String
        else { return }
        pickerPicked = true
        if slots[id] == nil {
            restoreRecords([entry])
        }
        guard let slot = slots[id] else { return }
        NSApp.activate(ignoringOtherApps: true)
        slot.window.makeKeyAndOrderFront(nil)
        let window = slot.window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            self?.writeState()
        }
    }

    // MARK: - Find in page (⌘F)
    // Engine and bar live in `findBarScript` (user script, injected per page);
    // these menu actions only drive its JS API.

    @objc private func findInPage(_ sender: Any?) {
        guard let slot = activeSlot() else { return }
        slot.webView.evaluateJavaScript(
            "window.__arowserFind && window.__arowserFind.show()",
            completionHandler: nil
        )
    }

    @objc private func findNextMatch(_ sender: Any?) {
        guard let slot = activeSlot() else { return }
        slot.webView.evaluateJavaScript(
            "window.__arowserFind && window.__arowserFind.next()",
            completionHandler: nil
        )
    }

    @objc private func findPreviousMatch(_ sender: Any?) {
        guard let slot = activeSlot() else { return }
        slot.webView.evaluateJavaScript(
            "window.__arowserFind && window.__arowserFind.prev()",
            completionHandler: nil
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handle(url)
        }
        writeState()
    }

    /// Reopen handling (Dock click, Raycast/`open -a` on the running app —
    /// all arrive as the same rapp AppleEvent, so this must NOT open picker
    /// menus unconditionally: keepAlive keeps the app always running, making
    /// every launcher "open" a reopen; a menu popping there reads as a bug,
    /// 2026-11-13 user report). Semantics: zero windows → history picker
    /// (Dock click on an idle app should still do something); visible
    /// windows → plain activate + front the key one (standard relaunch
    /// feel); all hidden → window picker (launching means "get my windows").
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if slots.isEmpty {
            showHistoryPicker()
            return true
        }
        if flag {
            NSApp.activate(ignoringOtherApps: true)
            if let slot = slots.values.first(where: { $0.window.isKeyWindow })
                ?? slots.values.first(where: { $0.window.isVisible }) {
                slot.window.makeKeyAndOrderFront(nil)
                let window = slot.window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
            }
        } else {
            showWindowPicker()
        }
        return true
    }

    /// Windows are independent; the app leaves only after the last one closes
    /// and a short grace period passed (so multiple agents can open windows
    /// back to back without racing a teardown).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Set by the CLI `quit` action so programmatic (agent) quits never get
    /// stuck on the confirmation dialog below.
    private var skipQuitConfirm = false

    /// All terminateNow exits funnel through here: isTerminating stops the
    /// per-window teardown writes (windowWillClose) from emptying the
    /// state.json snapshot restore depends on.
    private func terminateNow() -> NSApplication.TerminateReply {
        isTerminating = true
        saveCookieMirrors()
        return .terminateNow
    }

    /// ⌘Q confirmation: closing kills every window (hidden ones included)
    /// and the serve listener. Programmatic quits (CLI quit --all, and the
    /// 1s grace auto-exit after the last window closed, which only fires
    /// with zero slots) bypass the dialog. A confirmed dialog quit marks the
    /// session for restore-on-next-launch; CLI/grace exits never do.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if skipQuitConfirm || slots.isEmpty { return terminateNow() }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Quit arowser?")
        let hidden = slots.values.filter { !$0.window.isVisible }.count
        var detail = LF("%d windows will close", slots.count)
        if hidden > 0 { detail += LF(" (including %d hidden windows)", hidden) }
        let mounts = DirServer.shared.mountList.count
        if mounts > 0 {
            detail += LF("; local serve will stop (%d mounts, automatically restored on next serve)", mounts)
        }
        if sessionRestoreEnabled() { detail += L(". These windows will be restored on next launch") }
        alert.informativeText = detail
        // 取消 is the default (Return/Esc): a reflexive Enter after an
        // accidental ⌘Q must not kill the windows.
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Quit"))
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if sessionRestoreEnabled() { writeSessionSnapshot() }
            return terminateNow()
        }
        return .terminateCancel
    }

    /// Persists the live slots as session.json for the next launch to
    /// restore. Built from live state (not state.json) so geometry captured
    /// since the last writeState isn't lost.
    private func writeSessionSnapshot() {
        guard let sessionURL else { return }
        var slotDict: [String: Any] = [:]
        for (id, slot) in slots {
            slotDict[id] = serializedSlot(id, slot)
        }
        let payload: [String: Any] = [
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "slots": slotDict,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: sessionURL, options: .atomic)
    }

    // MARK: - Session restore (core)

    /// Replays persisted slot records as live windows via the normal open
    /// path. Skips ids already alive and private windows (their cookie jar
    /// died with the process). Returns how many windows were recreated.
    @discardableResult
    private func restoreRecords(_ records: [[String: Any]]) -> Int {
        var restored = 0
        let ordered = records.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        for record in ordered {
            guard let id = record["id"] as? String, !id.isEmpty,
                  let url = record["url"] as? String, !url.isEmpty,
                  slots[id] == nil
            else { continue }
            let profile = record["profile"] as? String ?? "default"
            if profile == "private" { continue }
            var params: [String: String] = [
                "id": id,
                "url": url,
                "owner": record["owner"] as? String ?? "anonymous",
            ]
            if profile != "default" { params["profile"] = profile }
            if let title = record["title"] as? String, !title.isEmpty, title != id {
                params["title"] = title
            }
            if let fit = record["fit"] as? Bool { params["fit"] = fit ? "1" : "0" }
            if let mobile = record["mobile"] as? Bool { params["mobile"] = mobile ? "1" : "0" }
            // Level rides the record: pre-default-flip records say pinned:true
            // (they were floating) and keep it on restore; new records carry
            // the actual choice.
            params["float"] = (record["pinned"] as? Bool ?? true) ? "1" : "0"
            for key in ["x", "y", "w", "h"] {
                if let n = record[key] as? Int { params[key] = String(n) }
            }
            let outcome = openWindow(params, owner: params["owner"] ?? "anonymous")
            guard outcome.error == nil, let slot = slots[id] else { continue }
            if let zoom = record["zoom"] as? Double, zoom > 0, zoom != 1.0 {
                slot.manualZoom = zoom
                slot.webView.pageZoom = zoom
            }
            if let dragBar = record["dragBar"] as? Bool { slot.dragBarEnabled = dragBar }
            if (record["visible"] as? Bool) == false {
                slot.window.orderOut(nil)
            }
            restored += 1
        }
        if restored > 0 { writeState() }
        return restored
    }

    /// Launch hook: after a ⌘Q-confirmed quit, replay session.json — but
    /// wait 1.2s first. A cold-start GURL (an agent's `arowser open ...`
    /// launching the app) cancels the restore and forfeits the session:
    /// agents must keep their "open one window, get one window" lifecycle.
    private func maybeRestoreSession() {
        guard sessionRestoreEnabled(), let sessionURL,
              FileManager.default.fileExists(atPath: sessionURL.path)
        else { return }
        let snapshot = sessionURL
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestore = nil
            defer { try? FileManager.default.removeItem(at: snapshot) }
            guard let data = try? Data(contentsOf: snapshot),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let slotDict = object["slots"] as? [String: Any]
            else { return }
            self.restoreRecords(slotDict.values.compactMap { $0 as? [String: Any] })
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// An open/show/restore action arrived at launch: the caller wants a
    /// specific window set, not the restored session. open/show forfeit the
    /// snapshot; the restore action consumes it itself (forfeit: false).
    /// Deleting is NOT gated on pendingRestore: a cold-start GURL is handled
    /// BEFORE maybeRestoreSession arms (measured 25ms earlier), so at cancel
    /// time the work item doesn't exist yet — removing session.json now is
    /// what stops the later arming from ever firing.
    private func cancelPendingRestore(forfeit: Bool) {
        pendingRestore?.cancel()
        pendingRestore = nil
        if forfeit, let sessionURL { try? FileManager.default.removeItem(at: sessionURL) }
    }

    /// `arowser restore`: explicit recovery — session.json snapshot first,
    /// then any dead state.json records (crash leftovers). Consumes the
    /// snapshot so it doesn't resurrect again on the next launch.
    private func restoreFromStateFile() -> Int {
        var records: [[String: Any]] = []
        if let sessionURL,
           let data = try? Data(contentsOf: sessionURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let slotDict = object["slots"] as? [String: Any] {
            records = slotDict.values.compactMap { $0 as? [String: Any] }
            try? FileManager.default.removeItem(at: sessionURL)
        }
        if records.isEmpty, let stateURL,
           let data = try? Data(contentsOf: stateURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let slotDict = object["slots"] as? [String: Any] {
            records = slotDict.values.compactMap { $0 as? [String: Any] }
        }
        return restoreRecords(records)
    }

    // MARK: - Window history (core)

    private func loadHistory() {
        guard let historyURL,
              let data = try? Data(contentsOf: historyURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["history"] as? [[String: Any]]
        else { return }
        historyEntries = pruneHistory(raw)
        writeHistory()
    }

    /// Entries are most-recent-first; drops entries older than historyHours
    /// (0 = no time limit) and caps the count.
    private func pruneHistory(_ entries: [[String: Any]]) -> [[String: Any]] {
        let hours = configuredHistoryHours()
        let cutoff = hours > 0 ? Date().addingTimeInterval(-hours * 3600) : nil
        var kept: [[String: Any]] = []
        for entry in entries {
            if kept.count >= Self.historyMaxEntries { break }
            if let cutoff, let closed = closedAt(entry), closed < cutoff { break }
            kept.append(entry)
        }
        return kept
    }

    private func closedAt(_ entry: [String: Any]) -> Date? {
        guard let text = entry["closedAt"] as? String else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private func writeHistory() {
        guard let historyURL else { return }
        let payload: [String: Any] = ["history": historyEntries]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    /// Every close path funnels here (CLI close, ⌘W/menu close, popup
    /// window.close). Private windows and the shared notify card (owner
    /// "notify", see the notify-user convention) are transient by design —
    /// they never enter history.
    private func appendHistory(_ id: String, _ slot: Slot) {
        guard slot.profile != "private", slot.owner != "notify" else { return }
        var entry = serializedSlot(id, slot)
        entry["closedAt"] = ISO8601DateFormatter().string(from: Date())
        historyEntries.removeAll { $0["id"] as? String == id }
        historyEntries.insert(entry, at: 0)
        if historyEntries.count > Self.historyMaxEntries {
            historyEntries = Array(historyEntries.prefix(Self.historyMaxEntries))
        }
        writeHistory()
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return L("Just now") }
        if seconds < 3600 { return LF("%d min ago", Int(seconds / 60)) }
        if seconds < 86400 { return LF("%d hours ago", Int(seconds / 3600)) }
        return LF("%d days ago", Int(seconds / 86400))
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit arowser",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = NSMenuItem()
        findItem.title = "Find"
        let findMenu = NSMenu(title: "Find")
        let findBarItem = NSMenuItem(title: "Find in Page…", action: #selector(findInPage(_:)), keyEquivalent: "f")
        findBarItem.target = self
        findMenu.addItem(findBarItem)
        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(findNextMatch(_:)), keyEquivalent: "g")
        findNextItem.target = self
        findMenu.addItem(findNextItem)
        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(findPreviousMatch(_:)), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.target = self
        findMenu.addItem(findPrevItem)
        findItem.submenu = findMenu
        editMenu.addItem(findItem)
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)
        let actualSizeItem = NSMenuItem(title: "Actual Size", action: #selector(zoomReset(_:)), keyEquivalent: "0")
        actualSizeItem.target = self
        viewMenu.addItem(actualSizeItem)
        let fitWidthItem = NSMenuItem(title: "Fit to Width", action: #selector(zoomFit(_:)), keyEquivalent: "9")
        fitWidthItem.target = self
        viewMenu.addItem(fitWidthItem)
        viewMenu.addItem(.separator())
        let reloadItem = NSMenuItem(title: "Reload", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        let fullReloadItem = NSMenuItem(
            title: "Full Reload",
            action: #selector(fullReloadPage(_:)),
            keyEquivalent: "R"
        )
        fullReloadItem.target = self
        viewMenu.addItem(fullReloadItem)
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        let hideItem = NSMenuItem(
            title: "Hide Window",
            action: #selector(hideCurrentWindow(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = self
        windowMenu.addItem(hideItem)
        windowMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Reload

    @objc private func reloadPage(_ sender: Any?) {
        activeSlot()?.webView.reload()
    }

    @objc private func fullReloadPage(_ sender: Any?) {
        activeSlot()?.webView.reloadFromOrigin()
    }

    // MARK: - Zoom

    @objc private func zoomIn(_ sender: Any?) {
        adjustZoom(by: 1.2)
    }

    @objc private func zoomOut(_ sender: Any?) {
        adjustZoom(by: 1 / 1.2)
    }

    @objc private func zoomReset(_ sender: Any?) {
        setZoom(1.0)
    }

    /// Clears manual zoom and goes back to fit-to-width.
    @objc private func zoomFit(_ sender: Any?) {
        guard let slot = activeSlot() else { return }
        slot.manualZoom = nil
        slot.fit = true
        applyFit(slot)
    }

    private func adjustZoom(by factor: Double) {
        guard let slot = activeSlot() else { return }
        let base = slot.manualZoom ?? Double(slot.webView.pageZoom)
        setZoom(base * factor, slot: slot)
    }

    private func setZoom(_ value: Double, slot: Slot? = nil) {
        guard let slot = slot ?? activeSlot() else { return }
        let clamped = min(3.0, max(0.2, value))
        slot.manualZoom = clamped
        slot.webView.pageZoom = clamped
        writeState()
    }

    private func activeSlot() -> Slot? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           let slot = slots.values.first(where: { $0.window === window }) {
            return slot
        }
        let visible = slots.values.filter { $0.window.isVisible }
        if visible.count == 1 {
            return visible[0]
        }
        if let window = NSApp.orderedWindows.first(where: { candidate in
            slots.values.contains { $0.window === candidate }
        }) {
            return slots.values.first { $0.window === window }
        }
        return nil
    }

    // MARK: - Directories and state

    private func prepareDirectories() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = base.appendingPathComponent("arowser", isDirectory: true)
        let acks = dir.appendingPathComponent("acks", isDirectory: true)
        try? FileManager.default.createDirectory(at: acks, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("state.json")
        sessionURL = dir.appendingPathComponent("session.json")
        historyURL = dir.appendingPathComponent("history.json")
        ackDir = acks
    }

    private func applicationSupportDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("arowser", isDirectory: true)
    }

    /// The exact per-slot dict writeState persists (also the shape history
    /// entries use, plus closedAt). Restore reads the same keys back.
    private func serializedSlot(_ id: String, _ slot: Slot) -> [String: Any] {
        let frame = slot.window.frame
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let x = (frame.origin.x).rounded()
        let y = (primaryHeight - frame.maxY).rounded()
        let w = frame.width.rounded()
        let h = frame.height.rounded()
        return [
            "id": id,
            "owner": slot.owner,
            "profile": slot.profile ?? "default",
            "url": slot.urlString,
            "title": slot.window.title,
            "pageTitle": slot.pageTitle,
            "visible": slot.window.isVisible,
            "pinned": slot.window.level == .floating,
            // Top-left screen coordinates, same convention as --x/--y.
            "frame": "{{\(Int(x)), \(Int(y))}, {\(Int(w)), \(Int(h))}}",
            "x": Int(x),
            "y": Int(y),
            "w": Int(w),
            "h": Int(h),
            "fit": slot.fit,
            "mobile": slot.mobile,
            "dragBar": slot.dragBarEnabled,
            "zoom": Double(slot.webView.pageZoom),
            // Non-empty only while the last navigation failed (see
            // handleLoadFailure); lets agents detect dead URLs via `list`.
            "error": slot.loadError ?? "",
        ]
    }

    private func writeState() {
        guard let stateURL else { return }
        var slotDict: [String: Any] = [:]
        for (id, slot) in slots {
            slotDict[id] = serializedSlot(id, slot)
        }
        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "slots": slotDict,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func writeAck(_ req: String, _ ack: [String: Any]) {
        guard !req.isEmpty, let ackDir else { return }
        let safe = req.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty else { return }
        let url = ackDir.appendingPathComponent("\(safe).json")
        if let data = try? JSONSerialization.data(withJSONObject: ack, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        pruneAcks(ackDir)
    }

    private func pruneAcks(_ dir: URL) {
        let cutoff = Date().addingTimeInterval(-3600)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Command dispatch

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "arowser",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }

        let action = (comps.host ?? "").lowercased()
        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            params[item.name] = item.value ?? ""
        }

        let req = params["req"] ?? ""
        let owner = params["owner"].flatMap { $0.isEmpty ? nil : $0 } ?? "anonymous"
        var ack: [String: Any] = [
            "req": req,
            "action": action,
            "ok": false,
            "ts": Date().timeIntervalSince1970,
        ]

        switch action {
        case "open", "show":
            cancelPendingRestore(forfeit: true)
            let outcome = openWindow(params, owner: owner)
            ack["ok"] = outcome.error == nil
            ack["id"] = outcome.id ?? ""
            if let error = outcome.error { ack["error"] = error }

        case "hide", "close", "reload":
            let outcome = control(params, owner: owner, action: action)
            ack["ok"] = outcome.error == nil
            ack["id"] = outcome.id ?? ""
            if let error = outcome.error { ack["error"] = error }

        case "list":
            ack["ok"] = true

        case "serve":
            guard let dir = params["dir"], !dir.isEmpty else {
                ack["error"] = "serve requires dir"
                break
            }
            if let mount = DirServer.shared.mount(dir, requestedID: params["id"]) {
                ack["ok"] = true
                ack["id"] = mount.id
                ack["url"] = mount.url
            } else {
                ack["error"] = "cannot serve '\(dir)' (not a directory, or port never became ready)"
            }

        case "quit":
            if params["all"] == "1" || params["force"] == "1" {
                ack["ok"] = true
                writeAck(req, ack)
                skipQuitConfirm = true
                NSApp.terminate(nil)
                return
            }
            ack["error"] = "quit closes every window; pass --all"

        case "restore":
            // Explicit recovery: reopen every state.json slot not currently
            // live (crash leftovers, or the pre-⌘Q snapshot).
            cancelPendingRestore(forfeit: false)
            let count = restoreFromStateFile()
            ack["ok"] = true
            ack["id"] = "restored \(count) window(s)"

        default:
            ack["error"] = "unknown action '\(action)'"
        }

        writeAck(req, ack)
    }

    // MARK: - Window operations

    private func openWindow(_ params: [String: String], owner: String) -> (id: String?, error: String?) {
        let requestedID = params["id"].flatMap { $0.isEmpty ? nil : $0 }
            ?? params["slot"].flatMap { $0.isEmpty ? nil : $0 }
        let id = requestedID ?? "w-" + UUID().uuidString.prefix(8).lowercased()

        // `show <id>` without a URL raises an existing window without
        // reloading it; geometry options still apply.
        if resolveTarget(params) == nil {
            guard let slot = slots[id] else {
                return (nil, "url required to create window '\(id)'")
            }
            if slot.owner != owner && params["force"] != "1" {
                return (nil, "window '\(id)' belongs to owner '\(slot.owner)'")
            }
            var frame = applyGeometry(params, to: slot.window.frame)
            if params["center"] == "1" {
                frame = centered(frame)
            }
            if frame != slot.window.frame {
                slot.window.setFrame(frame, display: true)
            }
            if let floatValue = params["float"] {
                slot.window.level = floatValue == "1" ? .floating : .normal
            }
            slot.window.orderFrontRegardless()
            return (id, nil)
        }

        guard let raw = resolveTarget(params),
              let target = URL(string: raw),
              let scheme = target.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme)
        else {
            return (nil, "invalid or missing url")
        }

        if let slot = slots[id] {
            if slot.owner != owner && params["force"] != "1" {
                return (nil, "window '\(id)' belongs to owner '\(slot.owner)'")
            }
            if let requestedProfile = effectiveProfile(params), requestedProfile != slot.profile {
                return (nil, "window '\(id)' already uses profile '\(slot.profile ?? "default")'")
            }
            slot.urlString = target.absoluteString
            if let title = params["title"], !title.isEmpty {
                slot.window.title = title
            }
            if let fitValue = params["fit"] {
                slot.fit = fitValue != "0"
                if slot.fit {
                    slot.manualZoom = nil
                }
            }
            if let mobileValue = params["mobile"] {
                slot.mobile = mobileValue == "1"
                slot.webView.customUserAgent = slot.mobile ? mobileUserAgent : desktopUserAgent
            }
            var frame = applyGeometry(params, to: slot.window.frame)
            if params["center"] == "1" {
                frame = centered(frame)
            }
            if frame != slot.window.frame {
                slot.window.setFrame(frame, display: true)
            }
            if let floatValue = params["float"] {
                slot.window.level = floatValue == "1" ? .floating : .normal
            }
            slot.webView.pageZoom = 1.0
            load(target, in: slot.webView)
            slot.window.orderFrontRegardless()
            return (id, nil)
        }

        let fit = params["fit"] != "0"
        let mobile = params["mobile"] == "1"

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: params)
        config.userContentController.addUserScript(
            WKUserScript(
                source: Self.findBarScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let webView = DraggableWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = mobile ? mobileUserAgent : desktopUserAgent
        startObserving(webView)

        let window = makeWindow(
            contentRect: frameForNewSlot(id: id, params: params),
            title: params["title"].flatMap { $0.isEmpty ? nil : $0 } ?? id,
            webView: webView
        )
        // Default .normal (makeWindow); agents opt into always-on-top with
        // --float (notify cards, dashboards the user wants always visible).
        window.level = params["float"] == "1" ? .floating : .normal
        window.orderFrontRegardless()

        slots[id] = Slot(
            id: id,
            window: window,
            webView: webView,
            owner: owner,
            profile: effectiveProfile(params),
            urlString: target.absoluteString,
            fit: fit,
            mobile: mobile
        )
        load(target, in: webView)
        return (id, nil)
    }

    /// Builds the chromeless always-on-top window that hosts a web view.
    private func makeWindow(
        contentRect: NSRect,
        title: String,
        webView: WKWebView,
        dragBarEnabled: Bool = true
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // Neutral default (2026-11-13): ordinary stacking level. Callers
        // decide — agent windows opt into .floating via --float, popups
        // inherit their opener. Used to be unconditionally .floating.
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self

        // No traffic lights, no title; content fills the whole window.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true

        let container = NSView(frame: window.contentView?.bounds ?? window.frame)
        container.autoresizingMask = [.width, .height]

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let dragBar = DragBarView(frame: NSRect(
            x: 0,
            y: container.bounds.height - DragBarView.height,
            width: container.bounds.width,
            height: DragBarView.height
        ))
        dragBar.autoresizingMask = [.width, .minYMargin]
        dragBar.isHidden = !dragBarEnabled
        container.addSubview(dragBar)

        window.contentView = container
        return window
    }

    /// Links that request a new window (`target=_blank`, `window.open`):
    /// without Command (⌘) the target replaces the current page; with Command
    /// a new arowser window inherits the opener's owner/profile/fit/mobile.
    /// Returning the web view keeps `window.opener` working.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let opener = slots.values.first(where: { $0.webView === webView })
        else { return nil }

        if !NSEvent.modifierFlags.contains(.command) {
            webView.pageZoom = 1.0
            load(navigationAction.request, in: webView)
            return nil
        }

        let id = "w-" + UUID().uuidString.prefix(8).lowercased()
        let popup = DraggableWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.customUserAgent = opener.mobile ? mobileUserAgent : desktopUserAgent
        startObserving(popup)

        var frame = defaultFrame()
        if let width = windowFeatures.width?.doubleValue,
           let height = windowFeatures.height?.doubleValue,
           width >= 200, height >= 200 {
            frame.size = NSSize(width: width, height: height)
        }

        let window = makeWindow(
            contentRect: centered(frame),
            title: "popup",
            webView: popup,
            dragBarEnabled: opener.dragBarEnabled
        )
        // ⌘-click popups inherit their opener's level: floating opener
        // (notify card) → floating popup; normal opener → normal popup.
        window.level = opener.window.level
        window.orderFrontRegardless()

        slots[id] = Slot(
            id: id,
            window: window,
            webView: popup,
            owner: opener.owner,
            profile: opener.profile,
            urlString: "",
            fit: opener.fit,
            mobile: opener.mobile,
            dragBarEnabled: opener.dragBarEnabled
        )
        writeState()
        return popup
    }

    /// Handles `window.close()` from a popup created above.
    func webViewDidClose(_ webView: WKWebView) {
        for (id, slot) in slots where slot.webView === webView {
            appendHistory(id, slot)
            stopObserving(slot.webView)
            slots.removeValue(forKey: id)
            slot.window.close()
        }
        writeState()
    }

    // MARK: - Context menu

    /// Right-click menu. Both actions act on the right-clicked link when
    /// there is one, otherwise on the current page URL (so right-clicking
    /// blank space copies/opens the page's own address). The trailing
    /// Back/Forward/Reload items replace the default WebKit menu (which
    /// rightMouseDown interception suppresses).
    func presentContextMenu(for webView: WKWebView, event: NSEvent) {
        let point = webView.convert(event.locationInWindow, from: nil)
        let zoom = Double(webView.pageZoom)
        let clientX = Double(point.x) / zoom
        let clientY = Double(webView.bounds.height - point.y) / zoom
        let probe = """
        (function() {
            var el = document.elementFromPoint(\(clientX), \(clientY));
            var a = el && el.closest ? el.closest('a[href]') : null;
            var href = a ? a.href : '';
            return /^https?:|^file:/.test(href) ? href : '';
        })()
        """
        webView.evaluateJavaScript(probe) { [weak self, weak webView] result, _ in
            guard let self, let webView else { return }
            let link = (result as? String)
                .flatMap { $0.isEmpty ? nil : URL(string: $0) }
            self.showContextMenu(for: webView, event: event, link: link)
        }
    }

    private func showContextMenu(for webView: WKWebView, event: NSEvent, link: URL?) {
        let target = link ?? webView.url
        let menu = NSMenu(title: "arowser")
        if let target {
            let copy = NSMenuItem(
                title: "Copy Link",
                action: #selector(copyLinkAddress(_:)),
                keyEquivalent: ""
            )
            copy.target = self
            copy.representedObject = target
            menu.addItem(copy)
            let openExternal = NSMenuItem(
                title: "Open in Default Browser",
                action: #selector(openInDefaultBrowser(_:)),
                keyEquivalent: ""
            )
            openExternal.target = self
            openExternal.representedObject = target
            menu.addItem(openExternal)
            menu.addItem(.separator())
        }
        if slots.count > 1 {
            let windowsItem = NSMenuItem(title: "Windows", action: nil, keyEquivalent: "")
            windowsItem.submenu = windowListMenu()
            menu.addItem(windowsItem)
        }
        let back = NSMenuItem(title: "Back", action: #selector(goBackAction(_:)), keyEquivalent: "[")
        back.target = self
        back.representedObject = webView
        back.isEnabled = webView.canGoBack
        menu.addItem(back)
        let forward = NSMenuItem(title: "Forward", action: #selector(goForwardAction(_:)), keyEquivalent: "]")
        forward.target = self
        forward.representedObject = webView
        forward.isEnabled = webView.canGoForward
        menu.addItem(forward)
        let reload = NSMenuItem(title: "Reload", action: #selector(reloadAction(_:)), keyEquivalent: "r")
        reload.target = self
        reload.representedObject = webView
        menu.addItem(reload)
        if let slot = slots.values.first(where: { $0.webView === webView }) {
            let floatItem = NSMenuItem(
                title: slot.window.level == .floating ? "Unfloat" : "Float on Top",
                action: #selector(toggleFloat(_:)),
                keyEquivalent: ""
            )
            floatItem.target = self
            floatItem.representedObject = webView
            menu.addItem(.separator())
            menu.addItem(floatItem)
            let dragItem = NSMenuItem(
                title: slot.dragBarEnabled ? "Disable Drag Bar" : "Enable Drag Bar",
                action: #selector(toggleDragBar(_:)),
                keyEquivalent: ""
            )
            dragItem.target = self
            dragItem.representedObject = webView
            menu.addItem(dragItem)
            // Window management: act on the RIGHT-CLICKED window (not merely
            // the key one). Close routes through performClose so the normal
            // windowWillClose funnel (history append, cookie mirror save,
            // grace-exit timer) applies — same as ⌘W.
            let hideItem = NSMenuItem(
                title: "Hide Window",
                action: #selector(hideClickedWindow(_:)),
                keyEquivalent: "h"
            )
            hideItem.target = self
            hideItem.keyEquivalentModifierMask = [.command]
            hideItem.representedObject = webView
            menu.addItem(hideItem)
            let closeItem = NSMenuItem(
                title: "Close Window",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
            closeItem.target = slot.window
            closeItem.keyEquivalentModifierMask = [.command]
            menu.addItem(closeItem)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: webView)
    }

    /// Context-menu hide: the right-clicked window only, same effect as ⌘H.
    @objc private func hideClickedWindow(_ sender: NSMenuItem) {
        guard let webView = sender.representedObject as? WKWebView,
              let slot = slots.values.first(where: { $0.webView === webView })
        else { return }
        slot.window.orderOut(nil)
        writeState()
    }

    /// Context-menu float toggle: .floating (always on top, the default) ↔
    /// .normal (regular stacking, other apps may cover it). Cross-Space
    /// following is collectionBehavior and stays. "pinned" in state.json /
    /// history records carries the choice across restores.
    @objc private func toggleFloat(_ sender: NSMenuItem) {
        guard let webView = sender.representedObject as? WKWebView,
              let slot = slots.values.first(where: { $0.webView === webView })
        else { return }
        slot.window.level = slot.window.level == .floating ? .normal : .floating
        writeState()
    }

    /// Shows/hides the 28pt drag strip of one window. With the strip gone the
    /// top area receives page events normally; ⌥+drag still moves the window.
    @objc private func toggleDragBar(_ sender: NSMenuItem) {
        guard let webView = sender.representedObject as? WKWebView,
              let slot = slots.values.first(where: { $0.webView === webView })
        else { return }
        slot.dragBarEnabled.toggle()
        for case let bar as DragBarView in slot.window.contentView?.subviews ?? [] {
            bar.isHidden = !slot.dragBarEnabled
        }
        writeState()
    }

    @objc private func copyLinkAddress(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .URL)
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @objc private func openInDefaultBrowser(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func goBackAction(_ sender: NSMenuItem) {
        (sender.representedObject as? WKWebView)?.goBack()
    }

    @objc private func goForwardAction(_ sender: NSMenuItem) {
        (sender.representedObject as? WKWebView)?.goForward()
    }

    @objc private func reloadAction(_ sender: NSMenuItem) {
        (sender.representedObject as? WKWebView)?.reload()
    }

    private func control(_ params: [String: String], owner: String, action: String) -> (id: String?, error: String?) {
        let id = params["id"] ?? params["slot"] ?? ""
        guard !id.isEmpty else { return (nil, "missing window id") }
        guard let slot = slots[id] else { return (nil, "no such window: '\(id)'") }
        if slot.owner != owner && params["force"] != "1" {
            return (nil, "window '\(id)' belongs to owner '\(slot.owner)'")
        }

        switch action {
        case "hide":
            slot.window.orderOut(nil)
        case "close":
            appendHistory(id, slot)
            stopObserving(slot.webView)
            slots.removeValue(forKey: id)
            slot.window.close()
        case "reload":
            slot.webView.reload()
        default:
            break
        }
        return (id, nil)
    }

    private func load(_ request: URLRequest, in webView: WKWebView) {
        if let url = request.url, url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(request)
        }
    }

    private func load(_ target: URL, in webView: WKWebView) {
        if target.isFileURL {
            // loadFileURL grants read access to the file's directory, which is
            // what relative CSS/JS/images in local reports need.
            webView.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: target))
        }
    }

    private func resolveTarget(_ params: [String: String]) -> String? {
        if let encoded = params["url_b64"], let decoded = decodeBase64URL(encoded), !decoded.isEmpty {
            return decoded
        }
        if let raw = params["url"], !raw.isEmpty {
            return raw
        }
        return nil
    }

    private func decodeBase64URL(_ value: String) -> String? {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 {
            text += "="
        }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Data stores (per-window isolation)

    private func effectiveProfile(_ params: [String: String]) -> String? {
        if params["private"] == "1" { return "private" }
        if let name = params["profile"], !name.isEmpty { return name }
        return nil
    }

    // MARK: - Cookie persistence mirror
    //
    // WebKit only writes cookies WITH an expiry to disk. Session cookies
    // (no Max-Age/Expires — what session-cookie SSO logins hand out) stay in the
    // network process memory and die with the app. Controlled repro
    // (2026-11-12): one fetch login response sets `sid` (session) and
    // `pers` (Max-Age); `pers` lands in every jar's on-disk
    // BinaryCookies, `sid` lands in none — default jar AND named profiles
    // alike. So "default jar loses login on restart" is WebKit session-
    // cookie semantics, not a default-vs-profile split, and switching to
    // --profile does NOT fix it.
    //
    // This mirror closes the gap jar-wide. NOTE: WKHTTPCookieStoreObserver
    // proved unreliable for NETWORK-layer cookie changes — the observer
    // never fired for Set-Cookie from page fetches and the mirror file
    // never appeared (2026-11-12 E2E), so the cache is POLL-driven: every
    // registered store getAllCookies's once a second while any window is
    // alive. Window close / terminate write the cache to Application
    // Support/arowser/cookie-mirror/; store creation re-injects it before
    // the first page load. Private jars are excluded (ephemeral by design).

    private var cookieMirrorStores: [String: WKWebsiteDataStore] = [:]
    private var cookieMirrors: [String: [HTTPCookie]] = [:]
    private var cookieMirrorInjected: Set<String> = []

    private func attachCookieMirror(to store: WKWebsiteDataStore, key: String) {
        if cookieMirrorStores[key] == nil {
            cookieMirrorStores[key] = store
            store.httpCookieStore.getAllCookies { [weak self] cookies in
                self?.cookieMirrors[key] = cookies
            }
        }
        guard cookieMirrorInjected.insert(key).inserted else { return }
        guard let stored = loadCookieMirror(key: key) else { return }
        for cookie in stored {
            store.httpCookieStore.setCookie(cookie)
        }
    }

    private func pollCookieMirrors() {
        guard !slots.isEmpty else { return }
        for (key, store) in cookieMirrorStores {
            store.httpCookieStore.getAllCookies { [weak self] cookies in
                self?.cookieMirrors[key] = cookies
            }
        }
    }

    private func cookieMirrorFile(_ key: String) -> URL? {
        guard let base = stateURL?.deletingLastPathComponent() else { return nil }
        let dir = base.appendingPathComponent("cookie-mirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(key + ".json")
    }

    /// JSON shape: [cookie.properties] with Date → epoch seconds. Session
    /// cookies have no Expires entry at all — that absence is exactly what
    /// survives here and nowhere else.
    private func saveCookieMirrors() {
        for (key, cookies) in cookieMirrors {
            guard cookieMirrorStores[key] != nil else { continue }
            guard let file = cookieMirrorFile(key) else { continue }
            let payload: [[String: Any]] = cookies.map { cookie in
                var dict: [String: Any] = [:]
                for (k, v) in cookie.properties ?? [:] {
                    if let date = v as? Date {
                        dict[k.rawValue] = date.timeIntervalSince1970
                    } else {
                        dict[k.rawValue] = v
                    }
                }
                return dict
            }
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            else { continue }
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path
            )
        }
    }

    private func loadCookieMirror(key: String) -> [HTTPCookie]? {
        guard let file = cookieMirrorFile(key),
              let data = try? Data(contentsOf: file),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        var out: [HTTPCookie] = []
        for dict in raw {
            var props: [HTTPCookiePropertyKey: Any] = [:]
            for (name, value) in dict {
                let key = HTTPCookiePropertyKey(name)
                if name == HTTPCookiePropertyKey.expires.rawValue || name == "Created",
                    let seconds = value as? Double {
                    props[key] = Date(timeIntervalSince1970: seconds)
                } else {
                    props[key] = value
                }
            }
            if let cookie = HTTPCookie(properties: props) { out.append(cookie) }
        }
        return out.isEmpty ? nil : out
    }

    private func dataStore(for params: [String: String]) -> WKWebsiteDataStore {
        if params["private"] == "1" {
            return .nonPersistent()
        }
        if let name = params["profile"], !name.isEmpty {
            if #available(macOS 14.0, *) {
                let store = WKWebsiteDataStore(forIdentifier: profileUUID(name))
                attachCookieMirror(to: store, key: "profile-" + profileUUID(name).uuidString)
                return store
            }
        }
        let store = WKWebsiteDataStore.default()
        attachCookieMirror(to: store, key: "default")
        return store
    }

    private func profileUUID(_ name: String) -> UUID {
        let digest = SHA256.hash(data: Data(name.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Frames

    private func number(_ params: [String: String], _ key: String) -> CGFloat? {
        guard let raw = params[key], let value = Double(raw) else { return nil }
        return CGFloat(value)
    }

    private func applyGeometry(_ params: [String: String], to base: NSRect) -> NSRect {
        var rect = base
        if let x = number(params, "x") { rect.origin.x = x }
        if let w = number(params, "w") { rect.size.width = w }
        if let h = number(params, "h") { rect.size.height = h }
        if let top = number(params, "y") {
            // --x/--y use top-left screen coordinates (same as screenshots and
            // Accessibility); convert to AppKit's bottom-left window origin.
            let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
            let screenHeight = primary?.frame.height ?? 0
            rect.origin.y = screenHeight - top - rect.size.height
        }
        return rect
    }

    private func frameForNewSlot(id: String, params: [String: String]) -> NSRect {
        var rect: NSRect
        var hadSaved = false
        if let saved = UserDefaults.standard.string(forKey: "frame.\(id)") {
            let stored = NSRectFromString(saved)
            if stored.width > 80 && stored.height > 80 {
                rect = stored
                hadSaved = true
            } else {
                rect = defaultFrame()
            }
        } else {
            rect = defaultFrame()
        }

        rect = applyGeometry(params, to: rect)

        if params["center"] == "1" {
            return centered(rect)
        }

        // A brand-new window keeps the top-right anchor for whichever axis was
        // not specified explicitly.
        if !hadSaved {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let bothDefault = params["x"] == nil && params["y"] == nil
            let offset = bothDefault ? CGFloat(cascadeStep % 8) * 24 : 0
            if bothDefault {
                cascadeStep += 1
            }
            if params["x"] == nil {
                rect.origin.x = screen.maxX - rect.width - 24 - offset
            }
            if params["y"] == nil {
                rect.origin.y = screen.maxY - rect.height - 24 - offset
            }
        }
        return rect
    }

    private func centered(_ rect: NSRect) -> NSRect {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var r = rect
        r.origin.x = screen.midX - r.width / 2
        r.origin.y = screen.midY - r.height / 2
        return r
    }

    private func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 460, height: 620)
        return NSRect(
            x: screen.maxX - size.width - 24,
            y: screen.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Delegates

    func windowDidMove(_ notification: Notification) {
        windowGeometryChanged(notification)
    }

    func windowDidResize(_ notification: Notification) {
        windowGeometryChanged(notification)

        guard let window = notification.object as? NSWindow else { return }
        for (id, slot) in slots where slot.window === window && slot.fit && slot.manualZoom == nil {
            scheduleFit(id: id, slot: slot)
        }
    }

    private func scheduleFit(id: String, slot: Slot) {
        pendingFit[id]?.cancel()
        let item = DispatchWorkItem { [weak self, weak slot] in
            guard let self, let slot else { return }
            self.applyFit(slot)
        }
        pendingFit[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func windowGeometryChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        for (id, slot) in slots where slot.window === window {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "frame.\(id)")
        }
        writeState()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // During app termination windows close one by one; each pass would
        // rewrite state.json emptier and destroy the restore snapshot the
        // ⌘Q path just saved. History already has the whole session via the
        // snapshot itself — nothing to append here either.
        guard !isTerminating else { return }
        for (id, slot) in slots where slot.window === window {
            appendHistory(id, slot)
            slots.removeValue(forKey: id)
        }
        writeState()
        // Crash-safety for the cookie mirror: a session cookie earned in a
        // window that later closes while the app keeps running must not
        // depend on a clean app exit to reach disk.
        saveCookieMirrors()

        // Resident mode (default, 2026-11-12): with every window closed the
        // process stays alive so the global hotkeys (⌃⌥⌘L / ⌃⌥⌘K) keep
        // working — the history picker can reopen windows from zero.
        // {"keepAlive": false} in settings.json restores the old auto-exit.
        if slots.isEmpty, !keepAliveEnabled() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.slots.isEmpty else { return }
                NSApp.terminate(nil)
            }
        }
    }

    /// Default true: the app stays running with zero windows (hotkeys and
    /// serve keep working). Explicit exits: ⌘Q (with confirm), CLI
    /// `quit --all`, logout/reboot.
    private func keepAliveEnabled() -> Bool {
        if let flag = settingsObject()?["keepAlive"] as? Bool { return flag }
        return true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        clearLoadError(webView)
        refreshMetadata(for: webView)
        if let slot = slots.values.first(where: { $0.webView === webView }) {
            if let manual = slot.manualZoom {
                slot.webView.pageZoom = manual
                writeState()
            } else {
                applyFit(slot)
            }
        } else {
            writeState()
        }
    }

    /// Committed = the server answered; only a mid-load abort can still fail.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        clearLoadError(webView)
    }

    /// DNS failure / connection refused / missing file land here (the request
    /// never committed). Without handling the window just stays blank white.
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleLoadFailure(webView, error)
    }

    /// The load started but broke mid-way.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(webView, error)
    }

    private func handleLoadFailure(_ webView: WKWebView, _ error: Error) {
        guard let slot = slots.values.first(where: { $0.webView === webView }) else { return }
        let ns = error as NSError
        slot.loadError = "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"
        showLoadErrorOverlay(slot)
        writeState()
    }

    private func clearLoadError(_ webView: WKWebView) {
        guard let slot = slots.values.first(where: { $0.webView === webView }),
              slot.loadError != nil
        else { return }
        slot.loadError = nil
        slot.errorOverlay?.removeFromSuperview()
        slot.errorOverlay = nil
        writeState()
    }

    /// Full-cover dark card over the blank web view: what failed, why, retry.
    /// Native (not injected JS) because a failed page has no scripts running.
    /// Sits above the web view but below the drag bar so the window stays
    /// movable.
    private func showLoadErrorOverlay(_ slot: Slot) {
        let content = slot.window.contentView
        if let overlay = slot.errorOverlay {
            if let text = (overlay.subviews.first(where: { $0 is NSStackView }) as? NSStackView)?
                .views.compactMap({ $0 as? NSTextField })
                .first(where: { $0.tag == 2 }) {
                text.stringValue = slot.loadError ?? ""
            }
            return
        }

        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(
            srgbRed: 0.118, green: 0.118, blue: 0.180, alpha: 1
        ).cgColor  // #1e1e2e, same dark card as the find bar / notify cards

        let title = NSTextField(labelWithString: L("⚠️ Load failed"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = NSColor(srgbRed: 0.8, green: 0.855, blue: 0.957, alpha: 1)  // #cdd6f4

        let urlField = NSTextField(labelWithString: slot.urlString)
        urlField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        urlField.textColor = NSColor(srgbRed: 0.498, green: 0.518, blue: 0.612, alpha: 1)  // #7f849c
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.maximumNumberOfLines = 1
        urlField.tag = 1

        let detail = NSTextField(labelWithString: slot.loadError ?? "")
        detail.font = .systemFont(ofSize: 12, weight: .regular)
        detail.textColor = NSColor(srgbRed: 0.976, green: 0.886, blue: 0.686, alpha: 1)  // #f9e2af
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 0
        detail.tag = 2
        detail.preferredMaxLayoutWidth = 360

        let hint = NSTextField(labelWithString: L("⌘R Retry · ⌘W Close · ⌥+drag to move window"))
        hint.font = .systemFont(ofSize: 10, weight: .regular)
        hint.textColor = NSColor(srgbRed: 0.42, green: 0.44, blue: 0.53, alpha: 1)  // #6c7086

        let stack = NSStackView(views: [title, urlField, detail, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10

        let retry = NSButton(title: L("Retry"), target: self, action: #selector(retryFailedLoad(_:)))
        retry.bezelStyle = .rounded
        retry.controlSize = .regular
        stack.addView(retry, in: .bottom)

        overlay.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        content?.addSubview(
            overlay,
            positioned: .below,
            relativeTo: content?.subviews.first(where: { $0 is DragBarView })
        )
        if let content {
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: content.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
                retry.widthAnchor.constraint(equalToConstant: 80),
            ])
        }
        slot.errorOverlay = overlay
    }

    @objc private func retryFailedLoad(_ sender: NSButton) {
        guard let window = sender.window,
              let slot = slots.values.first(where: { $0.window === window })
        else { return }
        slot.webView.reload()
    }

    /// Scale desktop pages down so their full layout fits the window width.
    /// The measurement is taken at zoom 1; the resulting zoom is capped to
    /// [0.3, 1.0] so text never becomes microscopic.
    private func applyFit(_ slot: Slot) {
        if let manual = slot.manualZoom {
            slot.webView.pageZoom = manual
            writeState()
            return
        }
        guard slot.fit else {
            slot.webView.pageZoom = 1.0
            writeState()
            return
        }
        let viewport = Double(slot.webView.bounds.width)
        guard viewport > 1 else { return }

        slot.webView.pageZoom = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak slot] in
            guard let self, let slot else { return }
            slot.webView.evaluateJavaScript(
                "Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0)"
            ) { result, _ in
                let width = (result as? NSNumber)?.doubleValue ?? 0
                guard width > 1 else { return }
                let zoom = max(0.3, min(1.0, viewport / width))
                slot.webView.pageZoom = zoom
                slot.naturalWidth = width
                self.writeState()
            }
        }
    }

    private func startObserving(_ webView: WKWebView) {
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.title), options: [.new], context: nil)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: [.new], context: nil)
    }

    private func stopObserving(_ webView: WKWebView) {
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if let webView = object as? WKWebView {
            refreshMetadata(for: webView)
            writeState()
            return
        }
        super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }

    private func refreshMetadata(for webView: WKWebView) {
        for (_, slot) in slots where slot.webView === webView {
            if let url = webView.url?.absoluteString, !url.isEmpty {
                slot.urlString = url
            }
            if let title = webView.title, !title.isEmpty {
                slot.pageTitle = title
                if slot.window.subtitle != title {
                    slot.window.subtitle = title
                }
            }
        }
    }
}

@main
enum ArowserMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
