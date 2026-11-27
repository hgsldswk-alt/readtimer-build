import Foundation

final class LibraryStore: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.hgsldswk.readtimer.library", qos: .userInitiated)

    enum Failure: Error { case unsupportedVersion }
    private struct Header: Decodable { let version: Int }

    init(url: URL) { self.url = url }

    static func open() -> LibraryStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = Launch.testing ? "ReadTimer-UI" : "ReadTimer"
        return LibraryStore(url: root.appendingPathComponent(folder).appendingPathComponent("library.json"))
    }

    func load(reset: Bool = false) async throws -> ReadingLibrary? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if reset, FileManager.default.fileExists(atPath: self.url.path) {
                        try FileManager.default.removeItem(at: self.url)
                    }
                    guard FileManager.default.fileExists(atPath: self.url.path) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let data = try Data(contentsOf: self.url)
                    let decoder = JSONDecoder()
                    guard try decoder.decode(Header.self, from: data).version == 1 else {
                        throw Failure.unsupportedVersion
                    }
                    continuation.resume(returning: try decoder.decode(ReadingLibrary.self, from: data))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func enqueue(_ value: ReadingLibrary, done: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: self.url, options: [.atomic])
                done(.success(()))
            } catch { done(.failure(error)) }
        }
    }

    func save(_ value: ReadingLibrary) async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(value) { continuation.resume(with: $0) }
        }
    }
}
