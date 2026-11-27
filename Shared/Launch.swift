import Foundation

enum Launch {
    static let freePeriod = false
    #if DEBUG
    static let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
    #else
    static let testing = false
    #endif
    static let demoDate = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
    static var demo: Bool { testing && has("-demo") }
    static var isFree: Bool {
        if testing && has("-free-mode") { return true }
        return freePeriod && !(testing && ["-paid-mode", "-paywall", "-expired"].contains(where: has))
    }

    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }
    static let proID = "com.hgsldswk.readtimer.pro"
    static let trialID = "com.hgsldswk.readtimer.trial"
}
