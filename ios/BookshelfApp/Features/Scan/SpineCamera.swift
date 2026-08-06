import AVFoundation
import BookshelfCore
import CoreImage
import Vision
import SwiftUI
import UIKit

/// The camera for photographing a book's spine.
///
/// `AVCaptureSession` rather than `UIImagePickerController` because the whole
/// point is the guide rectangle: the user has to see what will be kept, and a
/// system picker has nowhere to put it.
///
/// The guide and the crop are driven from the *same* rect, and the preview is
/// `resizeAspectFill` — so what's on screen is a centred window onto the photo
/// rather than the whole of it. `SpineCrop` maps between the two, and it lives
/// in BookshelfCore so that mapping can be tested; getting it wrong produces a
/// crop rotated by 90°, which is precisely what the first version did.
@MainActor
final class SpineCameraController: NSObject, ObservableObject {


    /// The guide, in the preview's coordinates. Written by the view on layout.
    var guideRect: CGRect = .zero
    /// The preview's own size, needed to work out which part of the photo it
    /// was showing — `resizeAspectFill` means it is a window, not the whole.
    var previewSize: CGSize = .zero
    /// Held only to convert a tap into device coordinates; the crop no longer
    /// depends on it.
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    @Published var failure: String?
    /// The spine the camera can currently see, normalised with a top-left
    /// origin. Nil when nothing convincing is in frame, which is when the
    /// centred guide takes over.
    @Published var detected: SpineQuad?
    /// Width over height of the camera frame, in display orientation. Needed
    /// to place a detection on a preview that only shows part of that frame.
    @Published var bufferAspect: Double = 3.0 / 4.0

    enum CaptureError: LocalizedError {
        case noImage, cropFailed

        var errorDescription: String? {
            switch self {
            case .noImage: "The camera didn't return a photo. Try again."
            case .cropFailed: "Couldn't read that photo. Try again with the spine inside the frame."
            }
        }
    }

    private var completion: ((Result<Data, Error>) -> Void)?

    // MARK: - Session
    //
    // `AVCaptureSession` is not `Sendable` and must not be configured on the main
    // thread — `startRunning` blocks. AVFoundation's own answer is a serial queue
    // that owns the session, which is what `SessionBox` is: unchecked `Sendable`
    // backed by a real invariant, namely that every touch happens on that queue.

    private let box = SessionBox()
    private let detector = SpineDetector()

    var session: AVCaptureSession { box.session }

    func start() async {
        guard await Self.authorized() else {
            failure = "Bookshelf doesn't have camera access. Turn it on in Settings › Bookshelf."
            return
        }
        // Smoothed on the way in: raw detections jitter frame to frame, and a
        // box that twitches reads as broken even when it is finding the right
        // thing. Snapping straight to a *new* spine is right, though — easing
        // across the screen would look like a bug of its own.
        detector.onResult = { [weak self] quad in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let quad else {
                    detected = nil
                    return
                }
                if let current = detected, current.boundingBox.intersects(quad.boundingBox) {
                    detected = current.blended(towards: quad, amount: 0.35)
                } else {
                    detected = quad
                }
            }
        }
        box.onFrame = { [weak self, detector] buffer, orientation in
            if let pixels = CMSampleBufferGetImageBuffer(buffer) {
                // Rotated for display, so the sensor's width becomes height.
                let w = Double(CVPixelBufferGetHeight(pixels))
                let h = Double(CVPixelBufferGetWidth(pixels))
                if h > 0 {
                    Task { @MainActor [weak self] in self?.bufferAspect = w / h }
                }
            }
            detector.process(buffer, orientation: orientation)
        }
        await box.startRunning()
    }

    func stop() {
        box.stopRunning()
    }

    /// Tap-to-focus. `point` is in the preview's coordinates; the layer converts
    /// it to the device's own space, which accounts for the aspect-fill window.
    func focus(at point: CGPoint, in layer: AVCaptureVideoPreviewLayer?) {
        guard let layer else { return }
        box.focus(at: layer.captureDevicePointConverted(fromLayerPoint: point))
    }

    static func authorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    // MARK: - Capture

    func capture() async throws -> Data {
        guard box.isRunning else { throw CaptureError.noImage }
        return try await withCheckedThrowingContinuation { continuation in
            completion = { continuation.resume(with: $0) }
            box.capture(delegate: self)
        }
    }
}

