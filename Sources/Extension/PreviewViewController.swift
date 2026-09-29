import AppKit
import QuickLook
import QuickLookUI
import WebKit

/// Preview de arquivos Markdown para o Quick Look do Finder.
///
/// A partir do macOS 26 `QLPreviewViewController` deixou de existir; a API de
/// preview baseado em view é agora o protocolo `QLPreviewingController`, que
/// esta classe implementa sobre um `NSViewController` comum. O nome da classe
/// continua o mesmo porque é ele que o `NSExtensionPrincipalClass` aponta.
final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate, WKScriptMessageHandler {

    /// Canal de volta do JavaScript. O `preview.html` manda o resultado do
    /// render por aqui; sem isso não há como distinguir uma página em branco
    /// de uma renderização que deu errado.
    private static let messageName = "mdPreview"

    private var webView: WKWebView?
    private var fallbackLabel: NSTextField?
    private var renderConfirmed = false

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) não é usado")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        container.wantsLayer = true
        view = container
    }

    deinit {
        holdsDirectoryAccess?.stopAccessingSecurityScopedResource()
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        // Chamado uma vez, na main thread, antes de o preview aparecer. O
        // handler precisa rodar cedo: o sistema mostra um spinner até ele ser
        // chamado.
        //
        // Note que `providePreview(for:)` NÃO é implementado de propósito: a
        // presença dele faz o QuickLook tratar a extensão como geradora de
        // preview baseado em dados e tomar esse caminho, em vez de exibir a
        // view. A rota baseada em view é a que serve aqui.
        Trace.log("preparePreviewOfFile \(url.lastPathComponent)")

        // O poder recebido é só sobre o arquivo em preview. Imagens relativas
        // moram **ao lado** dele, então a tentativa de abrir um `.png` vizinho é
        // negada pelo sandbox — medido, não presumido. A extensão pede acesso ao
        // diretório mesmo assim: se numa instalação o sistema conceder, as
        // imagens passam a carregar sem nenhuma outra mudança.
        let directory = url.deletingLastPathComponent()
        let granted = directory.startAccessingSecurityScopedResource()
        if !granted {
            Trace.log("acesso ao diretorio negado: imagens relativas dependem disso. "
                      + "Ver README, secao 'Imagens relativas'.")
        }

        do {
            let raw = try MarkdownDocument.load(at: url)
            let markdown = MarkdownDocument.stripFrontMatter(raw)
            DispatchQueue.main.async { [weak self] in
                self?.render(markdown: markdown, documentURL: url)
                completionHandler(nil)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.showMessage(error.localizedDescription)
                // Sem preview não há o que mostrar, mas completando com erro o
                // Quick Look cai no gerador padrão em vez de travar.
                completionHandler(error)
            }
        }

        // O acesso ao diretório é mantido enquanto o preview existir: as
        // imagens são carregadas durante o render e redimensionadas depois, no
        // primeiro layout.
        if granted { holdsDirectoryAccess = directory }
    }

    /// Mantém o acesso ao diretório do arquivo em preview enquanto a view
    /// existir. Solto em `deinit`, que é o ponto em que o preview terminou.
    private var holdsDirectoryAccess: URL?

    // MARK: - Render

    /// Motor de renderização.
    ///
    /// `native` usa o parser de Markdown da própria Apple num NSTextView —
    /// sem WebKit, sem JavaScript, instantâneo. `web` usa a WKWebView, que dá
    /// o visual idêntico ao GitHub mas depende de JS rodando dentro da
    /// extensão, o que não é garantido (ver README).
    /// `native` é o padrão porque a WKWebView não executa JavaScript dentro
    /// da extensão Quick Look nesta instalação (ver README, seção "WebKit").
    /// Troque para `.web` em outra máquina para recuperar o visual do GitHub.
    private enum Engine: String {
        case native
        case web

        static let current: Engine = .native
    }

    private func render(markdown: String, documentURL: URL) {
        guard Engine.current == .web else {
            return renderNative(markdown: markdown, documentURL: documentURL)
        }

        guard let html = Self.makeHTML(markdown: markdown) else {
            Trace.log("ERRO: nao montou o HTML. resources=\(Self.resourceDirectory()?.path ?? "nil")")
            showMessage("Não foi possível carregar os recursos do preview.")
            return
        }

        clearFallback()
        renderConfirmed = false

        let webView = WKWebView(frame: .zero, configuration: configuration(for: documentURL))
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.webView = webView

        // baseURL nil: o HTML é autocontido e não depende de nada em disco.
        webView.loadHTMLString(html, baseURL: nil)
        expectRenderConfirmation(source: markdown)
    }

    private func renderNative(markdown: String, documentURL: URL) {
        clearFallback()
        webView?.removeFromSuperview()
        webView = nil
        markdownForRefit = RefitSource(markdown: markdown, url: documentURL)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.textStorage?.setAttributedString(
            NativeMarkdownRenderer.render(markdown, documentURL: documentURL)
        )

        scrollView.documentView = textView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        // A largura da coluna só é conhecida depois do layout, e é ela que
        // decide se uma imagem maior cabe ou precisa ser reduzida. Rerenderizar
        // aqui evita fixar uma largura arbitrária e cortar a imagem.
        DispatchQueue.main.async { [weak self] in self?.refitImages(in: textView) }

        renderConfirmed = true
        Trace.log("render nativo ok, \(markdown.count) chars")
    }

    /// Reaplica o render com a largura real do container, agora que o layout
    /// já aconteceu.
    private func refitImages(in textView: NSTextView) {
        let available = textView.textContainer?.size.width ?? 0
        guard available > 0, markdownForRefit != nil else { return }

        let previous = markdownForRefit
        let width = available - textView.textContainerInset.width * 2
        textView.textStorage?.setAttributedString(
            NativeMarkdownRenderer.render(
                previous!.markdown,
                documentURL: previous!.url,
                maximumImageWidth: width
            )
        )
        Trace.log("imagens ajustadas para \(Int(width)) pontos de coluna")
    }

    /// Guarda o que `refitImages` precisa para repetir o render.
    private struct RefitSource {
        let markdown: String
        let url: URL
    }

    private var markdownForRefit: RefitSource?

    private func configuration(for documentURL: URL) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            AssetSchemeHandler(root: documentURL.deletingLastPathComponent()),
            forURLScheme: AssetSchemeHandler.schemeName
        )
        configuration.userContentController.add(self, name: Self.messageName)
        return configuration
    }

    // MARK: - Confirmação de render

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let payload = message.body as? [String: Any] ?? [:]
        if (payload["status"] as? String) == "ok" {
            renderConfirmed = true
            Trace.log("RENDER OK: html=\(payload["htmlChars"] ?? 0) imagens=\(payload["images"] ?? 0) "
                      + "blocos=\(payload["codeBlocks"] ?? 0)")
        } else {
            let detail = payload["mensagem"] as? String ?? "erro desconhecido"
            Trace.log("RENDER ERRO: \(detail)")
            showMessage("Falha ao renderizar o Markdown: \(detail)")
        }
    }

    /// Se o JavaScript não confirmar em alguns segundos, mostra o texto cru.
    ///
    /// Sem isso a janela ficaria permanentemente em branco quando o WebKit não
    /// consegue executar a página — que é o caso dentro da extensão Quick Look
    /// em algumas instalações. Ter o markdown legível é melhor que uma janela
    /// vazia, e o log deixa o motivo registrado.
    private func expectRenderConfirmation(source: String, attemptsRemaining: Int = 8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            guard !self.renderConfirmed else { return }
            guard attemptsRemaining > 1 else {
                Trace.log("JS nao confirmou; mostrando fallback de texto")
                self.showMessage(source)
                return
            }
            self.expectRenderConfirmation(source: source, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Trace.log("webview carregou")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Trace.log("ERRO navegacao: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Trace.log("ERRO navegacao provisoria: \(error.localizedDescription)")
    }

    // MARK: - HTML assembly

    private static let markdownPlaceholder = "{{MARKDOWN_B64}}"

    /// Assets embutidos no HTML final, em vez de carregados por `<script src>`.
    ///
    /// Uma WKWebView criada com `loadHTMLString(_:baseURL:)` resolve URLs
    /// relativas a partir do baseURL, mas sob o sandbox da extensão o WebKit
    /// não consegue ler esses arquivos em disco. Como tudo aqui é estático, o
    /// caminho robusto é ler os assets no Swift e injetá-los no HTML.
    private static let inlineAssets: [(placeholder: String, file: String)] = [
        ("{{THEME_CSS}}", "theme.css"),
        ("{{MARKED_JS}}", "vendor/marked.min.js"),
        ("{{PURIFY_JS}}", "vendor/purify.min.js"),
        ("{{HIGHLIGHT_JS}}", "vendor/highlight.min.js"),
    ]

    /// Procura os recursos no bundle.
    ///
    /// `Bundle.main.resourceURL` cobre a extensão rodando a partir do app
    /// instalado. Durante o desenvolvimento o macOS às vezes carrega o
    /// executável direto da pasta de build, e aí o `resourceURL` aponta para um
    /// bundle sem os recursos ao lado.
    private static func resourceDirectory() -> URL? {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.appendingPathComponent("Resources"),
        ].compactMap { $0 }

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("preview.html").path)
        }
    }

    private static func read(_ relativePath: String, in base: URL) -> String? {
        try? String(contentsOf: base.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func makeHTML(markdown: String) -> String? {
        guard let base = resourceDirectory(),
              var html = read("preview.html", in: base) else { return nil }

        for asset in inlineAssets {
            guard let contents = read(asset.file, in: base) else {
                Trace.log("ERRO: asset ausente \(asset.file)")
                return nil
            }
            html = html.replacingOccurrences(of: asset.placeholder, with: contents)
        }

        return html.replacingOccurrences(
            of: markdownPlaceholder,
            with: Data(markdown.utf8).base64EncodedString()
        )
    }

    // MARK: - Fallback

    private func showMessage(_ text: String) {
        webView?.removeFromSuperview()
        webView = nil

        let label: NSTextField
        if let existing = fallbackLabel {
            label = existing
        } else {
            let created = NSTextField(labelWithString: "")
            created.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            created.textColor = .secondaryLabelColor
            created.isSelectable = true
            created.lineBreakMode = .byWordWrapping
            created.maximumNumberOfLines = 0
            created.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(created)
            NSLayoutConstraint.activate([
                created.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                created.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                created.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            ])
            fallbackLabel = created
            label = created
        }
        label.stringValue = text
    }

    private func clearFallback() {
        fallbackLabel?.removeFromSuperview()
        fallbackLabel = nil
    }
}
