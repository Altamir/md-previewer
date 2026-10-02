import AppKit
import Foundation

/// Confere o caminho que **funciona dentro do Quick Look**: a imagem embutida
/// no próprio Markdown, em data URI.
///
/// O caminho relativo é barrado pelo sandbox — o poder vai só para o arquivo em
/// preview — então a única forma de a imagem aparecer no Finder é o `.md`
/// trazer os bytes junto. Este teste cobre esse caminho inteiro: decodificar o
/// URI, tolerar o base64 partido em linhas, manter a barreira de `..` fechada e
/// emitir o attachment no render.
///
///     make datacheck
@main
struct DataURICheck {
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath + "/Samples")
        let doc = root.appendingPathComponent("sample.md")

        // O PNG real do projeto. Um PNG gerado à mão costuma sair com CRC
        // errado, e aí o `NSImage` devolve tamanho 0×0 — o que faria o teste
        // passar por um motivo errado.
        let pngPath = root.appendingPathComponent("sample-assets/preview.png")
        guard let png = try? Data(contentsOf: pngPath) else {
            print("FALHA: não li \(pngPath)")
            exit(1)
        }
        let b64 = png.base64EncodedString()
        let uri = "data:image/png;base64,\(b64)"

        var falhas = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { falhas += 1 }
            print("\(ok ? "ok  " : "FALHA") \(name) \(detail)")
        }
        func size(_ image: NSImage?) -> String {
            image.map { NSStringFromSize($0.size) } ?? "nil"
        }

        // 1. URI de uma linha
        check("data URI de uma linha",
              MarkdownImageLoader.load(source: uri, relativeTo: doc) != nil,
              size(MarkdownImageLoader.load(source: uri, relativeTo: doc)))

        // 2. Base64 partido em linhas, que é como um Markdown real fica
        //    legível. Sem isso a imagem não carregaria num documento escrito à
        //    mão.
        let wrapped = stride(from: 0, to: b64.count, by: 76)
            .map { String(b64.dropFirst($0).prefix(76)) }
            .joined(separator: "\n")
        check("base64 partido em linhas",
              MarkdownImageLoader.load(
                  source: "data:image/png;base64,\(wrapped)", relativeTo: doc
              ) != nil,
              size(MarkdownImageLoader.load(
                  source: "data:image/png;base64,\(wrapped)", relativeTo: doc
              )))

        // 3. Redimensionamento pela largura da coluna, preservando a proporção
        let scaled = MarkdownImageLoader.load(source: uri, relativeTo: doc, maximumWidth: 200)
        check("redimensionada para 200", scaled?.size.width == 200, size(scaled))

        // 4. Payload corrompido devolve nil, e não uma imagem quebrada
        check("payload invalido devolve nil",
              MarkdownImageLoader.load(
                  source: "data:image/png;base64,@@@nao-e-base64@@@", relativeTo: doc
              ) == nil)

        // 5. A barreira do caminho relativo continua fechada: um data URI não
        //    deve virar um atalho para ler qualquer arquivo.
        check("escape relativo ainda barrado",
              MarkdownImageLoader.resolve(source: "../../etc/passwd", relativeTo: doc) == nil)

        // 6. O scanner precisa devolver o URI inteiro, sem as quebras de linha
        //    que o base64 tinha — o texto que o parser recebe em cima é um
        //    bloco só.
        let md = """
        ![embutida](data:image/png;base64,\(wrapped))

        Depois.
        """
        let found = MarkdownImageScanner.scan(md)
        check("scanner devolve o URI inteiro",
              found.first?.source == uri,
              found.first.map { "len=\($0.source.count)" } ?? "nada encontrado")

        // 7. O render completo emite o attachment
        let rendered = NativeMarkdownRenderer.render(md, documentURL: doc)
        var anexos = 0
        rendered.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if value is NSTextAttachment { anexos += 1 }
        }
        check("render emite attachment", anexos == 1, "anexos=\(anexos)")
        check("texto ao redor preservado", rendered.string.contains("Depois."))

        print(falhas == 0 ? "\nTUDO PASSOU" : "\n\(falhas) FALHA(S)")
        exit(falhas == 0 ? 0 : 1)
    }
}
