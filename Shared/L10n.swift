import Foundation

private final class LocalizationAnchor: NSObject {}

enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: LocalizationAnchor.self), comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: arguments)
    }

    static func duration(_ seconds: Int) -> String {
        if seconds == 0 { return f("duration.minutes", 0) }
        if seconds < 60 { return f("duration.seconds", seconds) }
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        if hours == 0 { return f("duration.minutes", minutes) }
        if minutes == 0 { return f("duration.hours", hours) }
        return f("duration.hoursMinutes", hours, minutes)
    }

    static func clock(_ seconds: Int, forceHours: Bool = false) -> String {
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        return hours > 0 || forceHours
            ? String(format: "%lld:%02lld:%02lld", hours, minutes, seconds % 60)
            : String(format: "%02lld:%02lld", minutes, seconds % 60)
    }
}
