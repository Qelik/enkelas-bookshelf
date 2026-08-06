import AVFoundation
import BookshelfCore
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

    @Published var failure: String?

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

    var session: AVCaptureSession { box.session }

    func start() async {
        guard await Self.authorized() else {
            failure = "Bookshelf doesn't have camera access. Turn it on in Settings › Bookshelf."
            return
        }
        await box.startRunning()
    }

    func stop() {
        box.stopRunning()
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
struct SpineGuideOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let guide = SpineCrop.guideRect(in: geo.size)

            ZStack {
                // Everything outside the guide, dimmed — the clearest way to say
                // "this part is not being kept".
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .reverseMask {
                        RoundedRectangle(cornerRadius: 6)
                            .frame(width: guide.width, height: guide.height)
                            .position(x: guide.midX, y: guide.midY)
                    }

                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    .frame(width: guide.width, height: guide.height)
                    .position(x: guide.midX, y: guide.midY)

                Text("Line the spine up inside the frame")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: .capsule)
                    .position(x: geo.size.width / 2, y: guide.maxY + 30)
            }
            .allowsHitTesting(false)
        }
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
private final class SessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.enkela.bookshelf.spine-camera")
    private var configured = false

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
                    }
                    if session.canAddOutput(output) { session.addOutput(output) }
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
