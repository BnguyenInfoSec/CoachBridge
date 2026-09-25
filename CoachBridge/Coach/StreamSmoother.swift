import Foundation

/// Evens out a streamed reply.
///
/// The API delivers text in bursts — a few words, a pause, then a paragraph — and appending each
/// burst straight to the screen reads as a stutter. This buffers what arrives and releases it at
/// a steady rate, speeding up when the backlog grows so it never falls behind the model, and
/// flushing whatever's left the moment the stream ends.
@MainActor
final class StreamSmoother {
    /// Characters per second when the buffer is roughly keeping pace. Chosen to sit a little
    /// above comfortable reading speed, so it feels alive rather than slow.
    private let baseRate: Double = 110
    /// Never emit slower than this once a backlog builds, or the tail lags the model badly.
    private let maxRate: Double = 900
    private let tick: Duration = .milliseconds(33)   // ~30 fps

    private var pending = ""
    private var task: Task<Void, Never>?
    private var finished = false
    private let emit: (String) -> Void

    init(emit: @escaping (String) -> Void) {
        self.emit = emit
    }

    /// Queues a chunk from the stream.
    func push(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        pending += chunk
        start()
    }

    /// The stream ended: release everything still buffered and stop.
    func finish() {
        finished = true
        if !pending.isEmpty {
            emit(pending)
            pending = ""
        }
        task?.cancel()
        task = nil
    }

    /// The stream was cancelled: drop what's left rather than finishing a sentence the model
    /// never sent.
    func cancel() {
        pending = ""
        finished = true
        task?.cancel()
        task = nil
    }

    private func start() {
        guard task == nil, !finished else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.pending.isEmpty {
                    self.task = nil
                    return
                }
                let n = self.batchSize()
                let piece = String(self.pending.prefix(n))
                self.pending.removeFirst(piece.count)
                self.emit(piece)
                try? await Task.sleep(for: self.tick)
            }
        }
    }

    /// How much to release this frame. The rate scales with the backlog, so a long pause
    /// followed by a big burst catches up quickly instead of trickling for ten seconds.
    private func batchSize() -> Int {
        let seconds = Double(tick.components.attoseconds) / 1e18 + Double(tick.components.seconds)
        let backlog = Double(pending.count)
        // 0 at an empty buffer, 1 once about 400 characters are waiting.
        let pressure = min(1, backlog / 400)
        let rate = baseRate + (maxRate - baseRate) * pressure * pressure
        return max(1, Int((rate * seconds).rounded()))
    }
}
