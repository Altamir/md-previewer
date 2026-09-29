import AppKit
import Foundation

/// Confere a barreira de confinamento das imagens e o redimensionamento.
///
/// A barreira é a parte que não pode regredir: ela garante que um `.md` vindo
/// de qualquer repositório não consiga fazer o preview abrir um arquivo do
/// diretório do usuário só por causa de um `![](../.ssh/id_rsa)`. Rodar fora do
/// Quick Look é suficiente — `resolve` é o mesmo código que roda lá dentro, e
/// dentro do sandbox a leitura falha antes por um motivo diferente, do
/// poder, não da barreira.
///
///     make imagecheck
@main
struct ImageAccessProbe {
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath + "/Samples")
        let doc = root.appendingPathComponent("sample.md")
        let assets = root.appendingPathComponent("sample-assets")

        // Alvo fora do diretório do Markdown, para provar que a barreira barra
        // um link simbólico apontando para fora.
        let outside = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("README.md")
        let link = assets.appendingPathComponent("escape.png")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: link) }

        // (caminho escrito no Markdown, deve ficar dentro do diretório?)
        let cases: [(String, Bool)] = [
            ("sample-assets/preview.png", true),
            // O arquivo não existe, mas o caminho é válido e interno: a
            // barreira é sobre *onde*, não sobre a existência. O sumiço da
            // imagem é tratado à parte, pelo texto alternativo.
            ("sample-assets/ausente.png", true),
            ("./sample-assets/preview.png", true),
            // O `..` que cancela a si mesmo continua dentro: o `standardized`
            // normaliza antes de comparar, então isto é aceito.
            ("sample-assets/../sample-assets/preview.png", true),
            ("../README.md", false),
            ("../../etc/passwd", false),
            ("sample-assets/escape.png", false),   // symlink para fora
            ("/etc/passwd", false),
            (outside.path, false),
            ("https://example.com/a.png", false),
            ("data:image/png;base64,AAAA", false),
            ("", false),
            ("   ", false),
        ]

        var falhas = 0
        for (source, esperado) in cases {
            let url = MarkdownImageLoader.resolve(source: source, relativeTo: doc)
            // Carregar pode falhar por falta de poder mesmo quando o caminho é
            // válido, então o veredito é sobre `resolve`, e `load` só
            // confirma quando `resolve` passou.
            let permitido = url != nil
            let ok = permitido == esperado
            if !ok { falhas += 1 }
            print("\(ok ? "ok  " : "FALHA") \(source.debugDescription) -> "
                  + "\(url?.lastPathComponent ?? "nil") permitido=\(permitido) esperado=\(esperado)")
        }

        // O redimensionamento precisa preservar a proporção, senão a imagem
        // aparece esticada.
        guard let natural = MarkdownImageLoader.load(
            source: "sample-assets/preview.png", relativeTo: doc
        ) else {
            print("FALHA: não leu a imagem de amostra; o resto do teste não diz nada")
            exit(1)
        }
        guard let scaled = MarkdownImageLoader.load(
            source: "sample-assets/preview.png", relativeTo: doc, maximumWidth: 200
        ) else {
            print("FALHA: não leu a imagem escalada")
            exit(1)
        }
        let proporcao = scaled.size.height / scaled.size.width
        let naturalProporcao = natural.size.height / natural.size.width
        let proporcaoPreservada = abs(proporcao - naturalProporcao) < 0.01
        if scaled.size.width > 200 { falhas += 1 }
        if !proporcaoPreservada { falhas += 1 }
        print("\(scaled.size.width <= 200 && proporcaoPreservada ? "ok  " : "FALHA") "
              + "redimensionamento: \(NSStringFromSize(natural.size)) -> "
              + "\(NSStringFromSize(scaled.size)) em coluna de 200")

        print(falhas == 0 ? "\nTODOS OS CASOS PASSARAM" : "\n\(falhas) FALHA(S)")
        exit(falhas == 0 ? 0 : 1)
    }
}
