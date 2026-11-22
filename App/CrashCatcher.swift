// SPDX-License-Identifier: AGPL-3.0-only
//
// Last-resort diagnostics for a release sideload build: an uncaught Objective-C/Swift exception
// that kills the process leaves nothing behind on a phone the developer cannot attach to. The
// handler writes the exception name, reason and a short stack into UserDefaults, and the next launch
// surfaces it on the CFMOTO EasyConn card and in the log.
//
// It does not install any signal handler on purpose: SIGSEGV/SIGABRT stack traces are not safely
// readable from inside a handler, and a half-written note would be worse than none.

import Foundation

enum CrashCatcher {
    private static let key = "lastUncaughtException"
    private static let installed = { () -> Bool in
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(24).joined(separator: "\n")
            let text = """
            \(exception.name.rawValue): \(exception.reason ?? "-")
            \(stack)
            """
            UserDefaults.standard.set(text, forKey: CrashCatcher.key)
        }
        return true
    }()

    /// Installs the handler once. Call as early as possible.
    static func install() { _ = installed }

    /// The exception recorded by the previous run, if that run died of one.
    static func previousException() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
