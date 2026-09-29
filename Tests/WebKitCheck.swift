import AppKit
import WebKit

// Executa a MESMA montagem de HTML que a extensão e reporta o resultado.
// Fora do Quick Look, para separar "WebKit quebrado no ambiente" de "WebKit
// indisponível dentro de uma extensão de preview".
final class WebKitCheck: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    private let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("webkitcheck.log")
    private var webView: WKWebView!

    private func log(_ s: String) {
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close()
        } else { try? Data(line.utf8).write(to: logURL) }
    }

    private func resourceDirectory() -> URL? {
        let base = URL(fileURLWithPath: "/Users/alt-zz/projetos/md-previewer/Resources")
        return FileManager.default.fileExists(atPath: base.appendingPathComponent("preview.html").path) ? base : nil
    }

    private func makeHTML(markdown: String) -> String? {
        guard let base = resourceDirectory(),
              var html = try? String(contentsOf: base.appendingPathComponent("preview.html"), encoding: .utf8)
        else { return nil }

        for (placeholder, file) in [("{{THEME_CSS}}", "theme.css"),
                                    ("{{MARKED_JS}}", "vendor/marked.min.js"),
                                    ("{{PURIFY_JS}}", "vendor/purify.min.js"),
                                    ("{{HIGHLIGHT_JS}}", "vendor/highlight.min.js")] {
            guard let c = try? String(contentsOf: base.appendingPathComponent(file), encoding: .utf8) else { return nil }
            html = html.replacingOccurrences(of: placeholder, with: c)
        }
        return html.replacingOccurrences(of: "{{MARKDOWN_B64}}",
                                        with: Data(markdown.utf8).base64EncodedString())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let markdown = "# Titulo\n\n**negrito** e `codigo`\n\n```swift\nlet x = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        guard let html = makeHTML(markdown: markdown) else { log("ERRO makeHTML"); exit(1) }
        log("html=\(html.count) chars")

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "mdPreview")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        webView.navigationDelegate = self

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = webView
        w.makeKeyAndOrderFront(nil)
        webView.loadHTMLString(html, baseURL: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            self.webView.evaluateJavaScript(
                "(document.getElementById('content')||{innerHTML:''}).innerHTML.length") { v, e in
                self.log("conteudo=\(v.map(String.init(describing:)) ?? "nil") erro=\(e?.localizedDescription ?? "-")")
                NSApp.terminate(nil)
            }
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let p = message.body as? [String: Any] ?? [:]
        log("CALLBACK status=\(p["status"] ?? "?") html=\(p["htmlChars"] ?? 0) codigo=\(p["codeBlocks"] ?? 0) msg=\(p["mensagem"] ?? "-")")
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { log("didFinish") }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { log("didFail \(e.localizedDescription)") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { log("didFailProv \(e.localizedDescription)") }
}

let app = NSApplication.shared
let d = WebKitCheck()
app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
