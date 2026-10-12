import AppKit

@main
@MainActor
enum WaxApp {
    /// `NSApplication` holds its delegate weakly, so something else has to keep it alive.
    private static var delegate: AppDelegate?

    static func main() {
        let options = LaunchOptions(arguments: CommandLine.arguments)
        Log.isVerbose = options.verbose

        let app = NSApplication.shared
        if options.isDevTool {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                exit(await DevTools.run(options))
            }
        } else {
            let delegate = AppDelegate(options: options)
            Self.delegate = delegate
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
        }
        app.run()
    }
}
