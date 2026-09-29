import Foundation

/// Localiza imagens no Markdown por conta própria.
///
/// O parser da Apple não é opção aqui: `AttributedString(markdown:)` com
/// `interpretedSyntax: .full` **descarta** o nó de imagem. Medido no parser
/// (ver README, "O renderer nativo"), `![alt](dir/arquivo.png)` volta como um
/// parágrafo qualquer cujo texto é só o alt — sem `run.link`, sem marca de
/// imagem, sem o caminho. Não há, portanto, nada para o renderer nativo
/// estilar: a detecção tem que acontecer antes, sobre o texto-fonte.
enum MarkdownImageScanner {

    /// Uma imagem localizada no texto.
    ///
    /// O `range` é o do **trecho exato** que a imagem ocupa no Markdown
    /// original — do `!` até o `)` —, para que a substituição seja uma fatiagem
    /// direta e não uma busca que pode acertar a ocorrência errada quando o
    /// mesmo `![...](...)` aparece duas vezes.
    struct Image {
        let range: Range<String.Index>
        /// Caminho escrito no Markdown, ainda sem resolver.
        let source: String
        /// Texto alternativo, já decodificado das entidades HTML.
        let alt: String
        /// Título opcional (`![alt](src "título")`).
        let title: String?
        /// Fonte em itálico, quando a imagem está cercada por `*`.
        let isEmphasized: Bool
    }

    /// Varre o documento inteiro e devolve as imagens em ordem de aparição.
    static func scan(_ markdown: String) -> [Image] {
        var found: [Image] = []
        for block in blocks(of: markdown) {
            found.append(contentsOf: images(in: markdown, block: block))
        }
        return found
    }

    // MARK: - Blocos
    //
    // Só é preciso saber onde cada bloco começa e termina para **não** tratar
    // como imagem o que está dentro de um bloco verbatim. Dentro de um bloco
    // normal a busca por `![]` é segura; num bloco de código, um `![...](...)`
    // é só texto.

    /// Devolve os ranges de conteúdo de cada bloco do documento.
    ///
    /// O range é o **conteúdo** do bloco, sem as linhas em branco que o
    /// separavam do anterior, e sem a indentação: é o texto que o parser
    /// receberia, e é nele que a sintaxe de imagem vale.
    private static func blocks(of markdown: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var blockStart = markdown.startIndex
        var cursor = markdown.startIndex
        var insideFence = false

        while cursor < markdown.endIndex {
            // A linha vai até o próximo `\n`; sem ele, é a última do arquivo.
            let lineEnd = markdown[cursor...].firstIndex(of: "\n") ?? markdown.endIndex
            let line = markdown[cursor..<lineEnd]
            let nextLineStart = lineEnd < markdown.endIndex
                ? markdown.index(after: lineEnd)
                : markdown.endIndex

            // Uma cerca de código alterna o estado: na abertura o bloco atual
            // fecha e começa o verbatim; no fechamento o verbatim termina.
            // Uma linha em branco só fecha bloco quando estamos fora de um.
            if isFenceLine(line) {
                if insideFence {
                    insideFence = false
                } else {
                    appendBlock(markdown, from: blockStart, to: cursor, to: &result)
                    insideFence = true
                }
                blockStart = nextLineStart
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !insideFence {
                    appendBlock(markdown, from: blockStart, to: cursor, to: &result)
                }
                blockStart = nextLineStart
            }
            // Dentro de um bloco normal ou de um verbatim aberto a linha faz
            // parte do bloco atual, então só o cursor avança.

            cursor = nextLineStart
        }

        if !insideFence {
            appendBlock(markdown, from: blockStart, to: markdown.endIndex, to: &result)
        }
        return result
    }

    private static func appendBlock(
        _ markdown: String,
        from start: String.Index,
        to end: String.Index,
        to result: inout [Range<String.Index>]
    ) {
        guard let content = contentRange(markdown, from: start, to: end) else { return }
        result.append(content)
    }

    /// Um bloco delimitado por ``` ou ~~~: dentro dele nada é Markdown.
    private static func isFenceLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// Corta a indentação comum às linhas do bloco e devolve o range do
    /// conteúdo resultante, em índices da string original.
    private static func contentRange(
        _ markdown: String,
        from start: String.Index,
        to end: String.Index
    ) -> Range<String.Index>? {
        guard start < end else { return nil }

        var lines = markdown[start..<end].split(
            separator: "\n", omittingEmptySubsequences: false
        )
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        let indent = lines
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
            .min() ?? 0

        var contentStart = start
        var contentEnd = end
        if indent > 0 {
            contentStart = markdown.index(start, offsetBy: indent)
            // O fim também sobe: a última linha não tem `\n` antes dela, então
            // o offset do fim é o do bloco menos a indentação da última linha.
            let lastLine = lines[lines.count - 1]
            let tailIndent = min(indent, lastLine.prefix(while: { $0 == " " || $0 == "\t" }).count)
            contentEnd = markdown.index(end, offsetBy: -tailIndent)
        }
        return contentStart..<contentEnd
    }

    // MARK: - Sintaxe de imagem

