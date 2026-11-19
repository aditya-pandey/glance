import AppKit
import Foundation

if CommandLine.arguments.contains("--self-test") {
    let ok = WindowWheelSelfTest.runAll()
    exit(ok ? 0 : 1)
}
if CommandLine.arguments.contains("--diag") {
    WindowWheelSelfTest.runDiagnostics()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
