import AppKit
import Foundation

/// Carrega imagens do Markdown para o `NSTextView` desenhar.
///
/// Duas origens, e elas têm destinos bem diferentes no preview do Quick Look:
///
/// - **data URI** (`![alt](data:image/png;base64,…)`) — os bytes estão dentro
///   do próprio `.md`, e o arquivo em preview é a única coisa que o sandbox
///   deixa abrir. Esta é a forma que **funciona dentro da extensão**.
/// - **caminho relativo** (`![alt](img/a.png)`) — depende de acesso ao disco
///   que o Quick Look não concede (medido: `existe=true legivel=false` no log).
///   Funciona fora da extensão, e numa instalação onde o sistema conceda acesso
///   ao diretório também funciona aqui.
///
/// Confinamento: um caminho relativo só é aceito dentro do diretório do próprio
/// Markdown, depois de `standardizedFileURL` + `resolvingSymlinksInPath` — o
/// mesmo do esquema `mdasset://` do motor web. Um `../` ou link simbólico para
/// fora é barrado. Um data URI não toca o disco, então essa regra não se
/// aplica a ele.
enum MarkdownImageLoader {

    /// Teto absoluto para o maior lado, em pontos, para o caso em que a coluna
    /// ainda não tem largura conhecida. Sem isto um PNG de 8000px viraria um
    /// bitmap gigante por causa de um preview.
    static let maximumSide: CGFloat = 1600

    /// Carrega a imagem apontada em `source`. Devolve `nil` quando não dá para
    /// usar, e o render mostra o texto alternativo nesse caso.
    ///
    /// - Parameter maximumWidth: largura disponível para a coluna. A imagem é
    ///   reduzida proporcionalmente quando for mais larga.
    static func load(
        source: String,
        relativeTo documentURL: URL,
        maximumWidth: CGFloat? = nil
    ) -> NSImage? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let data: Data
        if trimmed.lowercased().hasPrefix("data:") {
            guard let decoded = decodeDataURI(trimmed) else {
                Trace.log("data URI invalida (\(trimmed.count) chars)")
                return nil
            }
            data = decoded
        } else {
            guard let url = resolve(source: trimmed, relativeTo: documentURL) else {
                return nil
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let read = try? Data(contentsOf: url) else {
                Trace.log("imagem nao lida: \(url.lastPathComponent) "
                          + "existe=\(FileManager.default.fileExists(atPath: url.path)) "
                          + "erro=\(readError(url)?.localizedDescription ?? "?")")
                return nil
            }
            data = read
        }

        guard let image = NSImage(data: data) else {
            Trace.log("bytes nao sao uma imagem reconhecida (\(data.count) bytes)")
            return nil
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let size = fitted(image.size, to: maximumWidth)
        if size != image.size { image.size = size }
        return image
    }

    /// Resolve o caminho escrito no Markdown contra o diretório do arquivo,
    /// rejeitando o que sai dele.
    static func resolve(source: String, relativeTo documentURL: URL) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // URL com esquema não é asset local, e o parser nativo não tem como
        // buscá-la. `data:` é tratada antes, em `load`.
        if trimmed.contains("://") { return nil }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if decoded.hasPrefix("/") { return nil } // fora do diretório por definição

        let root = documentURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let candidate: URL
        if decoded.lowercased().hasPrefix("file:") {
            guard let url = URL(string: decoded) else { return nil }
            candidate = url.standardizedFileURL
        } else {
            candidate = URL(fileURLWithPath: decoded, relativeTo: root)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }

        // O `standardized` resolve "..", mas o `resolvingSymlinksInPath` é o que
        // fecha o caso do link simbólico que aponta para fora: ele é aplicado
        // depois, sobre o caminho já normalizado.
        guard isInside(root, candidate) else {
            Trace.log("caminho fora do diretorio do .md: \(source)")
            return nil
        }
        return candidate
    }

    // MARK: - Data URI

    /// `data:image/png;base64,AAA…` → bytes da imagem.
    ///
    /// É o caminho que funciona dentro da extensão Quick Look: os bytes estão
    /// no próprio arquivo em preview, que é o único que o sandbox libera.
    private static func decodeDataURI(_ uri: String) -> Data? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(after: uri.startIndex)..<comma]
        let payload = String(uri[uri.index(after: comma)...])

        let isBase64 = header
            .lowercased()
            .split(separator: ";")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "base64" }

        if isBase64 {
            // Espaço e quebra de linha são ruído no base64 e não no dado: um
            // Markdown com imagem embutida costuma partir o payload em linhas
            // de 76 colunas, e o scanner entrega o trecho ainda partido.
            let cleaned = payload.filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters])
        }
        return payload.removingPercentEncoding.map { Data($0.utf8) }
    }

    // MARK: - Tamanho

    private static func fitted(_ size: NSSize, to maximumWidth: CGFloat?) -> NSSize {
        var result = size
        // A largura da coluna tem precedência: é ela que decide se a imagem
        // cabe, e o TextKit corta o que transbordar.
        if let maximumWidth, maximumWidth > 0, result.width > maximumWidth {
            result.height = (result.height * maximumWidth / size.width).rounded()
            result.width = maximumWidth
        }
        if max(result.width, result.height) > maximumSide {
            let scale = maximumSide / max(result.width, result.height)
            result.width = (result.width * scale).rounded()
            result.height = (result.height * scale).rounded()
        }
        return result
    }

    /// Relê o arquivo para capturar o erro, só para o log dizer *por que* a
    /// imagem não entrou. O render usa o `Data(contentsOf:)` acima.
    private static func readError(_ url: URL) -> NSError? {
        do {
            _ = try Data(contentsOf: url)
            return nil
        } catch {
            return error as NSError
        }
    }

    private static func isInside(_ root: URL, _ candidate: URL) -> Bool {
        let rootPath = root.path
        let path = candidate.path
        if path == rootPath { return false }
        return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
