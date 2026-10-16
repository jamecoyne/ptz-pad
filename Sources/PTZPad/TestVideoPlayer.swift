import AVFoundation
import CoreVideo
import Foundation

/// Loops a movie file on its own thread at its own frame rate, handing out BGRA frames the
/// same way `NDIReceiver` does, so the rest of the pipeline can't tell the difference.
final class TestVideoPlayer {
    /// Called on the player thread; same contract as `NDIReceiver.onFrame`.
    var onFrame: ((_ data: UnsafeMutableRawPointer, _ width: Int, _ height: Int, _ stride: Int) -> Void)?

    let url: URL
    private var thread: Thread?
    private let running = Atomic(false)
    private let finished = DispatchSemaphore(value: 0)
    var error: String? { failure.value }
    private let failure = Atomic<String?>(nil)

    init(url: URL) {
        self.url = url
    }

    func start() {
        guard thread == nil else { return }
        running.value = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "ptzpad.testvideo"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Blocks until the playback loop has exited.
    func stop() {
        guard thread != nil else { return }
        running.value = false
        finished.wait()
        thread = nil
    }

    deinit { stop() }

    private func loop() {
        defer { finished.signal() }
        let asset = AVURLAsset(url: url)
        guard let track = videoTrack(of: asset) else {
            failure.value = "Can't read \(url.lastPathComponent)"
            return
        }
        while running.value {
            guard playOnce(asset, track: track) else { return }
        }
    }

    /// The async track loader, waited on — this is already a dedicated thread.
    private func videoTrack(of asset: AVURLAsset) -> AVAssetTrack? {
        let done = DispatchSemaphore(value: 0)
        let track = Atomic<AVAssetTrack?>(nil)
        Task {
            track.value = try? await asset.loadTracks(withMediaType: .video).first
            done.signal()
        }
        done.wait()
        return track.value
    }

    /// One pass through the file; false if it can't be read at all.
    private func playOnce(_ asset: AVURLAsset, track: AVAssetTrack) -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else {
            failure.value = "Can't read \(url.lastPathComponent)"
            return false
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            failure.value = reader.error?.localizedDescription ?? "Can't play \(url.lastPathComponent)"
            return false
        }
        defer { reader.cancelReading() }

        // Pace frames against the wall clock from the first frame's timestamp.
        var clockStart: CFAbsoluteTime?
        var firstPTS: Double = 0
        while running.value, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let start = clockStart {
                let wait = (pts - firstPTS) - (CFAbsoluteTimeGetCurrent() - start)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                // Fell far behind (machine asleep, debugger): re-anchor instead of racing.
                if wait < -0.5 { clockStart = CFAbsoluteTimeGetCurrent(); firstPTS = pts }
            } else {
                clockStart = CFAbsoluteTimeGetCurrent()
                firstPTS = pts
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                onFrame?(base, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                         CVPixelBufferGetBytesPerRow(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        return true
    }
}
