import AppKit
import Foundation

// Renderiza um Markdown e imprime o resultado, para conferir o layout sem
// passar pelo Quick Look. Reaproveita o mesmo código da extensão.
@main
struct RenderCheck {
    static func main() {
        let path = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath + "/Samples/sample.md"

        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("ERRO: não li \(path)"); exit(1)
        }
        let markdown = stripFrontMatter(raw)

        // A URL do documento é o que permite resolver imagens relativas; sem
        // ela o renderer não tem onde procurar.
        let documentURL = URL(fileURLWithPath: path)
        let output = NativeMarkdownRenderer.render(markdown, documentURL: documentURL)

        // Visão em texto puro, com os mesmos caracteres de controle, para
        // ver onde os blocos separam e como ficam alinhados.
        let text = output.string
        print("=== \(text.count) chars, \(output.length) unidades ===")
        print(text)
        print("=== fim ===")

        // Confere fontes e cores aplicadas, para garantir que o estilo entrou.
        var fonts: Set<String> = []
        output.enumerateAttribute(.font, in: NSRange(location: 0, length: output.length)) { value, _, _ in
            if let f = value as? NSFont { fonts.insert("\(f.fontName)@\(f.pointSize)") }
        }
        print("fontes: \(fonts.sorted().joined(separator: ", "))")

        // As imagens é o que se quer conferir: attachment presente e com o
        // tamanho esperado, ou o texto alternativo quando o arquivo falta.
        var attachments = 0
        output.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: output.length)
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachments += 1
            print(String(
                format: "imagem %d: %@ pontos",
                attachments,
                NSStringFromSize(attachment.bounds.size)
            ))
        }
        print("imagens embutidas: \(attachments) de \(MarkdownImageScanner.scan(markdown).count) encontradas")
    }

    private static func stripFrontMatter(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        lines.removeFirst()
        for i in lines.indices where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(i + 1)...].joined(separator: "\n")
        }
        return text
    }
}
