import AppKit
import Combine
import CoreImage
import CoreText
import CoreVideo
import Foundation
import QuartzCore
import UniformTypeIdentifiers

enum VideoEffect: String, CaseIterable, Identifiable {
    case none, edges, edgeWork, sketch, comic, posterize, pixelate, halftone,
         thermal, xray, invert, noir, bloom, kaleidoscope

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:         return "None"
        case .edges:        return "Edge detect"
        case .edgeWork:     return "Edge work"
        case .sketch:       return "Sketch"
        case .comic:        return "Comic"
        case .posterize:    return "Posterize"
        case .pixelate:     return "Pixelate"
        case .halftone:     return "Halftone"
        case .thermal:      return "Thermal"
        case .xray:         return "X-ray"
        case .invert:       return "Invert"
        case .noir:         return "Noir"
        case .bloom:        return "Bloom"
        case .kaleidoscope: return "Kaleidoscope"
        }
    }

    /// What the Amount slider does for this effect.
    var amountLabel: String {
        switch self {
        case .none:                                  return "—"
        case .edges:                                 return "Intensity"
        case .edgeWork:                              return "Thickness"
        case .sketch:                                return "Detail"
        case .posterize:                             return "Flatness"
        case .pixelate, .halftone:                   return "Size"
        case .bloom:                                 return "Glow"
        case .kaleidoscope:                          return "Rotation"
        case .comic, .thermal, .xray, .invert, .noir: return "Mix"
        }
    }
}

/// Everything the render thread needs, copied under lock so it never reads a torn value.
private struct RenderSettings {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var effect = VideoEffect.none
    var amount = 0.5
    var detection = DetectionSettings()
    var showLabels = true
    var saveFaces = false
    var saveInterval: TimeInterval = 2
    var faceOverlay = false
    var blueBackground = false
    var windowTrail = false
    var faceFill = false
    var censor = false
    var trailLimit = 100

    /// What Vision has to look for: the boxes that are drawn, plus faces while saving them.
    var vision: DetectionSettings {
        var v = detection
        if saveFaces || faceOverlay { v.face = true }
        if blueBackground || windowTrail { v.face = true; v.body = true; v.eyes = true }
        if faceFill { v.face = true }
        if censor { v.face = true; v.body = true }
        return v
    }
}

/// The camera's NDI feed: picture adjustments, a creative effect, segcam-style detection
/// boxes, then out to the preview and a Syphon server.
final class VideoController: ObservableObject {
    static let shared = VideoController()

