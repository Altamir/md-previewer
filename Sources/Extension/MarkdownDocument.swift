import Foundation

/// Leitura e limpeza de um arquivo Markdown vindo do Finder.
enum MarkdownDocument {

    enum LoadError: LocalizedError {
        case unreadable(URL, underlying: Error?)
        case notUTF8(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url, let underlying):
                if let underlying {
                    return "Não foi possível ler \(url.lastPathComponent): \(underlying.localizedDescription)"
                }
                return "Não foi possível ler \(url.lastPathComponent)."
            case .notUTF8(let url):
                return "\(url.lastPathComponent) não está em UTF-8 válido."
            }
        }
    }

    /// Lê o arquivo de forma segura dentro do sandbox da extensão.
    ///
    /// O `previewItemURL` chega security-scoped, então o acesso precisa acontecer
    /// entre start/stop. `NSFileCoordinator` cobre o caso de edição concorrente
    /// pelo Finder durante a leitura.
    static func load(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var readError: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &readError
        ) { coordinatedURL in
            data = try? Data(contentsOf: coordinatedURL)
        }

        if let readError {
            throw LoadError.unreadable(url, underlying: readError)
        }
        guard let data else {
            throw LoadError.unreadable(url, underlying: nil)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoadError.notUTF8(url)
        }
        return text
    }

    /// Remove o bloco YAML de front matter no topo do arquivo.
    ///
    /// Só remove quando o arquivo realmente começa com `---` numa linha própria e
    /// existe um `---` de fechamento — senão um `---` solto no meio do texto seria
    /// tratado como delimitador e o resto do arquivo sumiria. Um BOM UTF-8 inicial
    /// também conta, porque alguns editores gravam com ele.
    static func stripFrontMatter(_ text: String) -> String {
        var body = Substring(text)
        if body.first == "\u{FEFF}" {
            body = body.dropFirst()
        }

        guard body.hasPrefix("---") else { return String(body) }

        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        // A primeira linha precisa ser exatamente o marcador, não algo como "--- foo".
        guard let first = lines.first, isFrontMatterFence(first) else { return String(body) }
        lines.removeFirst()

        for index in lines.indices {
            if isFrontMatterFence(lines[index]) {
                return lines[(index + 1)...].joined(separator: "\n")
            }
        }
        // Abreu `---` mas nunca fechou: não é front matter, deixa o texto como está.
        return String(body)
    }

    private static func isFrontMatterFence(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "---"
    }
}
