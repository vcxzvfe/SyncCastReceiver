import Foundation

/// Accumulates TCP bytes and hands back complete newline-delimited lines.
///
/// A peer that never sends a newline must not be able to grow this buffer
/// without bound, so the framer refuses (and reports) an over-long line
/// instead of buffering it: control messages are a few hundred bytes.
public struct LineFramer {
    public static let maxLineBytes = 16 * 1024

    public enum FramingError: Error, Equatable { case lineTooLong(Int) }

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            let trimmed = Data(line).dropLast(while: { $0 == 0x0D })
            if !trimmed.isEmpty { lines.append(Data(trimmed)) }
        }
        if buffer.count > Self.maxLineBytes {
            let n = buffer.count
            buffer.removeAll(keepingCapacity: false)
            throw FramingError.lineTooLong(n)
        }
        return lines
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}

private extension Data {
    func dropLast(while predicate: (UInt8) -> Bool) -> Data {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) {
            end = index(before: end)
        }
        return self[startIndex..<end]
    }
}