extension SpineCameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // `photo` isn't Sendable; pull the bytes out here and hop with those.
        let data = photo.fileDataRepresentation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let finish = completion
            completion = nil
            if let error { finish?(.failure(error)); return }
            guard let data, let image = UIImage(data: data) else {
                finish?(.failure(CaptureError.noImage))
                return
            }
            guard let cropped = crop(image) else {
                finish?(.failure(CaptureError.cropFailed))
                return
            }
            finish?(.success(cropped))
        }
    }
}

extension SpineCameraController {
    /// Crop to the guide, then shrink to what a spine on a shelf actually needs.
    ///
    /// The photo is normalised to `.up` first. A capture from the back camera in
    /// portrait arrives as a landscape pixel buffer with an EXIF rotation, so its
    /// pixel space and the preview's point space disagree about which way is up.
    /// The first version tried to bridge that with
    /// `metadataOutputRectConverted` and an axis swap, and got it 90° wrong: the
    /// result was a wide landscape sliver where a spine should be. Baking the
    /// rotation in makes the two spaces the same and the question disappears.
    func crop(_ image: UIImage) -> Data? {
        let upright = image.normalisedUp()
        guard let cgImage = upright.cgImage else { return nil }

        // A detected spine is rarely perfectly parallel to the phone, so it
        // arrives as a slight trapezium. Straightening it keeps the background
        // out of the corners, which cropping its bounding box would not.
        if let quad = detected,
           let straightened = SpinePerspective.straighten(CIImage(cgImage: cgImage), quad: quad),
           let rendered = Self.render(straightened) {
            return Self.shrink(rendered)
        }

        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard let rect = SpineCrop.cropRect(
            guide: guideRect,
            previewSize: previewSize,
            imageSize: pixelSize
        ), let cut = cgImage.cropping(to: rect) else { return nil }

        return Self.shrink(UIImage(cgImage: cut, scale: 1, orientation: .up))
    }

    /// Down to `SpineCrop.storedSize` and JPEG.
    ///
    /// A shelf draws a spine about 40pt wide, so there is nothing to see past a
    /// few hundred pixels — and a few hundred full-resolution photographs would
    /// be hundreds of megabytes of the user's storage for no visible difference.
    static func shrink(_ image: UIImage) -> Data? {
        let target = SpineCrop.storedSize(for: image.size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}

/// The live preview, with the guide punched out of a dimming layer.
struct SpineCameraPreview: UIViewRepresentable {
    let controller: SpineCameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layer.session = controller.session
        view.layer.videoGravity = .resizeAspectFill
        view.onLayout = { [weak controller] layer, bounds in
            // The guide the user sees *is* the rect the crop uses. Computing it
            // in two places is how the frame and the photo drift apart.
            controller?.guideRect = SpineCrop.guideRect(in: bounds)
            controller?.previewSize = bounds
            controller?.previewLayer = layer
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }

        var onLayout: ((AVCaptureVideoPreviewLayer, CGSize) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(layer, bounds.size)
        }
    }
}

/// The dimmed surround and the bright guide, drawn over the preview.
///
/// When a spine has been found the guide *is* the found shape — corners and all,
/// so a tilted book shows a tilted frame. That honesty matters: a rectangle drawn
/// over a slanted book would promise a crop the capture isn't going to make.
struct SpineGuideOverlay: View {
    /// The detected spine, normalised with a top-left origin. Nil falls back to
    /// the centred rectangle and manual framing.
    var detected: SpineQuad?
    /// The camera frame's aspect, so the detection lands where the preview is
    /// actually showing it — the preview is a centred crop of that frame.
    var imageAspect: Double

    var body: some View {
        GeometryReader { geo in
            let quad = detected?.inPreview(imageAspect: imageAspect, previewSize: geo.size)
            let fallback = SpineCrop.guideRect(in: geo.size)

            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .reverseMask {
                        if let quad {
                            QuadShape(quad: quad)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .frame(width: fallback.width, height: fallback.height)
                                .position(x: fallback.midX, y: fallback.midY)
                        }
                    }

                if let quad {
                    QuadShape(quad: quad)
                        .stroke(.green, lineWidth: 2.5)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: fallback.width, height: fallback.height)
                        .position(x: fallback.midX, y: fallback.midY)
                }

                Text(detected == nil
                     ? "Point at a book — or line the spine up in the frame"
                     : "Spine found")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: .capsule)
                    .position(
                        x: geo.size.width / 2,
                        // Below whichever guide is showing, clamped so it can't
                        // slide off the bottom when the spine fills the frame.
                        y: min(geo.size.height - 24, (quad?.boundingBox.maxY ?? fallback.maxY) + 26)
                    )
            }
            .animation(.easeOut(duration: 0.18), value: detected)
            .allowsHitTesting(false)
        }
    }
}

