import CoreGraphics
import CoreVideo
import Foundation
import Vision

// Ported from segcam (Sources/FaceSegmenter.swift, Segment.swift, Frame.swift): Vision's
// face landmarks and human rectangles, turned into labelled boxes such as `eye.L#412`.

/// A rectangle in normalized frame space: origin top-left, y down.
struct NormRect: Equatable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat

    static let zero = NormRect(x: 0, y: 0, w: 0, h: 0)

    /// Vision's rects are bottom-left origin; this is the one place they are flipped.
    static func fromVision(_ r: CGRect) -> NormRect {
        NormRect(x: r.minX, y: 1 - r.maxY, w: r.width, h: r.height)
    }

    static func bounding(_ points: [CGPoint]) -> NormRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return NormRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    func padded(by fraction: CGFloat) -> NormRect {
        let dx = w * fraction, dy = h * fraction
        return NormRect(x: x - dx, y: y - dy, w: w + 2 * dx, h: h + 2 * dy).clamped()
    }

    /// Grows the box to at least `size` on each axis, keeping the centre put.
    func atLeast(_ size: CGFloat) -> NormRect {
        var r = self
        if r.w < size { r.x -= (size - r.w) / 2; r.w = size }
        if r.h < size { r.y -= (size - r.h) / 2; r.h = size }
        return r.clamped()
    }

    func clamped() -> NormRect {
        let x0 = min(max(0, x), 1), y0 = min(max(0, y), 1)
        let x1 = min(max(0, x + w), 1), y1 = min(max(0, y + h), 1)
        return NormRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }
}

enum SegmentKind: String {
    case face, body, eyeLeft, eyeRight, mouth

    var displayName: String {
        switch self {
        case .face:     return "face"
        case .body:     return "body"
        case .eyeLeft:  return "eye.L"
        case .eyeRight: return "eye.R"
        case .mouth:    return "mouth"
        }
    }
}

struct Segment {
    let kind: SegmentKind
    let number: Int
    var rect: NormRect
    var score: Float

    var label: String { "\(kind.displayName)#\(number)" }
}

/// Which parts become boxes.
struct DetectionSettings: Equatable {
    var face = true
    var body = false
    var eyes = true
    var mouth = false

    var any: Bool { face || body || eyes || mouth }
}

/// Like segcam, nothing is tracked between frames: every detection pass is a fresh set
/// of numbered instances, so `eye.L#412`, `eye.R#412` and `face#412` are one face in one
/// pass and the next pass gets new numbers.
final class FaceDetector {
    private let sequence = VNSequenceRequestHandler()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let bodyRequest: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false          // whatever of the person is in the frame
        return request
    }()
    private var next = 1
    private let maxFaces = 8
    private let maxBodies = 8

    private func take() -> Int {
        defer { next = next >= 99_999 ? 1 : next + 1 }
        return next
    }

    func segments(in buffer: CVPixelBuffer, settings: DetectionSettings) -> [Segment] {
        // Only the requests something is switched on for — a body pass is a second model.
        var requests: [VNRequest] = []
        if settings.face || settings.eyes || settings.mouth { requests.append(faceRequest) }
        if settings.body { requests.append(bodyRequest) }
        guard !requests.isEmpty else { return [] }
        do {
            try sequence.perform(requests, on: buffer, orientation: .up)
        } catch {
            return []
        }
        let faces = requests.contains(faceRequest) ? (faceRequest.results ?? []) : []
        let bodies = requests.contains(bodyRequest) ? (bodyRequest.results ?? []) : []
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))

        var out: [Segment] = []
        for face in faces.prefix(maxFaces) {
            let number = take()
            if settings.face {
                out.append(Segment(kind: .face, number: number,
                                   rect: NormRect.fromVision(face.boundingBox).padded(by: 0.05),
                                   score: face.confidence))
            }
            guard let landmarks = face.landmarks else { continue }

            // Landmark points hug the lid and lip line, so an unpadded box reads as too tight.
            if settings.eyes, let region = landmarks.leftEye {
                out.append(Segment(kind: .eyeLeft, number: number,
                                   rect: box(region, imageSize: size).padded(by: 0.4).atLeast(0.02),
                                   score: face.confidence))
            }
            if settings.eyes, let region = landmarks.rightEye {
                out.append(Segment(kind: .eyeRight, number: number,
                                   rect: box(region, imageSize: size).padded(by: 0.4).atLeast(0.02),
                                   score: face.confidence))
            }
            if settings.mouth, let region = landmarks.outerLips {
                out.append(Segment(kind: .mouth, number: number,
                                   rect: box(region, imageSize: size).padded(by: 0.15).atLeast(0.03),
                                   score: face.confidence))
            }
        }
        if settings.body {
            for body in bodies.prefix(maxBodies) {
                out.append(Segment(kind: .body, number: take(),
                                   rect: NormRect.fromVision(body.boundingBox),
                                   score: body.confidence))
            }
        }
        return out
    }

    /// Vision landmark points are image-space, origin bottom-left — flipped here, once.
    private func box(_ region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> NormRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let points = region.pointsInImage(imageSize: imageSize).map {
            CGPoint(x: $0.x / imageSize.width, y: 1 - $0.y / imageSize.height)
        }
        return NormRect.bounding(points).clamped()
    }
}