    /// Procura imagens dentro de um bloco, devolvendo ranges em índices da
    /// string **original** — o bloco é uma fatia, então todo índice local
    /// precisa ser deslocado de volta.
    private static func images(
        in markdown: String,
        block: Range<String.Index>
    ) -> [Image] {
        let paragraph = String(markdown[block])
        let offset = block.lowerBound

        var result: [Image] = []
        var index = paragraph.startIndex

        while index < paragraph.endIndex {
            // O `!` é procurado fora do guard porque um `guard` não expõe as
            // próprias bindings no `else` — e é no `else` que o índice avança
            // quando o candidato não é uma imagem.
            guard let opener = paragraph[index...].firstIndex(of: "!") else { break }
            guard let parsed = parseImage(paragraph, at: opener) else {
                index = paragraph.index(after: opener)
                continue
            }

            // O índice local vira global somando o deslocamento do bloco, que é
            // onde a string original começa.
            let distance = paragraph.distance(from: paragraph.startIndex, to: parsed.end)
            result.append(Image(
                range: offset..<markdown.index(offset, offsetBy: distance),
                source: parsed.source,
                alt: decodeEntities(parsed.alt),
                title: parsed.title,
                isEmphasized: parsed.isEmphasized
            ))

            index = parsed.end
        }
        return result
    }

    private struct ParsedImage {
        let alt: String
        let source: String
        let title: String?
        let isEmphasized: Bool
        /// Índice logo depois do `)` que fecha o destino.
        let end: String.Index
    }

    /// Interpreta `![alt](destino)` a partir do `!`, sem o consumir. Devolve
    /// `nil` quando o trecho não é uma imagem.
    private static func parseImage(_ text: String, at opener: String.Index) -> ParsedImage? {
        guard isPlainText(before: opener, in: text),
              let bracket = text[opener...].firstIndex(of: "["),
              opener < bracket,
              let closeBracket = matchingBracket(text, open: bracket),
              closeBracket < text.endIndex
        else { return nil }

        let afterBracket = text.index(after: closeBracket)
        guard afterBracket < text.endIndex,
              text[afterBracket] == "(",
              let closeParen = matchingParenthesis(text, open: afterBracket)
        else { return nil }

        let alt = String(text[text.index(after: bracket)..<closeBracket])
        let destination = String(text[text.index(after: afterBracket)..<closeParen])
        let (source, title) = splitDestination(destination)

        // O `*` só é itálico quando não for a abertura de `**`.
        let end = text.index(after: closeParen)
        let isEmphasized = text[..<opener].hasSuffix("*") && !text[..<opener].hasSuffix("**")
            && text[end...].hasPrefix("*") && !text[end...].hasPrefix("**")

        return ParsedImage(
            alt: alt,
            source: source,
            title: title,
            isEmphasized: isEmphasized,
            end: end
        )
    }

    /// O `]` que fecha é o que zera o contador de profundidade aberto pelo `[`.
    private static func matchingBracket(_ text: String, open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: text.index(after: index))
                continue
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func matchingParenthesis(_ text: String, open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: text.index(after: index))
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Um `!` só abre imagem quando não está escaped nem colado num `[`.
    private static func isPlainText(before index: String.Index, in text: String) -> Bool {
        guard let last = text[..<index].last else { return true }
        return last != "!" && last != "["
    }

    /// `destino "título"` → o caminho e o título separados; sem título, o
    /// destino é o que sobrar.
    private static func splitDestination(_ destination: String) -> (String, String?) {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        // <ângulo> — a forma que permite espaços no caminho.
        if trimmed.hasPrefix("<"), let end = trimmed.firstIndex(of: ">") {
            let source = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let rest = trimmed[trimmed.index(after: end)...]
                .trimmingCharacters(in: .whitespaces)
            return (decodeEntities(source), rest.isEmpty ? nil : unquote(rest))
        }

        // Só é título se o resto inteiro couber entre aspas.
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") {
            let quote = trimmed.first!
            if let end = trimmed.dropFirst().firstIndex(of: quote) {
                let title = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
                let rest = trimmed[trimmed.index(after: end)...]
                    .trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    return (unquote(title), nil)
                }
            }
        }

        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (unquote(trimmed), nil)
        }
        let source = String(trimmed[trimmed.startIndex..<space])
        let title = String(trimmed[trimmed.index(after: space)...])
            .trimmingCharacters(in: .whitespaces)
        return (unquote(source), title.isEmpty ? nil : unquote(title))
    }

    private static func unquote(_ value: String) -> String {
        var result = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
        if result.count >= 2 {
            let first = result.first!
            let last = result.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                result = result.dropFirst().dropLast()
            }
        }
        return decodeEntities(String(result))
    }

    /// Resolve as entidades que o marked resolveria: o alt de uma imagem
    /// normalmente vem com `&amp;` e `&#39;`, e mostrá-los crus seria um
    /// defeito visível.
    private static func decodeEntities(_ value: String) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "&",
                  let semicolon = value[index...].firstIndex(of: ";"),
                  value.distance(from: index, to: semicolon) <= 12 else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }
            let entity = String(value[value.index(after: index)..<semicolon])
            if let resolved = resolveEntity(entity) {
                result += resolved
                index = value.index(after: semicolon)
            } else {
                result.append(value[index])
                index = value.index(after: index)
            }
        }
        return result
    }

    private static func resolveEntity(_ entity: String) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: break
        }
        guard entity.hasPrefix("#") else { return nil }

        let body = entity.dropFirst()
        let value: UInt32?
        if body.hasPrefix("x") || body.hasPrefix("X") {
            value = UInt32(body.dropFirst(), radix: 16)
        } else {
            value = UInt32(body, radix: 10)
        }
        guard let value, let scalar = UnicodeScalar(value) else { return nil }
        return String(scalar)
    }
}