    // MARK: Settings (persisted)
    @Published var sourceName: String { didSet { defaults.set(sourceName, forKey: "ndiSource"); connectSelected() } }
    @Published var brightness: Double { didSet { defaults.set(brightness, forKey: "brightness"); pushSettings() } }
    @Published var contrast: Double { didSet { defaults.set(contrast, forKey: "contrast"); pushSettings() } }
    @Published var saturation: Double { didSet { defaults.set(saturation, forKey: "saturation"); pushSettings() } }
    @Published var effect: VideoEffect { didSet { defaults.set(effect.rawValue, forKey: "effect"); pushSettings() } }
    @Published var effectAmount: Double { didSet { defaults.set(effectAmount, forKey: "effectAmount"); pushSettings() } }
    @Published var detectionEnabled: Bool { didSet { defaults.set(detectionEnabled, forKey: "detectionEnabled"); pushSettings() } }
    @Published var detectFaces: Bool { didSet { defaults.set(detectFaces, forKey: "detectFaces"); pushSettings() } }
    @Published var detectBodies: Bool { didSet { defaults.set(detectBodies, forKey: "detectBodies"); pushSettings() } }
    @Published var detectEyes: Bool { didSet { defaults.set(detectEyes, forKey: "detectEyes"); pushSettings() } }
    @Published var detectMouths: Bool { didSet { defaults.set(detectMouths, forKey: "detectMouths"); pushSettings() } }
    @Published var showLabels: Bool { didSet { defaults.set(showLabels, forKey: "showLabels"); pushSettings() } }
    @Published var saveFaces: Bool { didSet { defaults.set(saveFaces, forKey: "saveFaces"); pushSettings() } }
    @Published var censor: Bool { didSet { defaults.set(censor, forKey: "censor"); pushSettings() } }
    @Published var faceFill: Bool { didSet { defaults.set(faceFill, forKey: "faceFill"); pushSettings() } }
    @Published var windowTrail: Bool { didSet { defaults.set(windowTrail, forKey: "windowTrail"); pushSettings() } }
    @Published var trailLimit: Int { didSet { defaults.set(trailLimit, forKey: "trailLimit"); pushSettings() } }
    @Published var blueBackground: Bool { didSet { defaults.set(blueBackground, forKey: "blueBackground"); pushSettings() } }
    @Published var faceOverlay: Bool { didSet { defaults.set(faceOverlay, forKey: "faceOverlay"); pushSettings(); reloadFaceLibrary() } }
    @Published var saveFaceInterval: Double { didSet { defaults.set(saveFaceInterval, forKey: "saveFaceInterval"); pushSettings() } }
    @Published var syphonEnabled: Bool { didSet { defaults.set(syphonEnabled, forKey: "syphonEnabled"); updateSyphon() } }
    @Published var syphonName: String { didSet { defaults.set(syphonName, forKey: "syphonName") } }
    @Published var testVideoEnabled: Bool { didSet { defaults.set(testVideoEnabled, forKey: "testVideoEnabled"); updateTestVideo() } }
    @Published var testVideoPath: String { didSet { defaults.set(testVideoPath, forKey: "testVideoPath"); restartTestVideo() } }
    @Published var syphonFlip: Bool { didSet { defaults.set(syphonFlip, forKey: "syphonFlip"); syphon.flipped = syphonFlip } }

    // MARK: Status
    @Published private(set) var sources: [NDISource] = []
    @Published private(set) var connectedSource: NDISource?
    @Published private(set) var frameSize: CGSize?
    @Published private(set) var fps: Double = 0
    @Published private(set) var detectionCount = 0
    @Published private(set) var savedFaceCount = 0
    @Published private(set) var libraryFaceCount = 0
    @Published private(set) var trailWindowCount = 0
    @Published private(set) var faceSaveError: String?
    @Published private(set) var syphonClients = false
    @Published private(set) var ndiError: String?
    @Published private(set) var usingTestVideo = false
    @Published private(set) var testVideoError: String?

