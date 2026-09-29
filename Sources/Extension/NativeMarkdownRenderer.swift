import AppKit
import Foundation

/// Renderização nativa de Markdown, sem WebKit.
///
/// O parser da Apple (`AttributedString(markdown:)` com `.full`) devolve o
/// documento como uma sequência de runs anotadas com `PresentationIntent` —
/// mas **sem estilo visual nenhum e sem quebras de linha entre blocos**: o
/// texto chega todo emendado. Este renderer percorre os intents e reconstrói a
/// apresentação: headings com tamanho, listas com marcadores e recuo, citações
/// deslocadas, blocos de código com fundo, tabelas alinhadas por coluna.
enum NativeMarkdownRenderer {

    // MARK: - API

    /// - Parameters:
    ///   - documentURL: o arquivo em preview. Só é usado para resolver imagens
    ///     relativas; sem ele elas não têm onde procurar e saem como texto
    ///     alternativo.
    ///   - maximumImageWidth: largura disponível para a coluna. Uma imagem
    ///     maior que isso é reduzida proporcionalmente, senão o attachment
    ///     estoura a largura e o `NSTextView` corta o lado direito.
    static func render(
        _ markdown: String,
        documentURL: URL? = nil,
        maximumImageWidth: CGFloat? = nil
    ) -> NSAttributedString {
        // As imagens saem do texto **antes** do parser: o parser da Apple
        // descarta o nó de imagem e devolve só o alt como parágrafo, então
        // deixá-las no texto significaria perder o caminho. Cada imagem vira um
        // marcador único que sobra intacto entre um bloco e o outro.
        let stripped = ImagePlaceholderStripper(
            markdown: markdown,
            documentURL: documentURL,
            maximumWidth: maximumImageWidth
        )

        let parsed: AttributedString
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .full
            parsed = try AttributedString(markdown: stripped.text, options: options)
        } catch {
            // O parser estrito lança em markup muito torto; um preview não
            // pode falhar por causa disso.
            Trace.log("parser nativo falhou: \(error.localizedDescription)")
            return NSAttributedString(
                string: markdown,
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph(lineHeight: 1.35),
                ]
            )
        }
        return layout(parsed, images: stripped.images)
    }

    // MARK: - Imagens
    //
    // O parser não devolve imagem alguma, então o bloco é reconstruído aqui a
    // partir do que o scanner encontrou no texto-fonte. A ponte entre os dois
    // mundos é um marcador opaco: o parser o entrega como parágrafo intacto e
    // o layout o troca pelo `NSTextAttachment`.

    private static let markerPrefix = "\u{FFFC}mdimg\u{FFFC}"
    private static let markerDelimiter: Character = "\u{FFFC}"

    /// `\u{FFFC}mdimg\u{FFFC}<índice>\u{FFFC}`.
    ///
    /// O prefixo é longo de propósito: um U+FFFC solto é o caractere que o
    /// TextKit usa para o attachment, e o texto do documento pode conter
    /// qualquer coisa. O que faz o marcador ser reconhecido é a sequência
    /// inteira, não o caractere.
    private static func marker(for index: Int) -> String {
        "\(markerPrefix)\(index)\(markerDelimiter)"
    }

    /// Substitui cada `![alt](src)` por um marcador e guarda o que ele
    /// representa.
    private struct ImagePlaceholderStripper {
        let text: String
        let images: [Int: PreparedImage]

        struct PreparedImage {
            let image: NSImage?
            let alt: String
            let title: String?
            let isEmphasized: Bool
        }

        init(markdown: String, documentURL: URL?, maximumWidth: CGFloat?) {
            let found = MarkdownImageScanner.scan(markdown)
            guard !found.isEmpty else {
                self.text = markdown
                self.images = [:]
                return
            }

            var output = ""
            var cursor = markdown.startIndex
            var prepared: [Int: PreparedImage] = [:]

            for (index, reference) in found.enumerated() {
                // O scanner devolve o range exato do trecho `![...](...)`, então
                // isto é uma fatiagem direta — sem busca, que acertaria a
                // ocorrência errada num documento com imagens repetidas.
                guard reference.range.lowerBound >= cursor else { continue }

                let loaded = documentURL.flatMap {
                    MarkdownImageLoader.load(
                        source: reference.source,
                        relativeTo: $0,
                        maximumWidth: maximumWidth
                    )
                }
                if loaded == nil {
                    Trace.log("preview: imagem nao carregada (\(reference.source)) alt=\(reference.alt)")
                }

                prepared[index] = PreparedImage(
                    image: loaded,
                    alt: reference.alt,
                    title: reference.title,
                    isEmphasized: reference.isEmphasized
                )

                output += markdown[cursor..<reference.range.lowerBound]
                output += marker(for: index)
                cursor = reference.range.upperBound
            }
            output += markdown[cursor...]

            self.text = output
            self.images = prepared
        }
    }

    /// Attachment que desenha a imagem.
    ///
    /// A imagem vai pela `attachmentCell` em vez da property `image`: atribuir
    /// `image` faz o attachment tratar o conteúdo como documento, o que
    /// exige `init(data:ofType:)` numa subclasse — e a subclasse sem esse
    /// initializer crasha no primeiro uso. A cell resolve a imagem direto na
    /// memória, que é o que um preview quer.
    private static func attachment(for image: NSImage, isEmphasized: Bool) -> NSTextAttachment {
        let cell = NSTextAttachmentCell(imageCell: image)
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell

        var size = image.size
        if isEmphasized {
            size.width *= 0.85
            size.height *= 0.85
        }
        // Uma altura de linha enorme desalinha o espaçamento dos parágrafos
        // vizinhos; o limite mantém a imagem grande o bastante para ser útil
        // sem estourar a coluna.
        if size.height > 1200 { size.height = 1200 }
        attachment.bounds = NSRect(origin: .zero, size: size)
        return attachment
    }

    // MARK: - Tipografia

    private static let bodyFont = NSFont.systemFont(ofSize: 13.5)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 24, weight: .bold)
        case 2: return .systemFont(ofSize: 19, weight: .bold)
        case 3: return .systemFont(ofSize: 16, weight: .semibold)
        case 4: return .systemFont(ofSize: 14, weight: .semibold)
        default: return .systemFont(ofSize: 13, weight: .semibold)
        }
    }

    private static func paragraph(
        spacingAfter: CGFloat = 9,
        spacingBefore: CGFloat = 0,
        firstLine: CGFloat = 0,
        head: CGFloat = 0,
        lineHeight: CGFloat = 1.35,
        alignment: NSTextAlignment? = nil
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.paragraphSpacingBefore = spacingBefore
        style.firstLineHeadIndent = firstLine
        style.headIndent = head
        style.lineHeightMultiple = lineHeight
        if let alignment { style.alignment = alignment }
        return style
    }

    // MARK: - Layout

    /// Um bloco lógico do documento: um parágrafo, um heading, um item de
    /// lista, uma linha de código, uma tabela inteira…
    private struct Group {
        let runs: [BlockRun]
    }

    /// Um pedaço do documento ainda com os dados do parser. A imagem é uma
    /// variante à parte porque não vem do parser: entra por fora, do scanner.
    private enum BlockRun {
        case text(String, intent: PresentationIntent?, inline: InlinePresentationIntent?, link: URL?)
        case image(Int)

        var intent: PresentationIntent? {
            if case .text(_, let intent, _, _) = self { return intent }
            return nil
        }

        var text: String {
            if case .text(let text, _, _, _) = self { return text }
            return ""
        }
    }

    private static func layout(
        _ parsed: AttributedString,
        images: [Int: ImagePlaceholderStripper.PreparedImage]
    ) -> NSAttributedString {
        // Coleta os runs com o que precisamos deles.
        var blocks: [BlockRun] = []
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)

            // O parser devolve o marcador como texto comum, normalmente em run
            // próprio. Quando vem colado a outro texto — o `*` do itálico nunca
            // é descartado — o que antecede o marcador vira parágrafo solto.
            if let index = markerIndex(in: text), images[index] != nil,
               let range = text.range(of: markerPrefix) {
                let leading = String(text[..<range.lowerBound])
                if !leading.isEmpty {
                    blocks.append(.text(leading, intent: nil, inline: nil, link: nil))
                }
                blocks.append(.image(index))
                continue
            }

            blocks.append(.text(
                text,
                intent: run.presentationIntent,
                inline: run.inlinePresentationIntent,
                link: run.link
            ))
        }

        // Agrupa runs consecutivos pelo "dono" do bloco. Células de tabela
        // pertencem à tabela inteira (identidade do componente `table`), o
        // resto ao componente mais interno. Cada imagem é o seu próprio grupo.
        var groups: [Group] = []
        var current: [BlockRun] = []
        var currentKey: String?

        for block in blocks {
            let key = ownerKey(of: block)
            if key != currentKey {
                if !current.isEmpty { groups.append(Group(runs: current)) }
                current = []
                currentKey = key
            }
            current.append(block)
        }
        if !current.isEmpty { groups.append(Group(runs: current)) }

        // Renderiza cada grupo e costura com quebra de parágrafo simples — o
        // espaçamento vem do paragraphStyle de cada bloco, não de linhas vazias.
        let result = NSMutableAttributedString()
        for (index, group) in groups.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(render(group: group, images: images))
        }

        if result.length == 0 {
            return NSAttributedString(string: "\n", attributes: [:])
        }

        // Cor base para tudo que não recebeu cor específica. A cor não pode
        // tocar num attachment, senão o TextKit pinta por cima do bitmap.
        let colorable = result.mutableCopy() as! NSMutableAttributedString
        var position = 0
        while position < result.length {
            let attributed = result as NSAttributedString
            let isAttachment = attributed.attribute(
                .attachment, at: position, effectiveRange: nil
            ) != nil
            if isAttachment {
                position += 1
                continue
            }
            var end = position
            while end < result.length,
                  attributed.attribute(.attachment, at: end, effectiveRange: nil) == nil {
                end += 1
            }
            colorable.addAttribute(
                .foregroundColor, value: NSColor.labelColor,
                range: NSRange(location: position, length: end - position)
            )
            position = end
        }
        return colorable
    }

    /// Lê o índice de um marcador. Os dígitos são consumidos um a um: um
    /// documento com mais de 10 imagens é comum, e assumir largura fixa
    /// faria o marcador da 10ª não ser reconhecido.
    private static func markerIndex(in text: String) -> Int? {
        guard let open = text.range(of: markerPrefix) else { return nil }

        var cursor = open.upperBound
        var digits = ""
        while cursor < text.endIndex, text[cursor].isNumber {
            digits.append(text[cursor])
            cursor = text.index(after: cursor)
        }

        guard !digits.isEmpty,
              cursor < text.endIndex,
              text[cursor] == markerDelimiter,
              let index = Int(digits) else { return nil }
        return index
    }

    private static func ownerKey(of block: BlockRun) -> String {
        if case .image(let index) = block { return "image:\(index)" }
        let chain = block.intent?.components ?? []
        if let table = chain.first(where: isTable) {
            return "table:\(table.identity)"
        }
        return "block:\(chain.first?.identity ?? 0)"
    }

    private static func isTable(_ component: PresentationIntent.IntentType) -> Bool {
        if case .table = component.kind { return true }
        return false
    }

    // MARK: - Render por grupo

    private static func render(
        group: Group,
        images: [Int: ImagePlaceholderStripper.PreparedImage]
    ) -> NSAttributedString {
        if case .image(let index) = group.runs.first {
            return image(index, from: images[index])
        }

        let chain = group.runs.first?.intent?.components ?? []
        guard let innermost = chain.first else {
            // Sem intent nenhum (raro): texto puro.
            return styled(group, font: bodyFont)
        }

        switch innermost.kind {
        case .header(let level):
            return styled(group, font: headingFont(level: level),
                          paragraph: paragraph(spacingAfter: 5, spacingBefore: 14, lineHeight: 1.2))

        case .codeBlock:
            return codeBlock(group)

        case .thematicBreak:
            let rule = NSAttributedString(
                string: String(repeating: "─", count: 48),
                attributes: [
                    .font: codeFont,
                    .foregroundColor: NSColor.separatorColor,
                    .paragraphStyle: paragraph(spacingAfter: 12, spacingBefore: 8, alignment: .center),
                ]
            )
            return rule

        case .tableCell, .tableRow, .tableHeaderRow:
            return table(group)

        default:
            // Parágrafo — que pode estar aninhado em lista ou citação.
            if chain.count >= 2 {
                let parent = chain[1].kind
                if case .listItem(let ordinal) = parent {
                    return listItem(group, chain: chain, ordinal: ordinal)
                }
                if case .blockQuote = parent {
                    return styled(group, font: bodyFont,
                                  color: .secondaryLabelColor,
                                  paragraph: paragraph(spacingAfter: 9, head: 22))
                }
            }
            return styled(group, font: bodyFont,
                          paragraph: paragraph(spacingAfter: 9))
        }
    }

    // MARK: Blocos comuns

    /// Desenha a imagem, ou o texto que a substitui quando ela não pôde ser
    /// carregada.
    ///
    /// O fallback não é decoração: o `sample.md` traz um caso de imagem
    /// inexistente de propósito, e um preview que mostrasse um retângulo vazio
    /// seria indistinguível de um bug.
    private static func image(
        _ index: Int,
        from prepared: ImagePlaceholderStripper.PreparedImage?
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let spacing = paragraph(spacingAfter: 12, spacingBefore: 6, lineHeight: 1.0)

        guard let prepared, let picture = prepared.image else {
            let label = prepared?.alt.isEmpty == false ? prepared!.alt : "imagem indisponível"
            return NSAttributedString(
                string: "🖼  \(label)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: spacing,
                ]
            )
        }

        let attachment = attachment(for: picture, isEmphasized: prepared.isEmphasized)
        // O U+FFFC é o caractere que ocupa a posição do attachment: o
        // comprimento da string continua 1, o que o TextKit espera.
        let cell = NSMutableAttributedString(string: "\u{FFFC}", attributes: [
            .attachment: attachment,
            .paragraphStyle: spacing,
        ])
        output.append(cell)

        if let title = prepared.title, !title.isEmpty {
            let caption = NSAttributedString(
                string: "\n\(title)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: paragraph(spacingAfter: 12, lineHeight: 1.0),
                ]
            )
            output.append(caption)
        }
        return output
    }

    /// Aplica estilo inline (negrito, itálico, código, risco, link) a cada run
    /// do grupo sob uma fonte-base e um paragraph style comuns.
    private static func styled(
        _ group: Group,
        font base: NSFont,
        color: NSColor? = nil,
        paragraph style: NSParagraphStyle? = nil
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in group.runs {
            guard case .text(let text, _, let inline, let url) = run else { continue }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: inlineFont(for: inline, base: base),
                .paragraphStyle: style ?? paragraph(),
            ]

            if let inline {
                if has(inline, Inline.code) {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular)
                    attributes[.foregroundColor] = NSColor.systemTeal
                }
                if has(inline, Inline.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                }
            }
            if let color { attributes[.foregroundColor] = color }
            if let url {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        return output
    }

    // MARK: - Presentation intents inline
    //
    // `InlinePresentationIntent` é um `OptionSet` sem membros nomeados. Os
    // valores foram medidos no parser (ver README): 1 itálico, 2 negrito,
    // 4 código, 32 tachado. Link não vem por aqui — vem em `run.link`.

    private enum Inline {
        static let italic: InlinePresentationIntent = [.init(rawValue: 1)]
        static let bold: InlinePresentationIntent = [.init(rawValue: 2)]
        static let code: InlinePresentationIntent = [.init(rawValue: 4)]
        static let strikethrough: InlinePresentationIntent = [.init(rawValue: 32)]
    }

    private static func has(_ inline: InlinePresentationIntent?, _ flag: InlinePresentationIntent) -> Bool {
        guard let inline else { return false }
        return !inline.isDisjoint(with: flag)
    }

    private static func inlineFont(for inline: InlinePresentationIntent?, base: NSFont) -> NSFont {
        guard let inline else { return base }
        var font = base
        if has(inline, Inline.bold) {
            font = NSFont.systemFont(ofSize: base.pointSize, weight: base.pointSize >= 17 ? .bold : .semibold)
        }
        if has(inline, Inline.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    // MARK: Lista

    private static func listItem(_ group: Group, chain: [PresentationIntent.IntentType], ordinal: Int) -> NSAttributedString {
        guard chain.count >= 3, case .orderedList = chain[2].kind else {
            return bulletItem(group, marker: marker(for: group))
        }
        return bulletItem(group, marker: "\(ordinal).")
    }

    /// GFM task list: o parser não entende `- [ ]`, o colchete chega literal
    /// no texto do run.
    private static func marker(for group: Group) -> String {
        let text = group.runs.map(\.text).joined()
        if text.hasPrefix("[ ]") { return "☐" }
        if text.lowercased().hasPrefix("[x]") { return "☑" }
        return "•"
    }

    private static func bulletItem(_ group: Group, marker: String) -> NSAttributedString {
        // Remove o "[ ]" / "[x]" que vira checkbox, se for o caso.
        var runs = group.runs
        if marker == "☐" || marker == "☑",
           case .some(.text(let first, let intent, let inline, let link)) = runs.first {
            runs[0] = .text(
                String(first.dropFirst(3)).trimmingCharacters(in: .whitespaces),
                intent: intent, inline: inline, link: link
            )
        }

        let indent: CGFloat = 16
        let style = paragraph(
            spacingAfter: 3,
            firstLine: indent,
            head: indent + 14
        )

        let output = NSMutableAttributedString()
        output.append(NSAttributedString(string: marker + "\t", attributes: [
            .font: bodyFont,
            .paragraphStyle: style,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        output.append(styled(Group(runs: runs), font: bodyFont, paragraph: style))
        return output
    }

    // MARK: Código

    private static func codeBlock(_ group: Group) -> NSAttributedString {
        var text = group.runs.map(\.text).joined()
        while text.hasSuffix("\n") { text.removeLast() }

        return NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                .font: codeFont,
                .backgroundColor: NSColor.separatorColor.withAlphaComponent(0.15),
                .paragraphStyle: paragraph(
                    spacingAfter: 12,
                    spacingBefore: 4,
                    firstLine: 10,
                    head: 10,
                    lineHeight: 1.25
                ),
            ]
        )
    }

    // MARK: Tabela

    private static func table(_ group: Group) -> NSAttributedString {
        struct Cell {
            let text: String
            let column: Int
            let isHeader: Bool
        }

        // Separa os runs de volta em células pela identidade mais interna.
        var cells: [Cell] = []
        var headerRow = true
        var alignments: [PresentationIntent.TableColumn.Alignment] = []

        for run in group.runs {
            guard case .text(let text, let intent, _, _) = run else { continue }
            let chain = intent?.components ?? []
            guard let inner = chain.first else { continue }

            if alignments.isEmpty,
               case .table(let columns) = chain.last?.kind {
                alignments = columns.map(\.alignment)
            }

            var column = 0
            var header = false
            if case .tableCell(let columnIndex) = inner.kind {
                column = columnIndex
            }
            for component in chain {
                if case .tableHeaderRow = component.kind { header = true; headerRow = true }
                if case .tableRow = component.kind { header = false }
            }
            cells.append(Cell(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                              column: column,
                              isHeader: header))
        }

        guard !cells.isEmpty else { return NSAttributedString(string: "") }
        _ = headerRow

        // Reconstrói as linhas: uma linha nova começa quando o índice de
        // coluna não avança em relação à célula anterior.
        var rows: [[Cell]] = []
        var current: [Cell] = []
        var previousColumn = -1
        for cell in cells {
            if cell.column <= previousColumn, !current.isEmpty {
                rows.append(current)
                current = []
            }
            current.append(cell)
            previousColumn = cell.column
        }
        if !current.isEmpty { rows.append(current) }

        // Largura de cada coluna em pontos, medida com a fonte real em vez de
        // contada em caracteres — é isso que faz as tabulações baterem.
        let columnCount = max(
            cells.map(\.column).max().map { $0 + 1 } ?? 1,
            alignments.count
        )
        let measuringFont = NSFont.systemFont(ofSize: 12.5)
        let widths: [CGFloat] = (0..<columnCount).map { column in
            cells
                .filter { $0.column == column }
                .map { $0.text.size(withAttributes: [.font: measuringFont]).width }
                .max() ?? 40
        }

        let output = NSMutableAttributedString()
        let tableStyle = paragraph(spacingAfter: 12, spacingBefore: 4, lineHeight: 1.45)

        // Tabelas usam tabs com `tabStops` em posição de texto, não espaços:
        // o TextKit alinha pela largura real do glifo, então `ã` e `ç` — que
        // ocupam menos espaço que `W` — não quebram a coluna. Padding manual
        // contaria caracteres e desalinharia justamente nesses casos.
        let regular = NSFont.systemFont(ofSize: 12.5)
        let semibold = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

        var offsets: [NSTextTab] = []
        var offset: CGFloat = 0
        for column in 0..<columnCount {
            offset += widths[column] + 14
            offsets.append(NSTextTab(textAlignment: .left, location: offset, options: [:]))
        }
        let tabbed = NSMutableParagraphStyle()
        tabbed.paragraphSpacing = tableStyle.paragraphSpacing
        tabbed.paragraphSpacingBefore = tableStyle.paragraphSpacingBefore
        tabbed.lineHeightMultiple = tableStyle.lineHeightMultiple
        tabbed.tabStops = offsets

        func appendLine(_ line: String, weight: NSFont.Weight, color: NSColor) {
            let font = weight == .semibold ? semibold : regular
            output.append(NSAttributedString(string: line, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: tabbed,
            ]))
        }

        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 { output.append(NSAttributedString(string: "\n")) }

            let isHeader = row.allSatisfy(\.isHeader) || rowIndex == 0
            let line = (0..<columnCount).map { column in
                row.first { $0.column == column }?.text ?? ""
            }.joined(separator: "\t")
            appendLine(line,
                       weight: isHeader ? .semibold : .regular,
                       color: NSColor.labelColor)

            if isHeader {
                output.append(NSAttributedString(string: "\n"))
                let rule = (0..<columnCount).map { column in
                    // O `─` é monoespaçado de largura menor que o texto, então
                    // a régua é desenhada só como separador visual, com o
                    // mesmo alinhamento por tab.
                    String(repeating: "─", count: max(Int(widths[column] / 7), 3))
                }.joined(separator: "\t")
                appendLine(rule, weight: .regular, color: NSColor.separatorColor)
            }
        }

        return output
    }

}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
