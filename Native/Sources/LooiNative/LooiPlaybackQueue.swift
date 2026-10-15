import Foundation

// Platform-independent buffering. Only a short window is scheduled on the audio node;
// the remaining PCM stays here so a stopped output can replay its unconfirmed window.
struct LooiPlaybackQueue {
    struct Chunk {
        let id: UUID
        let request: UUID
        let samples: [Float]
    }
    static let sampleRate = 24_000
    static let capacity = sampleRate * 60
    static let chunkFrames = 4_800
    static let windowFrames = 14_400
    private var waiting: [Chunk] = []
    private var scheduled: [Chunk] = []
    private var remaining: [UUID: Int] = [:]
    private(set) var queuedFrames = 0
    private(set) var scheduledFrames = 0
    var isEmpty: Bool { queuedFrames == 0 }
    func canAppend(_ frames: Int) -> Bool { frames > 0 && frames <= Self.capacity - queuedFrames }

    mutating func append(_ samples: [Float], request: UUID) -> Bool {
        guard canAppend(samples.count), remaining[request] == nil else { return false }
        for offset in stride(from: 0, to: samples.count, by: Self.chunkFrames) {
            waiting.append(Chunk(id: UUID(), request: request,
                                 samples: Array(samples[offset..<min(samples.count, offset + Self.chunkFrames)])))
        }
        remaining[request] = samples.count
        queuedFrames += samples.count
        return true
    }

    mutating func takeWindow() -> [Chunk] {
        var result: [Chunk] = []
        while let first = waiting.first, scheduledFrames + first.samples.count <= Self.windowFrames {
            waiting.removeFirst(); scheduled.append(first); result.append(first)
            scheduledFrames += first.samples.count
        }
        return result
    }

    // A request finishes only after every one of its slices has played back.
    mutating func complete(_ id: UUID) -> UUID? {
        guard let index = scheduled.firstIndex(where: { $0.id == id }) else { return nil }
        let chunk = scheduled.remove(at: index)
        scheduledFrames -= chunk.samples.count; queuedFrames -= chunk.samples.count
        let frames = (remaining[chunk.request] ?? 0) - chunk.samples.count
        if frames == 0 { remaining.removeValue(forKey: chunk.request); return chunk.request }
        remaining[chunk.request] = frames
        return nil
    }

    mutating func recover() {
        // Fresh IDs make late callbacks from the old node schedule harmless.
        waiting = scheduled.map { Chunk(id: UUID(), request: $0.request, samples: $0.samples) } + waiting
        scheduled.removeAll(); scheduledFrames = 0
    }

    mutating func clear() { self = Self() }
}