    /// The preview shows whatever IOSurface was last rendered — the exact frame Syphon gets.
    let previewLayer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }()

    private let defaults = UserDefaults.standard
    private let finder = NDIFinder()
    private var receiver: NDIReceiver?
    private let syphon = SyphonPublisher()
    private var statusTimer: Timer?
    private var testPlayer: TestVideoPlayer?
    /// When the last NDI frame arrived; the test video only plays while this is stale.
    private let lastNDIFrame = Atomic<CFAbsoluteTime>(0)
    private let ndiTimeout: CFAbsoluteTime = 2

    /// The sample clip at the top of the repo — found from this file's build-time path, so
    /// it works for builds made on this machine; anywhere else, pick a file instead.
    static let bundledTestVideo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("crowd sample.mov").path

    // Render-thread state. NDI and the test video each have their own thread; the lock
    // keeps them from rendering at once during a hand-over.
    private let renderLock = NSLock()
    private let settingsLock = NSLock()
    private var renderSettings = RenderSettings()
    private let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var outputPool: CVPixelBufferPool?
    private var outputSize = CGSize.zero
    private var visionPool: CVPixelBufferPool?
    private var visionSize = CGSize.zero
    private let frameCounter = Atomic(0)
    private let previewPending = Atomic(false)

    // Detection runs on its own queue against a downscaled copy, a pass at a time; the
    // render thread draws whatever the latest pass found.
    private let detector = FaceDetector()
    private let visionQueue = DispatchQueue(label: "ptzpad.vision", qos: .userInitiated)
    private let visionBusy = Atomic(false)
    private let latestSegments = Atomic<[Segment]>([])

    // Face saving crops from a full-size copy of the frame Vision looked at.
    private lazy var faceSaver = FaceSaver(context: ciContext, colorSpace: sRGB)
    private let faceLibrary = FaceLibrary()

    // Window trail: render-thread only, fed once per detection pass.
    private let trail = WindowTrail()
    private let segmentPass = Atomic(0)
    private var trailedPass = 0
    private let trailClearRequested = Atomic(false)
    private let trailSize = Atomic(0)

    // Face fill: render-thread only. The last faces seen are held briefly so a pass that
    // misses doesn't flash the whole frame.
    private var heldFaces: [NormRect] = []
    private var heldUntil: CFTimeInterval = 0
    private let strobeInterval: CFTimeInterval = 0.2
    private let faceHold: CFTimeInterval = 1

    // Censor: render-thread only. Every box stays up for a while after its pass, so a
    // pass that misses a face doesn't uncover it.
    private var censorBoxes: [(segment: Segment, until: CFTimeInterval)] = []
    private var censoredPass = 0
    private let censorHold: CFTimeInterval = 0.5
    private var ticks = 0
    private var facePool: CVPixelBufferPool?
    private var faceSize = CGSize.zero

    private init() {
        sourceName = defaults.string(forKey: "ndiSource") ?? ""
        brightness = defaults.object(forKey: "brightness") as? Double ?? 0
        contrast = defaults.object(forKey: "contrast") as? Double ?? 1
        saturation = defaults.object(forKey: "saturation") as? Double ?? 1
        effect = VideoEffect(rawValue: defaults.string(forKey: "effect") ?? "") ?? .none
        effectAmount = defaults.object(forKey: "effectAmount") as? Double ?? 0.5
        detectionEnabled = defaults.bool(forKey: "detectionEnabled")
        detectFaces = defaults.object(forKey: "detectFaces") as? Bool ?? true
        detectBodies = defaults.object(forKey: "detectBodies") as? Bool ?? true
        detectEyes = defaults.object(forKey: "detectEyes") as? Bool ?? true
        detectMouths = defaults.object(forKey: "detectMouths") as? Bool ?? false
        showLabels = defaults.object(forKey: "showLabels") as? Bool ?? true
        saveFaces = defaults.bool(forKey: "saveFaces")
        faceOverlay = defaults.bool(forKey: "faceOverlay")
        blueBackground = defaults.bool(forKey: "blueBackground")
        windowTrail = defaults.bool(forKey: "windowTrail")
        faceFill = defaults.bool(forKey: "faceFill")
        censor = defaults.bool(forKey: "censor")
        trailLimit = defaults.object(forKey: "trailLimit") as? Int ?? 100
        saveFaceInterval = defaults.object(forKey: "saveFaceInterval") as? Double ?? 2
        syphonEnabled = defaults.object(forKey: "syphonEnabled") as? Bool ?? true
        syphonName = defaults.string(forKey: "syphonName") ?? "Camera"
        // Resolume reads Syphon surfaces bottom-up (OpenGL rows), so flipped is what it wants.
        syphonFlip = defaults.object(forKey: "syphonFlip") as? Bool ?? true
        testVideoEnabled = defaults.object(forKey: "testVideoEnabled") as? Bool ?? true
        testVideoPath = defaults.string(forKey: "testVideoPath") ?? VideoController.bundledTestVideo
        syphon.flipped = syphonFlip
        pushSettings()
    }

    // MARK: Lifecycle

    func start() {
        ndiError = NDILibrary.shared.error
        finder.onChange = { [weak self] sources in
            guard let self else { return }
            self.sources = sources
            self.autoSelect()
        }
        finder.start()
        updateSyphon()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    func shutdown() {
        receiver?.stop()
        receiver = nil
        stopTestVideo()
        finder.stop()
        syphon.stop()
    }

    private func reloadFaceLibrary() {
        if faceOverlay { faceLibrary.reload(from: FaceSaver.rootFolder) }
    }

    func clearTrail() { trailClearRequested.value = true }

    func revealSavedFaces() {
        let folder = FaceSaver.rootFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func resetPicture() {
        brightness = 0
        contrast = 1
        saturation = 1
    }

    private func tick() {
        let frames = frameCounter.value
        frameCounter.value = 0
        fps = Double(frames)
        syphonClients = syphon.hasClients
        let drawn = currentSettings().detection
        detectionCount = latestSegments.value.filter { drawn.includes($0.kind) }.count
        savedFaceCount = faceSaver.savedCount
        libraryFaceCount = faceLibrary.count
        trailWindowCount = trailSize.value
        ticks += 1
        if faceOverlay, ticks % 3 == 0 { reloadFaceLibrary() }
        faceSaveError = faceSaver.lastError
        updateTestVideo()
        if let error = testPlayer?.error { testVideoError = error }
        if frames == 0, connectedSource != nil || usingTestVideo { frameSize = nil }
    }

    private func pushSettings() {
        let s = RenderSettings(
            brightness: brightness, contrast: contrast, saturation: saturation,
            effect: effect, amount: effectAmount,
            detection: detectionEnabled
                ? DetectionSettings(face: detectFaces, body: detectBodies, eyes: detectEyes, mouth: detectMouths)
                : DetectionSettings(face: false, body: false, eyes: false, mouth: false),
            showLabels: showLabels, saveFaces: saveFaces, saveInterval: saveFaceInterval,
            faceOverlay: faceOverlay, blueBackground: blueBackground,
            windowTrail: windowTrail, faceFill: faceFill, censor: censor, trailLimit: trailLimit)
        settingsLock.lock()
        renderSettings = s
        settingsLock.unlock()
        if !s.vision.any { latestSegments.value = [] }
    }

    private func currentSettings() -> RenderSettings {
        settingsLock.lock(); defer { settingsLock.unlock() }
        return renderSettings
    }

    // MARK: Source selection

    /// With nothing chosen yet, pick the NDI source on the camera's IP — the PTZ camera's
    /// own stream — so it works out of the box.
    private func autoSelect() {
        if sourceName.isEmpty,
           let match = sources.first(where: { $0.host == CameraController.shared.host }) {
            sourceName = match.name          // didSet connects
        } else {
            connectSelected()
        }
    }

    private func connectSelected() {
        if receiver?.source.name == sourceName { return }
        receiver?.stop()
        receiver = nil
        connectedSource = nil
        frameSize = nil
        latestSegments.value = []
        // A source that isn't announced yet is connected when it appears.
        guard !sourceName.isEmpty, let source = sources.first(where: { $0.name == sourceName }),
              let r = NDIReceiver(source: source) else { return }
        r.onFrame = { [weak self] data, w, h, stride in
            guard let self else { return }
            lastNDIFrame.value = CFAbsoluteTimeGetCurrent()
            process(data: data, width: w, height: h, stride: stride)
        }
        r.start()
        receiver = r
        connectedSource = source
    }

    // MARK: Test video

    private var ndiLive: Bool { CFAbsoluteTimeGetCurrent() - lastNDIFrame.value < ndiTimeout }

    /// Plays the test video while it's switched on and the camera has sent nothing for a
    /// couple of seconds; stops it as soon as NDI frames come back.
    private func updateTestVideo() {
        let want = testVideoEnabled && !ndiLive && !testVideoPath.isEmpty
        if want, testPlayer == nil {
            guard FileManager.default.fileExists(atPath: testVideoPath) else {
                testVideoError = "Test video not found — choose a file"
                return
            }
            testVideoError = nil
            let player = TestVideoPlayer(url: URL(fileURLWithPath: testVideoPath))
            player.onFrame = { [weak self] data, w, h, stride in
                guard let self, !ndiLive else { return }
                process(data: data, width: w, height: h, stride: stride)
            }
            player.start()
            testPlayer = player
            usingTestVideo = true
            latestSegments.value = []
        } else if !want, testPlayer != nil {
            stopTestVideo()
        }
        if !testVideoEnabled { testVideoError = nil }
    }

    private func stopTestVideo() {
        testPlayer?.stop()
        testPlayer = nil
        if usingTestVideo {
            usingTestVideo = false
            latestSegments.value = []
        }
    }

    private func restartTestVideo() {
        stopTestVideo()
        updateTestVideo()
    }

    func chooseTestVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        if !testVideoPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: testVideoPath).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            testVideoPath = url.path
        }
    }

    private func updateSyphon() {
        if syphonEnabled {
            syphon.start(name: syphonName.isEmpty ? "Camera" : syphonName)
        } else {
            syphon.stop()
        }
    }

    /// Restart the server under the new name.
    func applySyphonName() {
        guard syphonEnabled else { return }
        syphon.stop()
        updateSyphon()
    }

    // MARK: Render thread

    private func process(data: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) {
        renderLock.lock(); defer { renderLock.unlock() }
        // Wrap NDI's frame without copying; it is freed as soon as this returns, so every
        // render below is waited on.
        var wrapped: CVPixelBuffer?
        CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                     data, stride, nil, nil, nil, &wrapped)
        guard let input = wrapped else { return }
        let s = currentSettings()
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        var image = CIImage(cvPixelBuffer: input, options: [.colorSpace: sRGB]).settingAlphaOne(in: extent)
        if s.brightness != 0 || s.contrast != 1 || s.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: s.brightness,
                kCIInputContrastKey: s.contrast,
                kCIInputSaturationKey: s.saturation,
            ])
        }

        // Detection looks at the adjusted picture but before the effect — edge detection
        // or a posterize would leave Vision nothing to find.
        if s.vision.any, !visionBusy.value {
            detect(image, extent: extent, settings: s)
        }

        image = apply(s.effect, amount: s.amount, to: image, extent: extent).cropped(to: extent)
        // Censoring comes before the looks below, so face fill, the trail and the blue
        // background all carry the pixelation with them.
        if s.censor {
            image = pixelate(image, segments: heldCensorBoxes(), extent: extent)
        } else if !censorBoxes.isEmpty {
            censorBoxes.removeAll()
        }
        // Face fill takes over the whole frame, so the frame-wide looks and the overlays
        // that sit on face positions are skipped while it's showing a face.
        var filled = false
        if s.faceFill, let zoomed = fillWithFace(image, extent: extent) {
            image = zoomed
            filled = true
        }
        if filled {
            if trail.count > 0 { trail.clear(); trailSize.value = 0 }
        } else if s.windowTrail {
            updateTrail(from: image, extent: extent, limit: s.trailLimit)
            image = VideoController.black.cropped(to: extent)       // the windows are drawn after
        } else {
            if trail.count > 0 { trail.clear(); trailSize.value = 0 }
            if s.blueBackground {
                image = cutOut(image, keeping: latestSegments.value, extent: extent)
            }
        }

        guard let output = outputBuffer(width: width, height: height) else { return }
        render(image, to: output)

        CVPixelBufferLockBaseAddress(output, [])
        if let base = CVPixelBufferGetBaseAddress(output) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(output)
            if !filled, s.windowTrail, trail.count > 0,
               let ctx = bitmapContext(base, width: width, height: height, stride: bytesPerRow) {
                trail.draw(in: ctx)
            }
            if !filled, s.faceOverlay {
                pasteFaces(latestSegments.value.filter { $0.kind == .face }, into: base,
                           width: width, height: height, stride: bytesPerRow)
            }
            if !filled, s.detection.any {
                drawBoxes(latestSegments.value.filter { s.detection.includes($0.kind) }, into: base, width: width, height: height,
                          stride: bytesPerRow, labels: s.showLabels)
            }
            syphon.publish(base: base, width: width, height: height, stride: bytesPerRow)
        }
        CVPixelBufferUnlockBaseAddress(output, [])

        frameCounter.value += 1
        showInPreview(output, size: CGSize(width: width, height: height))
    }

    private func render(_ image: CIImage, to buffer: CVPixelBuffer) {
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = sRGB
        _ = try? ciContext.startTask(toRender: image, to: destination).waitUntilCompleted()
    }

    private func outputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if outputPool == nil || outputSize != size {
            outputPool = makePool(width: width, height: height)
            outputSize = size
        }
        guard let outputPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &buffer)
        return buffer
    }

    private func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                attributes as CFDictionary, &pool)
        return pool
    }

    private func showInPreview(_ buffer: CVPixelBuffer, size: CGSize) {
        // One pending preview update at most: the main thread never falls behind the feed.
        guard !previewPending.value,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        previewPending.value = true
        DispatchQueue.main.async { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.contents = surface
            CATransaction.commit()
            withExtendedLifetime(buffer) {}
            if frameSize != size { frameSize = size }
            previewPending.value = false
        }
    }

    // MARK: Effects

    private func apply(_ effect: VideoEffect, amount: Double, to image: CIImage, extent: CGRect) -> CIImage {
        let a = min(1, max(0, amount))
        let center = CIVector(x: extent.midX, y: extent.midY)
        func mix(_ filtered: CIImage) -> CIImage {
            filtered.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: image.cropped(to: extent), kCIInputTimeKey: 1 - a,
            ])
        }
        // Edge work and line overlay draw strokes on a transparent background.
        func over(_ color: CIColor, _ filtered: CIImage) -> CIImage {
            filtered.composited(over: CIImage(color: color).cropped(to: extent))
        }

        switch effect {
        case .none:
            return image
        case .edges:
            return image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1 + a * 15])
        case .edgeWork:
            return over(.black, image.applyingFilter("CIEdgeWork", parameters: [kCIInputRadiusKey: 1 + a * 8]))
        case .sketch:
            return over(.white, image.applyingFilter("CILineOverlay", parameters: [
                "inputThreshold": 0.3 - a * 0.28,
                "inputEdgeIntensity": 1 + a * 2,
            ]))
        case .comic:
            return mix(image.applyingFilter("CIComicEffect"))
        case .posterize:
            return image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 2 + (1 - a) * 12])
        case .pixelate:
            return image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: center,
                kCIInputScaleKey: max(2, a * extent.width / 24),
            ])
        case .halftone:
            return image.applyingFilter("CIDotScreen", parameters: [
                kCIInputCenterKey: center,
                kCIInputWidthKey: 4 + a * 36,
                kCIInputAngleKey: 0.4,
                kCIInputSharpnessKey: 0.7,
            ])
        case .thermal:
            return mix(image.applyingFilter("CIThermal"))
        case .xray:
            return mix(image.applyingFilter("CIXRay"))
        case .invert:
            return mix(image.applyingFilter("CIColorInvert"))
        case .noir:
            return mix(image.applyingFilter("CIPhotoEffectNoir"))
        case .bloom:
            return image.applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: extent.height / 60,
                kCIInputIntensityKey: a * 2,
            ])
        case .kaleidoscope:
            return image.applyingFilter("CIKaleidoscope", parameters: [
                kCIInputCenterKey: center,
                "inputCount": 6,
                kCIInputAngleKey: a * 2 * Double.pi,
            ])
        }
    }

    // MARK: Black background

    private static let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))

    /// Keeps the picture only inside face, body and eye boxes; everything else is solid
    /// black. Nothing detected means an all-black frame.
    private func cutOut(_ image: CIImage, keeping segments: [Segment], extent: CGRect) -> CIImage {
        let W = extent.width, H = extent.height
        // Union of the boxes as a white-on-transparent mask; NormRect is y-down, CI is y-up.
        var mask = CIImage.empty()
        for segment in segments where segment.kind != .mouth {
            let r = segment.rect
            let rect = CGRect(x: r.x * W, y: (1 - r.y - r.h) * H, width: r.w * W, height: r.h * H).integral
            mask = CIImage(color: .white).cropped(to: rect).composited(over: mask)
        }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: VideoController.black.cropped(to: extent),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }

    // MARK: Censor

    /// This pass's face and body boxes plus any from the last half second.
    private func heldCensorBoxes() -> [Segment] {
        let now = CACurrentMediaTime()
        let pass = segmentPass.value
        if pass != censoredPass {
            censoredPass = pass
            for segment in latestSegments.value where segment.kind == .face || segment.kind == .body {
                censorBoxes.append((segment, now + censorHold))
            }
        }
        censorBoxes.removeAll { $0.until < now }
        return censorBoxes.map(\.segment)
    }

    /// Big square pixels over every face and body box. Bodies first, so a face inside a
    /// body gets its own, finer blocks on top.
    private func pixelate(_ image: CIImage, segments: [Segment], extent: CGRect) -> CIImage {
        let W = extent.width, H = extent.height
        let boxes = segments.filter { $0.kind == .body } + segments.filter { $0.kind == .face }
        var out = image
        for segment in boxes {
            let r = segment.rect
            let rect = CGRect(x: r.x * W, y: (1 - r.y - r.h) * H, width: r.w * W, height: r.h * H)
                .integral.intersection(extent)
            guard rect.width >= 2, rect.height >= 2 else { continue }
            // About eight blocks across the shorter side, never finer than 6 px.
            let block = max(6, min(rect.width, rect.height) / 8)
            let blocks = image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),     // grid starts at the box
                kCIInputScaleKey: block,
            ])
            out = blocks.cropped(to: rect).composited(over: out)
        }
        return out.cropped(to: extent)
    }

    // MARK: Face fill

    /// One detected face blown up to fill the frame; with several, a different one every
    /// 200 ms, left to right. Nil when there's no face to show.
    private func fillWithFace(_ image: CIImage, extent: CGRect) -> CIImage? {
        let now = CACurrentMediaTime()
        let faces = latestSegments.value.filter { $0.kind == .face }.map(\.rect).sorted { $0.x < $1.x }
        if !faces.isEmpty {
            heldFaces = faces
            heldUntil = now + faceHold
        } else if now > heldUntil {
            heldFaces = []
        }
        guard !heldFaces.isEmpty else { return nil }
        let face = heldFaces[Int(now / strobeInterval) % heldFaces.count]

        // The face with some head around it, widened to the frame's shape so nothing is
        // stretched, then slid back inside the frame.
        let W = extent.width, H = extent.height
        let r = face.padded(by: 0.25)
        var rect = CGRect(x: r.x * W, y: (1 - r.y - r.h) * H, width: r.w * W, height: r.h * H)
        let aspect = W / H
        if rect.width / rect.height < aspect {
            rect = rect.insetBy(dx: -(rect.height * aspect - rect.width) / 2, dy: 0)
        } else {
            rect = rect.insetBy(dx: 0, dy: -(rect.width / aspect - rect.height) / 2)
        }
        rect.origin.x = min(max(0, rect.minX), max(0, W - rect.width))
        rect.origin.y = min(max(0, rect.minY), max(0, H - rect.height))
        guard rect.width > 1, rect.height > 1 else { return nil }

        let scale = W / rect.width
        return image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
            .cropped(to: extent)
    }

    // MARK: Window trail

    /// One new window per segment of each new detection pass, cut from this frame.
    private func updateTrail(from image: CIImage, extent: CGRect, limit: Int) {
        if trailClearRequested.value {
            trailClearRequested.value = false
            trail.clear()
        }
        let pass = segmentPass.value
        if pass != trailedPass {
            trailedPass = pass
            trail.add(latestSegments.value.filter { $0.kind != .mouth }, from: image, extent: extent,
                      context: ciContext, colorSpace: sRGB, limit: limit)
        }
        trailSize.value = trail.count
    }

    // MARK: Detection

    private func detect(_ image: CIImage, extent: CGRect, settings s: RenderSettings) {
        // Vision does as well at 960 wide as at full size, in a fraction of the time.
        let scale = min(1, 960 / extent.width)
        let w = Int((extent.width * scale).rounded()), h = Int((extent.height * scale).rounded())
        let size = CGSize(width: w, height: h)
        if visionPool == nil || visionSize != size {
            visionPool = makePool(width: w, height: h)
            visionSize = size
        }
        guard let visionPool else { return }
        var small: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, visionPool, &small)
        guard let small else { return }
        render(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: small)

        // The NDI frame is gone once process() returns, so a face save needs its own
        // full-size copy — only made when a save is due, not every pass.
        var full: CVPixelBuffer?
        if s.saveFaces, faceSaver.isDue(interval: s.saveInterval) {
            let width = Int(extent.width), height = Int(extent.height)
            if facePool == nil || faceSize != extent.size {
                facePool = makePool(width: width, height: height)
                faceSize = extent.size
            }
            if let facePool {
                CVPixelBufferPoolCreatePixelBuffer(nil, facePool, &full)
                if let full { render(image, to: full) }
            }
        }

        visionBusy.value = true
        visionQueue.async { [weak self] in
            guard let self else { return }
            let found = detector.segments(in: small, settings: s.vision)
            // A pass that finishes after detection was switched off must not bring boxes back.
            let now = currentSettings()
            if now.vision.any {
                latestSegments.value = found
                segmentPass.value += 1
            }
            if let full, now.saveFaces { faceSaver.save(found, from: full, interval: now.saveInterval) }
            visionBusy.value = false
        }
    }

    private static let boxBlue = CGColor(srgbRed: 0.15, green: 0.45, blue: 1, alpha: 1)

    /// segcam's windowed-mode look, in blue: a box per segment with its ID on a blue chip.
    private func bitmapContext(_ base: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) -> CGContext? {
        CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: stride, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Face swap: a random saved crop over every detected face, re-picked every frame,
    /// pasted as a hard-edged rectangle.
    private func pasteFaces(_ faces: [Segment], into base: UnsafeMutableRawPointer,
                            width: Int, height: Int, stride: Int) {
        guard !faces.isEmpty, faceLibrary.count > 0,
              let ctx = bitmapContext(base, width: width, height: height, stride: stride) else { return }
        let W = CGFloat(width), H = CGFloat(height)
        ctx.interpolationQuality = .medium
        for face in faces {
            guard let image = faceLibrary.random() else { break }
            // Saved crops carry 25% padding around the face; match it so features line up.
            let r = face.rect.padded(by: 0.25)
            let rect = CGRect(x: r.x * W, y: H - (r.y + r.h) * H, width: r.w * W, height: r.h * H)
            guard rect.width > 4, rect.height > 4 else { continue }
            ctx.draw(image, in: rect)
        }
    }

    private func drawBoxes(_ segments: [Segment], into base: UnsafeMutableRawPointer,
                           width: Int, height: Int, stride: Int, labels: Bool) {
        guard !segments.isEmpty,
              let ctx = bitmapContext(base, width: width, height: height, stride: stride) else { return }

        // Memory row 0 is the top of the picture and CG's y runs up, so flip NormRect's y.
        let W = CGFloat(width), H = CGFloat(height)
        let line = max(2, (H / 360).rounded())
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, max(10, H / 54), nil)
        ctx.setStrokeColor(VideoController.boxBlue)
        ctx.setFillColor(VideoController.boxBlue)
        ctx.setLineWidth(line)

        for segment in segments {
            let r = segment.rect
            let rect = CGRect(x: r.x * W, y: H - (r.y + r.h) * H, width: r.w * W, height: r.h * H)
            guard rect.width > 1, rect.height > 1 else { continue }
            ctx.stroke(rect.insetBy(dx: -line / 2, dy: -line / 2))

            guard labels else { continue }
            let text = NSAttributedString(string: segment.label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor.white,
            ])
            let ctLine = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            let pad = line * 2
            var chip = CGRect(x: rect.minX - line, y: rect.maxY + line,
                              width: bounds.width + pad * 2, height: bounds.height + pad)
            if chip.maxY > H { chip.origin.y = rect.maxY - chip.height - line }   // box at the top edge
            ctx.setFillColor(VideoController.boxBlue)
            ctx.fill(chip)
            ctx.textPosition = CGPoint(x: chip.minX + pad, y: chip.minY + pad / 2 - bounds.minY)
            CTLineDraw(ctLine, ctx)
        }
    }
}
