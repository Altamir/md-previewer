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

    static func render(_ markdown: String) -> NSAttributedString {
        let parsed: AttributedString
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .full
            parsed = try AttributedString(markdown: markdown, options: options)
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
        return layout(parsed)
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

    private struct BlockRun {
        var text: String
        let intent: PresentationIntent?
        let inline: InlinePresentationIntent?
        let link: URL?
    }

    private static func layout(_ parsed: AttributedString) -> NSAttributedString {
        // Coleta os runs com o que precisamos deles.
        var blocks: [BlockRun] = []
        for run in parsed.runs {
            blocks.append(BlockRun(
                text: String(parsed[run.range].characters),
                intent: run.presentationIntent,
                inline: run.inlinePresentationIntent,
                link: run.link
            ))
        }

        // Agrupa runs consecutivos pelo "dono" do bloco. Células de tabela
        // pertencem à tabela inteira (identidade do componente `table`), o
        // resto ao componente mais interno.
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
            result.append(render(group: group))
        }

        if result.length == 0 {
            return NSAttributedString(string: "\n", attributes: [:])
        }

        // Cor base para tudo que não recebeu cor específica.
        result.addAttribute(.foregroundColor, value: NSColor.labelColor,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func ownerKey(of block: BlockRun) -> String {
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

    private static func render(group: Group) -> NSAttributedString {
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
            var attributes: [NSAttributedString.Key: Any] = [
                .font: inlineFont(for: run.inline, base: base),
                .paragraphStyle: style ?? paragraph(),
            ]

            if let inline = run.inline {
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
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            output.append(NSAttributedString(string: run.text, attributes: attributes))
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
        if marker == "☐" || marker == "☑", var first = runs.first {
            first.text = String(first.text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            runs[0] = first
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
            let chain = run.intent?.components ?? []
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
            cells.append(Cell(text: run.text.trimmingCharacters(in: .whitespacesAndNewlines),
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
