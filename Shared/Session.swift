import Darwin
import Foundation

struct ClockReading: Equatable {
    let wall: Date
    let continuous: TimeInterval
    let boot: String
}

enum ReadingClock {
    static let utc = TimeZone(secondsFromGMT: 0)!
    static var zone: TimeZone { Launch.demo ? utc : .current }
    static var now: Date { Launch.demo ? Launch.demoDate : Date() }

    private static let processToken = "process-" + UUID().uuidString
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 0 }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private static func bootToken() -> String {
        var size = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, (2...128).contains(size) {
            var bytes = [CChar](repeating: 0, count: size)
            let status = bytes.withUnsafeMutableBufferPointer {
                sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0)
            }
            if status == 0, bytes.last == 0 {
                let token = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if UUID(uuidString: token) != nil { return token }
            }
        }
        var began = timeval()
        size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &began, &size, nil, 0) == 0, began.tv_sec > 0 {
            return "kernel-\(began.tv_sec)-\(began.tv_usec)"
        }
        return processToken
    }

    private static let boot = bootToken()

    static func sample() -> ClockReading {
        if Launch.demo && Launch.has("-store-shots") {
            return ClockReading(wall: now, continuous: 2_000, boot: "store-screenshot")
        }
        return ClockReading(wall: now, continuous: Double(mach_continuous_time()) * timebase, boot: boot)
    }
}

struct SessionDraft: Codable, Equatable, Identifiable {
    enum State: String, Codable { case running, paused, pending }

    struct Anchor: Codable, Equatable {
        let wall: Date
        let continuous: TimeInterval
        let boot: String
        init(_ time: ClockReading) {
            wall = time.wall
            continuous = time.continuous
            boot = time.boot
        }

        func elapsed(at time: ClockReading) -> TimeInterval? {
            guard time.boot == boot, time.continuous.isFinite, continuous.isFinite,
                  time.continuous >= continuous else { return nil }
            return time.continuous - continuous
        }
    }

    struct Ending: Codable, Equatable {
        let date: Date
        let zoneID: String
        var localDay: ReadingDay?
        var pageText: String
        var durationText: String
        var totalText: String
    }

    var id = UUID()
    let bookID: UUID
    let startPage: Int?
    let startedAt: Date
    private(set) var state: State = .running
    private(set) var accumulated: TimeInterval = 0
    private(set) var anchor: Anchor?
    private(set) var needsDurationReview = false
    var ending: Ending?

    init(book: Book, page: Int?, sample: ClockReading, accumulated: TimeInterval = 0) {
        bookID = book.id
        startPage = page
        startedAt = sample.wall.addingTimeInterval(-accumulated)
        anchor = Anchor(sample)
        self.accumulated = accumulated
    }

    func elapsed(at sample: ClockReading) -> TimeInterval {
        accumulated + (anchor?.elapsed(at: sample) ?? 0)
    }

    func seconds(at sample: ClockReading) -> Int {
        Int(min(3_600_000_000, max(0, elapsed(at: sample))).rounded(.down))
    }

    mutating func checkpoint(at sample: ClockReading) {
        guard state == .running, let anchor else { return }
        guard let elapsed = anchor.elapsed(at: sample) else {
            self.anchor = nil
            state = .paused
            needsDurationReview = true
            return
        }
        accumulated += elapsed
        self.anchor = Anchor(sample)
    }

    mutating func pause(at sample: ClockReading) {
        guard state == .running else { return }
        checkpoint(at: sample)
        anchor = nil
        state = .paused
    }

    mutating func resume(at sample: ClockReading) {
        guard state == .paused else { return }
        anchor = Anchor(sample)
        state = .running
    }

    mutating func stop(at sample: ClockReading, zone: TimeZone, total: Int?) {
        guard state != .pending else { return }
        pause(at: sample)
        state = .pending
        ending = Ending(date: sample.wall, zoneID: zone.identifier, localDay: ReadingDay(sample.wall, in: zone),
                        pageText: startPage.map { String($0) } ?? "",
                        durationText: L.clock(seconds(at: sample), forceHours: true),
                        totalText: total.map { String($0) } ?? "")
    }
}
