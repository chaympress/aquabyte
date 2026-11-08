// Aquabyte — frameless macOS desktop widget
// build: swiftc -O -framework Cocoa -framework WebKit pet.swift -o aquabyte-pet
import Cocoa
import WebKit

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var app: App?
    func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let d = msg.body as? [String: Any] else { return }
        if let mv = d["move"] as? [Double], mv.count == 2, let w = app?.window {
            var p = w.frame.origin
            p.x += CGFloat(mv[0])
            p.y -= CGFloat(mv[1])
            w.setFrameOrigin(p)
        }
        if d["panel"] as? Bool == true { app?.show("panel") }
        if d["pet"] as? Bool == true { app?.show("pet") }
        if d["close"] as? Bool == true { NSApp.terminate(nil) }
    }
}

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    let bridge = Bridge()
    var dir: URL!
    var watcher: Process?
    var pipeBuf = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        dir = exe.deletingLastPathComponent()

        let cfg = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.add(bridge, name: "pet")
        let glue = "window.pet={move:function(x,y){window.webkit.messageHandlers.pet.postMessage({move:[x,y]});},close:function(){window.webkit.messageHandlers.pet.postMessage({close:true});},panel:function(){window.webkit.messageHandlers.pet.postMessage({panel:true});},pet:function(){window.webkit.messageHandlers.pet.postMessage({pet:true});}};"
        uc.addUserScript(WKUserScript(source: glue, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = uc

        let rect = NSRect(x: 0, y: 0, width: 150, height: 186)
        window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bridge.app = self

        web = WKWebView(frame: rect, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = .clear
        }
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.clear.cgColor
        if let inner = web.subviews.first {
            inner.wantsLayer = true
            inner.layer?.backgroundColor = NSColor.clear.cgColor
        }
        window.contentView = web

        if let scr = NSScreen.main {
            let f = scr.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.maxX - 168, y: f.minY + 26))
        }
        load("pet")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        startWatcher()
    }

    func langCode() -> String {
        let home = NSHomeDirectory()
        var path = home + "/.aquabyte.json"
        if !FileManager.default.fileExists(atPath: path) { path = home + "/.ai-bottle.json" }
        if let data = FileManager.default.contents(atPath: path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let l = obj["lang"] as? String, !l.isEmpty {
            return String(l.prefix(2)).lowercased()
        }
        let code = (Locale.preferredLanguages.first ?? "en").prefix(2)
        return String(code).lowercased()
    }

    func load(_ mode: String) {
        let page = dir.appendingPathComponent("web/index.html")
        var comp = URLComponents(url: page, resolvingAgainstBaseURL: false)
        let base = (mode == "panel") ? "panel=1&electron=1" : "electron=1"
        comp?.query = base + "&lang=" + langCode()
        if let u = comp?.url {
            web.loadFileURL(u, allowingReadAccessTo: dir)
        }
    }

    func show(_ mode: String) {
        let w: CGFloat = (mode == "panel") ? 372 : 150
        let h: CGFloat = (mode == "panel") ? 372 : 186
        var f = window.frame
        let ax = f.maxX, ay = f.maxY
        f.size = NSSize(width: w, height: h)
        f.origin = NSPoint(x: ax - w, y: ay - h)
        window.setFrame(f, display: true)
        web.frame = NSRect(x: 0, y: 0, width: w, height: h)
        load(mode)
    }

    func startWatcher() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-u", self.dir.appendingPathComponent("web/collect.py").path, "--watch"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let self = self else { return }
            let d = fh.availableData
            if d.isEmpty { return }
            self.pipeBuf += String(data: d, encoding: .utf8) ?? ""
            while let r = self.pipeBuf.range(of: "\n") {
                let line = String(self.pipeBuf[self.pipeBuf.startIndex..<r.lowerBound])
                self.pipeBuf = String(self.pipeBuf[r.upperBound...])
                guard let sb = line.range(of: "{"),
                      let eb = line.range(of: "}", options: .backwards) else { continue }
                let json = String(line[sb.lowerBound..<eb.upperBound])
                DispatchQueue.main.async {
                    self.web.evaluateJavaScript("window.__setLive&&window.__setLive(\(json))", completionHandler: nil)
                }
            }
        }
        do {
            try p.run()
            self.watcher = p
        } catch {
            self.watcher = nil
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        watcher?.terminate()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
