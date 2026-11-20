import Foundation
import zlib

public struct LinkBuffer: Equatable, Sendable {
    public static let flagIn: UInt32 = 1
    public static let flagOut: UInt32 = 2

    public var flags: UInt32
    /// Payload size when a payload is present, otherwise the capacity offered.
    public var length: UInt32
    public var data: Data?

    public init(flags: UInt32, length: UInt32, data: Data? = nil) { self.flags = flags; self.length = length; self.data = data }
    public static func input(_ data: Data) -> LinkBuffer { LinkBuffer(flags: flagIn, length: UInt32(data.count), data: data) }
    public static func output(capacity: Int) -> LinkBuffer { LinkBuffer(flags: flagOut, length: UInt32(capacity)) }
}

public struct Frame: Equatable, Sendable {
    public enum Kind: UInt16, Sendable { case request = 1, reply = 2 }

    public var requestId: UInt64
    public var kind: Kind
    public var opcode: UInt16
    public var status: UInt32
    public var inline: Data
    public var buffers: [LinkBuffer]

    public init(requestId: UInt64, kind: Kind, opcode: UInt16, status: UInt32, inline: Data = Data(), buffers: [LinkBuffer] = []) {
        self.requestId = requestId; self.kind = kind; self.opcode = opcode; self.status = status
        self.inline = inline; self.buffers = buffers
    }

    /// Which flag makes a buffer carry a payload in this kind of frame.
    var payloadFlag: UInt32 { kind == .reply ? LinkBuffer.flagOut : LinkBuffer.flagIn }

    public func encode() -> Data {
        let pad = (8 - inline.count % 8) % 8
        var descriptors = Data(), payloads = Data()
        for buffer in buffers {
            let present = buffer.flags & payloadFlag != 0
            let data = present ? (buffer.data ?? Data()) : Data()
            descriptors.appendLE(present ? UInt32(data.count) : buffer.length)
            descriptors.appendLE(buffer.flags)
            payloads.append(data)
        }
        let total = GuestLinkConstants.headerSize + inline.count + pad + descriptors.count + payloads.count + 4
        var out = Data(capacity: total)
        out.appendLE(GuestLinkConstants.magic)
        out.appendLE(UInt32(total))
        out.appendLE(requestId)
        out.appendLE(kind.rawValue)
        out.appendLE(opcode)
        out.appendLE(status)
        out.appendLE(UInt32(inline.count))
        out.appendLE(UInt16(buffers.count))
        out.appendLE(UInt16(0))
        out.append(inline)
        out.append(Data(count: pad))
        out.append(descriptors)
        out.append(payloads)
        out.appendLE(Frame.crc32(out))
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            UInt32(zlib.crc32(0, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count)))
        }
    }
}

/// Incremental decoder. Feed it bytes as they arrive; it returns complete frames and resynchronises on garbage.
public struct FrameDecoder: Sendable {
    private var pending = Data()
    /// Bytes thrown away while searching for a frame start.
    public private(set) var discardedBytes = 0

    public init() {}

    /// True while part of a frame is buffered.
    public var hasPartialFrame: Bool { !pending.isEmpty }

    /// The stall rule (PROTOCOL.md §2): give up on an incomplete frame and search for the next one.
    public mutating func resyncAfterStall() -> [Frame] {
        guard !pending.isEmpty else { return [] }
        pending.removeFirst(1)
        discardedBytes += 1
        skipToMagic()
        return feed(Data())
    }

    public mutating func feed(_ data: Data) -> [Frame] {
        pending.append(data)
        var frames: [Frame] = []
        while true {
            switch parseOne() {
            case .frame(let frame, let size):
                frames.append(frame)
                pending.removeFirst(size)
            case .needMore:
                // Re-base so indices stay small and memory is released.
                pending = Data(pending)
                return frames
            case .garbage:
                pending.removeFirst(1)
                discardedBytes += 1
                skipToMagic()
            }
        }
    }

    private enum Parse { case frame(Frame, Int), needMore, garbage }

    private mutating func skipToMagic() {
        let magicBytes = Swift.withUnsafeBytes(of: GuestLinkConstants.magic.littleEndian) { Data($0) }
        if let range = pending.range(of: magicBytes) {
            discardedBytes += range.lowerBound - pending.startIndex
            pending.removeFirst(range.lowerBound - pending.startIndex)
        } else {
            // Keep the last 3 bytes: they may be the start of a magic split across reads.
            let keep = min(3, pending.count)
            discardedBytes += pending.count - keep
            pending.removeFirst(pending.count - keep)
        }
    }

    private func parseOne() -> Parse {
        let header = GuestLinkConstants.headerSize
        if pending.count < 4 { return .needMore }
        guard pending.readLE(UInt32.self, at: 0) == GuestLinkConstants.magic else { return .garbage }
        if pending.count < header { return .needMore }
        let total = Int(pending.readLE(UInt32.self, at: 4))
        let kindRaw = pending.readLE(UInt16.self, at: 16)
        let inlineLen = Int(pending.readLE(UInt32.self, at: 24))
        let count = Int(pending.readLE(UInt16.self, at: 28))
        guard let kind = Frame.Kind(rawValue: kindRaw), total >= header + 4, total <= GuestLinkConstants.maxFrameSize,
              count <= GuestLinkConstants.maxBuffers else { return .garbage }
        let descriptorsAt = header + inlineLen + (8 - inlineLen % 8) % 8
        let payloadsAt = descriptorsAt + 8 * count
        guard payloadsAt + 4 <= total else { return .garbage }
        if pending.count < total { return .needMore }
        let base = pending.startIndex
        let bodyEnd = total - 4
        guard Frame.crc32(pending[base..<base + bodyEnd]) == pending.readLE(UInt32.self, at: bodyEnd) else { return .garbage }

        var frame = Frame(requestId: pending.readLE(UInt64.self, at: 8), kind: kind,
                          opcode: pending.readLE(UInt16.self, at: 18), status: pending.readLE(UInt32.self, at: 20))
        frame.inline = Data(pending[base + header..<base + header + inlineLen])
        var offset = payloadsAt
        for i in 0..<count {
            let length = pending.readLE(UInt32.self, at: descriptorsAt + 8 * i)
            let flags = pending.readLE(UInt32.self, at: descriptorsAt + 8 * i + 4)
            var buffer = LinkBuffer(flags: flags, length: length)
            if flags & frame.payloadFlag != 0 {
                guard offset + Int(length) <= bodyEnd else { return .garbage }
                buffer.data = Data(pending[base + offset..<base + offset + Int(length)])
                offset += Int(length)
            }
            frame.buffers.append(buffer)
        }
        guard offset == bodyEnd else { return .garbage }
        return .frame(frame, total)
    }
}
