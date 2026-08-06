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
/// The guide and the crop are driven from the *same* rect. The preview is
/// `resizeAspectFill`, so what's on screen is already a crop of the sensor
/// frame — cropping the photo to the guide's screen coordinates would take a
/// different region than the one framed. `metadataOutputRectConverted` is what
/// bridges the two, and it's the reason this isn't a few lines in a view.
@MainActor
final class SpineCameraController: NSObject, ObservableObject {


    /// Set by the preview layer once it exists — the conversion needs the live
    /// layer's geometry, not a remembered copy of it.
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    /// The guide, in the preview's coordinates. Written by the view on layout.
    var guideRect: CGRect = .zero

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
    func crop(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        // The preview knows how its own gravity maps screen space onto the sensor
        // frame. Doing this by hand is where the region silently drifts.
        let normalised = previewLayer.map {
            $0.metadataOutputRectConverted(fromLayerRect: guideRect)
        } ?? CGRect(x: 0, y: 0, width: 1, height: 1)

        // `metadataOutputRect` is in the *unrotated* sensor space, so it has to be
        // turned to match how the photo itself is oriented before it can index
        // pixels. For a portrait capture the axes swap.
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let oriented: CGRect = switch image.imageOrientation {
        case .right, .rightMirrored, .left, .leftMirrored:
            CGRect(x: normalised.origin.y, y: normalised.origin.x,
                   width: normalised.height, height: normalised.width)
        default:
            normalised
        }

        guard let rect = SpineCrop.pixelRect(from: oriented, imageSize: pixelSize),
              let cut = cgImage.cropping(to: rect)
        else { return nil }

        let cropped = UIImage(cgImage: cut, scale: 1, orientation: image.imageOrientation)
        return Self.shrink(cropped)
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
            controller?.previewLayer = layer
            // The guide the user sees *is* the rect the crop uses. Computing it
            // in two places is how the frame and the photo drift apart.
            controller?.guideRect = SpineCrop.guideRect(in: bounds)
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
