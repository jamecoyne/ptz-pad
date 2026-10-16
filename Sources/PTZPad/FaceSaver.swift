import CoreImage
import CoreVideo
import Foundation

/// Writes face crops from a full-resolution frame to `~/Desktop/PTZ Pad Faces/<date>/`.
///
/// Nothing is tracked between detection passes, so the same person can't be recognised
/// from one pass to the next; instead saving is rate-limited to one batch per interval.
final class FaceSaver {
    static var rootFolder: URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        return desktop.appendingPathComponent("PTZ Pad Faces", isDirectory: true)
    }

    /// Faces smaller than this (in source pixels) are too blurry to be worth keeping.
    private let minSide: CGFloat = 48
    private let ioQueue = DispatchQueue(label: "ptzpad.facesaver", qos: .utility)
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let lastSave = Atomic<TimeInterval>(0)
    private let saved = Atomic(0)

    var savedCount: Int { saved.value }
    var lastError: String? { error.value }
    private let error = Atomic<String?>(nil)

    init(context: CIContext, colorSpace: CGColorSpace) {
        self.context = context
        self.colorSpace = colorSpace
    }

    /// Whether a frame grabbed now would be saved — lets the render thread skip the
    /// full-size copy between saves.
    func isDue(interval: TimeInterval) -> Bool {
        Date().timeIntervalSince1970 - lastSave.value >= interval
    }

    /// Crops each face segment out of `frame` and writes it as a JPEG. Call off the render thread.
    func save(_ segments: [Segment], from frame: CVPixelBuffer, interval: TimeInterval) {
        let faces = segments.filter { $0.kind == .face }
        guard !faces.isEmpty, isDue(interval: interval) else { return }

        let W = CGFloat(CVPixelBufferGetWidth(frame)), H = CGFloat(CVPixelBufferGetHeight(frame))
        let image = CIImage(cvPixelBuffer: frame, options: [.colorSpace: colorSpace])
        let now = Date()
        var crops: [(String, CIImage)] = []
        for face in faces {
            // Detection boxes hug the face; a headshot wants some hair and chin around it.
            let r = face.rect.padded(by: 0.25)
            // NormRect is y-down, Core Image is y-up.
            let rect = CGRect(x: r.x * W, y: (1 - r.y - r.h) * H, width: r.w * W, height: r.h * H).integral
            guard rect.width >= minSide, rect.height >= minSide else { continue }
            let crop = image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            crops.append(("\(Self.timeFormatter.string(from: now))_face-\(face.number).jpg", crop))
        }
        guard !crops.isEmpty else { return }
        lastSave.value = now.timeIntervalSince1970

        // Encode before the frame's buffer goes back to its pool; only the disk write is deferred.
        let encoded: [(String, Data)] = crops.compactMap { name, crop in
            context.jpegRepresentation(of: crop, colorSpace: colorSpace, options: [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9,
            ]).map { (name, $0) }
        }
        let folder = Self.rootFolder.appendingPathComponent(Self.dayFormatter.string(from: now), isDirectory: true)
        ioQueue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, data) in encoded {
                    try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    saved.value += 1
                }
                error.value = nil
            } catch {
                self.error.value = error.localizedDescription
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH-mm-ss.SSS"
        return f
    }()
}
