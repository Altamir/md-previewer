import Foundation
import WebKit

/// Serve imagens relativas ao `.md` via o esquema `mdasset://`.
///
/// A webview não enxerga o disco fora do bundle da extensão, então o renderer no
/// JS reescreve `img.src` para `mdasset://img/<base64url(caminho)>` e este handler
/// devolve os bytes.
///
/// Tudo é confinado ao diretório do arquivo Markdown: um `../../.ssh/id_rsa`
/// resolve para fora do diretório e vira 404, deixando o `<img>` quebrar em vez de
/// servir um arquivo arbitrário.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {

    private static let scheme = "mdasset"
    static let schemeName = scheme

    private let root: URL

    /// - Parameter root: diretório do arquivo Markdown em preview.
    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func install(in webView: WKWebView, root: URL) {
        let configuration = webView.configuration
        configuration.setURLSchemeHandler(AssetSchemeHandler(root: root), forURLScheme: scheme)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask)
            return
        }

        guard let fileURL = decode(url) else {
            fail(urlSchemeTask)
            return
        }

        let data = try? Data(contentsOf: fileURL)
        guard let data else {
            fail(urlSchemeTask)
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(for: fileURL.pathExtension),
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Leitura síncrona e curta; nada a cancelar.
    }

    /// `mdasset://img/<base64url>` → URL local, se estiver dentro de `root`.
    private func decode(_ url: URL) -> URL? {
        guard url.scheme == Self.scheme, url.host == "img" else { return nil }

        var encoded = url.path
        if encoded.hasPrefix("/") { encoded.removeFirst() }
        guard let data = Data(base64Encoded: encoded),
              let path = String(data: data, encoding: .utf8) else { return nil }

        // URL(fileURLWithPath:) resolve ".." manualmente, mas sem normalizar o
        // resultado; o standardized + resolvingSymlinks abaixo é o que de fato
        // impede o escape via "..", link simbólico ou barra duplicada.
        let candidate = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard isInsideRoot(candidate) else { return nil }
        return candidate
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let rootPath = root.path
        let filePath = url.path
        if filePath == rootPath { return false }
        return filePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// Resposta vazia. Para o `<img>` interessa apenas que a task termine: o
    /// navegador desenha o alt e segue, sem distinguir "não encontrado" de
    /// "caminho inválido" — os dois significam "não dá para mostrar".
    private func fail(_ task: WKURLSchemeTask) {
        let response = URLResponse(
            url: task.request.url ?? URL(fileURLWithPath: "/"),
            mimeType: "text/plain",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didFinish()
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}
