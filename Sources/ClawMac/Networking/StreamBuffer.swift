import Foundation

final class StreamBuffer {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshotLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        var current = Data()
        for byte in data {
            if byte == 0x0A {
                if let line = String(data: current, encoding: .utf8), !line.isEmpty {
                    lines.append(line)
                }
                current.removeAll()
            } else {
                current.append(byte)
            }
        }
        return lines
    }

    func takeAllString() -> String {
        lock.lock(); defer { lock.unlock() }
        let str = String(data: data, encoding: .utf8) ?? ""
        data.removeAll()
        return str
    }
}
