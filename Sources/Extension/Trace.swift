import Foundation

/// Log da extensão, para depurar a carga pelo Quick Look.
///
/// A extensão roda num processo do sistema (`quicklookd`), onde `print` e
/// `NSLog` somem do console do Xcode — e o sandbox proíbe escrita em `/tmp`.
/// Por isso o arquivo vai para o diretório temporário do próprio container:
///
///     ~/Library/Containers/com.mdpreviewer.app.preview/Data/tmp/mdpreviewer.log
///
/// Marcador de build: se o trace mostrar outro valor, o macOS carregou um
/// bundle antigo em vez do instalado.
enum Trace {
    private static let buildTag = "v1"

    private static var logURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mdpreviewer.log")
    }

    static func log(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) [\(buildTag)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
