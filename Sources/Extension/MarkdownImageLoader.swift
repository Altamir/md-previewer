import AppKit
import Foundation

/// Carrega imagens relativas ao `.md` em preview e devolve `NSImage` pronta
/// para o `NSTextView` desenhar.
///
/// Duas regras valem para todo caminho resolvido aqui:
///
/// - **Confinamento.** O arquivo só pode vir do diretório do próprio Markdown,
///   ou de um subdiretório dele. `../` e link simbólico para fora continuam
///   barrados, como já acontece no esquema `mdasset://` do motor web — o
///   preview não deve abrir um `~/.ssh/id_rsa` a partir de um `.md` que veio
///   da internet.
/// - **Sem acesso fora do escopo.** O `previewItemURL` chega security-scoped;
///   a leitura precisa acontecer entre start/stop, como em `MarkdownDocument`.
enum MarkdownImageLoader {

    /// Teto absoluto para o maior lado, em pontos. Vale quando a largura da
    /// coluna não é conhecida — sem isso, um PNG de 8000px viraria um bitmap
    /// gigante em memória por causa de um preview.
    static let maximumSide: CGFloat = 1600

    /// Carrega a imagem apontada em `source`, que está escrito no Markdown e
    /// ainda não foi resolvido. Devolve `nil` quando não dá para usar.
    ///
    /// - Parameter maximumWidth: largura disponível para a coluna. A imagem é
    ///   reduzida proporcionalmente quando for mais larga, mantendo a proporção
    ///   para não distorcer.
    static func load(
        source: String,
        relativeTo documentURL: URL,
        maximumWidth: CGFloat? = nil
    ) -> NSImage? {
        guard let url = resolve(source: source, relativeTo: documentURL) else {
            Trace.log("imagem fora do escopo ou caminho invalido: \(source)")
            return nil
        }

        // O `previewItemURL` autoriza **só** o arquivo em preview. Um `.png`
        // vizinho fica fora do escopo: `startAccessing…` devolve `false` e a
        // leitura é negada pelo sandbox. Medido dentro da extensão — o vizinho
        // aparece como `existe=true legivel=false`, e criar um bookmark de
        // security scope para ele também falha, porque criar o bookmark já
        // exige o acesso que se quer conquistar. Desligar o sandbox resolve,
        // mas quebra a extensão por completo (ela nem carrega), então o
        // caminho é outro: dar um poder de leitura ao diretório inteiro.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let image = NSImage(contentsOf: url) else {
            let denied = readError(url)
            Trace.log("imagem nao lida: \(url.lastPathComponent) "
                      + "existe=\(FileManager.default.fileExists(atPath: url.path)) "
                      + "erro=\(denied?.localizedDescription ?? "?")")
            return nil
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        var size = image.size
        // A largura da coluna tem precedência: é ela que decide se a imagem
        // cabe. O teto do maior lado cobre o caso em que a coluna ainda não
        // tem largura conhecida.
        if let maximumWidth, maximumWidth > 0, size.width > maximumWidth {
            size.width = maximumWidth
            size.height = (size.height * maximumWidth / image.size.width).rounded()
        }
        if max(size.width, size.height) > maximumSide {
            let scale = maximumSide / max(size.width, size.height)
            size.width = (size.width * scale).rounded()
            size.height = (size.height * scale).rounded()
        }
        if size != image.size { image.size = size }
        return image
    }

    /// Resolve o caminho escrito no Markdown contra o diretório do arquivo,
    /// rejeitando o que sai dele.
    static func resolve(source: String, relativeTo documentURL: URL) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // URL absoluta, ou com esquema: não é asset local, o parser nativo não
        // tem como buscá-la e fingir que tem só produziria um buraco.
        if trimmed.contains("://") { return nil }
        if trimmed.hasPrefix("data:") { return nil }

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
        guard isInside(root, candidate) else { return nil }
        return candidate
    }

    /// Lê o arquivo de novo, agora capturando o erro, para o log dizer *por
    /// que* a imagem não entrou. É o caminho de diagnóstico; o render mesmo
    /// usa `NSImage(contentsOf:)`.
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
