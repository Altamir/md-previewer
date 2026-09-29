import Cocoa

/// Container app do previewer.
///
/// Não tem janela nenhuma: o macOS só registra uma extensão Quick Look quando ela
/// é embarcada em um `.app`. `LSUIElement` no Info.plist impede que ele apareça no
/// Dock, e terminate-after-launch evita que ele fique rodando.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
