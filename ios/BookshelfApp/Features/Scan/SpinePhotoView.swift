import AVFoundation
import BookshelfCore
import PhotosUI
import SwiftUI

/// Photograph a book's spine, so the shelf shows the real thing.
///
/// Two ways in, because the camera isn't always available — no hardware (the
/// Simulator), permission denied, or simply because the book isn't to hand and
/// there's already a photo in the library. The library path crops to the same
/// guide shape, so both produce the same kind of image.
struct SpinePhotoView: View {
    @Environment(SpinePhotos.self) private var photos
    @Environment(\.themeBackground) private var background
    @Environment(\.dismiss) private var dismiss

    let book: WireBook

    @StateObject private var camera = SpineCameraController()
    @State private var cameraReady = false
    @State private var cameraDenied = false
    @State private var picked: PhotosPickerItem?
    @State private var preview: UIImage?
    @State private var busy = false
    @State private var problem: String?

    private var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let preview {
                    confirm(preview)
                } else if cameraReady {
                    viewfinder
                } else {
                    unavailable
                }
            }
            .navigationTitle("Spine photo")
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if photos.hasPhoto(for: book.id), preview == nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Remove", role: .destructive) {
                            photos.delete(bookID: book.id)
                            dismiss()
                        }
                    }
                }
            }
            .task { await startCamera() }
            .onDisappear { camera.stop() }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task { await loadFromLibrary(item) }
            }
            .alert("Couldn't save that", isPresented: .constant(problem != nil), presenting: problem) { _ in
                Button("OK") { problem = nil }
            } message: { Text($0) }
        }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        VStack(spacing: 0) {
            ZStack {
                SpineCameraPreview(controller: camera)
                SpineGuideOverlay(detected: camera.detected, imageAspect: camera.bufferAspect)
                // Tap to focus. Autofocus is continuous, but a spine held close
                // against a busy background is exactly where it guesses wrong,
                // and there has to be a way to say "this bit".
                TapToFocus { point in
                    camera.focus(at: point, in: camera.previewLayer)
                    Haptics.pageTurn()
                }
            }
            .clipped()

            controls {
                Button {
                    Task { await take() }
                } label: {
                    // The system's shutter: a ring with a filled centre. A labelled
                    // button here would be the only place in iOS that has one.
                    // It turns green once a spine is found, so the state is
                    // readable without looking away from the book.
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 68, height: 68)
                        Circle()
                            .fill(camera.detected == nil ? Color.white : .green)
                            .frame(width: 56, height: 56)
                    }
                }
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)
                .accessibilityLabel("Take the photo")
            }
        }
    }

    @ViewBuilder
    private var unavailable: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "camera.metering.unknown")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(cameraDenied
                 ? "Bookshelf doesn't have camera access. Turn it on in Settings › Bookshelf, or choose a photo instead."
                 : "No camera on this device. Choose a photo instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if cameraDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url).font(.footnote)
            }
            Spacer()
            controls { EmptyView() }
        }
    }

    /// The bar under the viewfinder: library on the left, shutter in the middle.
    private func controls<Shutter: View>(@ViewBuilder _ shutter: () -> Shutter) -> some View {
        ZStack {
            HStack {
                PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                    Label("Choose a photo", systemImage: "photo.on.rectangle")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            shutter()
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .background(.black)
        .foregroundStyle(.white)
    }

    // MARK: - Confirm

    private func confirm(_ image: UIImage) -> some View {
        VStack(spacing: 18) {
            Spacer()
            // Shown at the size and shape it will appear on the shelf, so what's
            // being approved is the actual result rather than a full-bleed
            // version of it.
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 260)
                .clipShape(.rect(cornerRadius: 3))
                .shadow(radius: 6, y: 3)
            Text("This is how \(book.title) will sit on the shelf.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            HStack(spacing: 14) {
                Button("Retake") { preview = nil; picked = nil }
                    .buttonStyle(.bordered)
                Button("Use this photo") { save(image) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 28)
        }
    }

    // MARK: - Actions

    private func startCamera() async {
        guard hasCamera else { return }
        guard await SpineCameraController.authorized() else {
            cameraDenied = true
            return
        }
        await camera.start()
        cameraReady = camera.failure == nil
        if let failure = camera.failure { problem = failure }
    }

    private func take() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await camera.capture()
            guard let image = UIImage(data: data) else { throw SpineCameraController.CaptureError.noImage }
            Haptics.saved()
            preview = image
        } catch {
            problem = error.localizedDescription
        }
    }

    /// A library photo gets the same treatment as a captured one: cropped to the
    /// spine shape and shrunk, so the shelf is consistent whichever way it came.
    private func loadFromLibrary(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else {
            problem = "Couldn't read that photo."
            return
        }
        preview = await Task.detached(priority: .userInitiated) {
            SpinePhotoView.centreCrop(image)
        }.value
    }

    /// Centre-crop to the spine aspect. The picker has no guide to honour, so the
    /// middle is the only defensible choice — and the confirm step shows the
    /// result before it's kept.
    nonisolated static func centreCrop(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        var width = size.height * SpineCrop.aspect
        var height = size.height
        if width > size.width {
            width = size.width
            height = width / SpineCrop.aspect
        }
        let rect = CGRect(
            x: ((size.width - width) / 2).rounded(.down),
            y: ((size.height - height) / 2).rounded(.down),
            width: width.rounded(.down),
            height: height.rounded(.down)
        )
        guard let cut = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cut, scale: 1, orientation: image.imageOrientation)
    }

    private func save(_ image: UIImage) {
        guard let data = SpineCameraController.shrink(image) else {
            problem = "Couldn't prepare that photo."
            return
        }
        photos.save(data, for: book.id)
        Haptics.unlocked()
        dismiss()
    }
}


/// A transparent layer that reports where it was tapped.
///
/// `onTapGesture` gives no location in the view's own coordinates before iOS 18,
/// and the focus conversion needs exactly that — so the tap is read from a
/// gesture with a coordinate space instead of guessed at.
private struct TapToFocus: View {
    var onTap: (CGPoint) -> Void

    @State private var ring: CGPoint?

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let point = value.location
                            guard geo.frame(in: .local).contains(point) else { return }
                            onTap(point)
                            withAnimation(.easeOut(duration: 0.15)) { ring = point }
                            // The confirmation fades on its own; a marker that
                            // stayed would look like a permanent focus lock.
                            Task {
                                try? await Task.sleep(for: .seconds(0.9))
                                withAnimation(.easeOut(duration: 0.25)) { ring = nil }
                            }
                        }
                )
                .overlay {
                    if let ring {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.yellow, lineWidth: 1.5)
                            .frame(width: 64, height: 64)
                            .position(ring)
                            .transition(.opacity)
                    }
                }
        }
    }
}