/// The detected quad, in view coordinates.
struct QuadShape: Shape {
    let quad: SpineQuad

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: quad.topLeft)
        path.addLine(to: quad.topRight)
        path.addLine(to: quad.bottomRight)
        path.addLine(to: quad.bottomLeft)
        path.closeSubpath()
        return path
    }
}

private extension View {
    /// Cuts `mask` *out* of the receiver. SwiftUI's `.mask` keeps what's inside;
    /// the dimming needs the opposite.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            ZStack {
                Rectangle()
                mask().blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}


/// The capture session, confined to one serial queue.
///
/// `@unchecked Sendable` with an invariant that is actually upheld: `session` and
/// `output` are only ever configured or started/stopped inside `queue`, which is
/// serial. Reading `session` from the main thread to hand it to the preview layer
/// is the one documented exception, and it is what AVFoundation's own sample code
/// does.
private final class SessionBox: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let video = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.enkela.bookshelf.spine-camera")
    private var configured = false

    /// Live frames, for spine detection. Called on `queue`.
    var onFrame: (@Sendable (CMSampleBuffer, CGImagePropertyOrientation) -> Void)?

    private var device: AVCaptureDevice?

    /// Keep hunting for focus instead of locking on the first thing seen.
    ///
    /// The default is a single autofocus at start-up, which locks onto whatever
    /// was in front of the lens then — usually not the book, since the user is
    /// still raising the phone. A book is also held close, so the near range
    /// restriction stops the camera hunting past it to the wall behind.
    private func configureFocus(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        // Without this the picture visibly pulses while the lens hunts, which on
        // a spine full of small text looks like the app struggling.
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        if device.isSubjectAreaChangeMonitoringEnabled == false {
            // Tells the system to re-run autofocus when the scene changes, which
            // is what makes moving to the next book refocus on its own.
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    /// Focus and expose for a point the user tapped, in normalised device
    /// coordinates.
    func focus(at point: CGPoint) {
        queue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }

            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
            // Back to hunting once it has settled, so the next book is picked up
            // without another tap.
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    var isRunning: Bool { session.isRunning }

    func startRunning() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !configured {
                    configured = true
                    session.beginConfiguration()
                    session.sessionPreset = .photo
                    if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                       let input = try? AVCaptureDeviceInput(device: device),
                       session.canAddInput(input) {
                        session.addInput(input)
                        self.device = device
                        configureFocus(device)
                    }
                    if session.canAddOutput(output) { session.addOutput(output) }
                    // Late frames are dropped rather than queued: detection only
                    // has to keep up with a hand, and a backlog would show the
                    // guide where the book *was*.
                    video.alwaysDiscardsLateVideoFrames = true
                    video.setSampleBufferDelegate(self, queue: queue)
                    if session.canAddOutput(video) { session.addOutput(video) }
                    session.commitConfiguration()
                }
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    func stopRunning() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capture(delegate: AVCapturePhotoCaptureDelegate) {
        queue.async { [self] in
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }
}


extension UIImage {
    /// The same pixels, with any EXIF rotation baked in and scale 1.
    ///
    /// After this, pixel coordinates and on-screen coordinates agree — which is
    /// what lets the crop be plain geometry instead of a guess about which
    /// coordinate space a capture API reports in.
    func normalisedUp() -> UIImage {
        guard imageOrientation != .up || scale != 1 else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}


extension SpineCameraController {
    /// Core Image is lazy; this is where the work actually happens.
    static func render(_ image: CIImage) -> UIImage? {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}


extension SessionBox: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // The buffer is landscape from the sensor while the preview is portrait,
        // so Vision is told how to read it rather than the results being rotated
        // afterwards — the correction that went wrong the first time.
        onFrame?(sampleBuffer, .right)
    }
}
