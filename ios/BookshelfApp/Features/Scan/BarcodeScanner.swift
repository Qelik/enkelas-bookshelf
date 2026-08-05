import AVFoundation
import BookshelfCore
import SwiftUI
import Vision
import VisionKit

/// The camera half of scanning a book.
///
/// `DataScannerViewController` rather than a hand-rolled `AVCaptureSession`: it
/// brings the live highlighting, tap-to-focus and guidance text that make a
/// scanner feel like the system's, and it is a fraction of the code. The cost is
/// that it needs real hardware — see `BarcodeScanner.availability`.
///
/// Only EAN-13, EAN-8 and UPC-E are requested. A book's barcode is an EAN-13, and
/// asking for QR codes as well would have the scanner lock onto the wifi sticker
/// on the back of a router instead.
struct BarcodeScanner: UIViewControllerRepresentable {

    /// Called with each candidate the camera reads. Already filtered to something
    /// that passes `ISBN.normalize`, so the caller never sees a cereal box.
    var onISBN: (String) -> Void

    static let symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .upce]

    /// Why scanning can't start, or nil when it can.
    enum Unavailable {
        case unsupportedDevice
        case cameraDenied
        case cameraRestricted

        var message: String {
            switch self {
            case .unsupportedDevice:
                "This device can't scan barcodes. You can type the ISBN instead."
            case .cameraDenied:
                "Bookshelf doesn't have camera access. Turn it on in Settings › Bookshelf, or type the ISBN instead."
            case .cameraRestricted:
                "Camera access is restricted on this device. You can type the ISBN instead."
            }
        }
    }

    /// Checked before presenting rather than after, so the sheet can open
    /// straight onto manual entry instead of flashing an empty camera view.
    ///
    /// `isSupported` is false on the Simulator — there is no camera — so the
    /// manual path is the *only* one testable there, and it has to be good.
    static func availability() -> Unavailable? {
        guard DataScannerViewController.isSupported else { return .unsupportedDevice }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied: return .cameraDenied
        case .restricted: return .cameraRestricted
        default: break
        }
        // `isAvailable` also covers "camera in use by another app" and Screen
        // Time limits, which `authorizationStatus` doesn't report.
        return DataScannerViewController.isAvailable ? nil : .unsupportedDevice
    }

    static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onISBN: onISBN) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: Self.symbologies)],
            // A book barcode is one code held still, not a page of them.
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onISBN = onISBN
        // `try?`: starting twice is harmless and throwing here would take down a
        // view that is already on screen.
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        // The camera must be released when the sheet closes, or it stays warm and
        // the indicator light stays on.
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onISBN: (String) -> Void
        /// Barcodes stream in many times a second while the code is in frame.
        /// Without this the caller would fire a lookup per frame.
        private var reported: Set<String> = []

        init(onISBN: @escaping (String) -> Void) {
            self.onISBN = onISBN
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(addedItems)
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            // Also on update: a code that was blurry when it first appeared often
            // resolves a frame or two later, and only the update carries it.
            handle(updatedItems)
        }

        private func handle(_ items: [RecognizedItem]) {
            for item in items {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      // The check digit does the work here: it rejects a misread
                      // before it can become a wrong book.
                      let isbn = ISBN.normalize(payload),
                      reported.insert(isbn).inserted
                else { continue }
                onISBN(isbn)
            }
        }
    }
}
