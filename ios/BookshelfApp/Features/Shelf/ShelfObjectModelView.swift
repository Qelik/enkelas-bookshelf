import BookshelfCore
import SceneKit
import SwiftUI

/// A shelf object rendered as an actual 3D model.
///
/// **SceneKit rather than RealityKit.** `Model3D` and `RealityView` are the
/// modern answer and would be less code, but both are iOS 18 and this app
/// deploys to 17 — using them would mean either dropping a year of devices or
/// carrying two renderers. SceneKit loads the same `.usdz` files, runs
/// everywhere the app does, and gives direct control of the lights, which
/// matters here: the model has to be lit from the upper left like everything
/// else on the shelf or it reads as pasted in from somewhere else.
///
/// **Every object falls back to its drawing.** A kind with no model file renders
/// exactly as before, so models can land one at a time and the shelf is never
/// half-broken waiting for the set to be finished.
struct ShelfObjectModelView: UIViewRepresentable {
    let modelName: String
    /// Applied to the model's own materials, so one model can be a jade plant
    /// or a red-leafed one — the same trick the drawings use.
    let tint: Double
    let size: CGSize

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        // The shelf shows through: the case, the plank and the books behind are
        // all drawn by SwiftUI, and an opaque box would punch a hole in them.
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling2X
        // Nothing animates, so there is no reason to hold a display link at
        // 60 fps behind every ornament on the shelf.
        view.rendersContinuously = false
        view.isUserInteractionEnabled = false
        view.scene = Self.scene(named: modelName, tint: tint)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // Recolouring is the only thing that changes; rebuilding the scene for
        // it would reload the model from disk on every slider tick.
        view.scene?.rootNode.childNode(withName: Self.modelRoot, recursively: true)
            .map { Self.apply(tint: tint, to: $0) }
    }

    // MARK: - Scene

    private static let modelRoot = "shelf-object"

    /// Whether a model exists for this name. Drives the fallback.
    static func hasModel(_ name: String) -> Bool { url(for: name) != nil }

    private static func url(for name: String) -> URL? {
        // `.usdz` is what a modelling tool exports; `.usda` is the text form,
        // which is what a hand-written placeholder is. SceneKit reads both.
        for ext in ["usdz", "usda", "usdc", "scn"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Models")
                ?? Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private static func scene(named name: String, tint: Double) -> SCNScene? {
        guard let url = url(for: name), let loaded = try? SCNScene(url: url) else { return nil }

        let scene = SCNScene()
        let model = SCNNode()
        model.name = modelRoot
        for child in loaded.rootNode.childNodes { model.addChildNode(child) }

        // Models arrive at wildly different scales — a metre-tall statue and a
        // centimetre-tall trinket are both "1 unit" depending on the exporter.
        // Normalising to a known height is what makes an arbitrary download sit
        // correctly on the shelf instead of filling the screen or vanishing.
        let (minB, maxB) = model.boundingBox
        let height = Float(maxB.y - minB.y)
        if height > 0 {
            let target: Float = 1.0
            model.scale = SCNVector3(target / height, target / height, target / height)
        }
        // Sat on the floor of the scene rather than centred on the origin, so it
        // stands on the plank rather than sinking through it.
        let scaled = model.scale.y
        model.position = SCNVector3(
            -Float(minB.x + maxB.x) / 2 * scaled,
            -Float(minB.y) * scaled,
            -Float(minB.z + maxB.z) / 2 * scaled
        )
        apply(tint: tint, to: model)
        scene.rootNode.addChildNode(model)

        scene.rootNode.addChildNode(camera())
        for light in lights() { scene.rootNode.addChildNode(light) }
        return scene
    }

    private static func camera() -> SCNNode {
        let node = SCNNode()
        let camera = SCNCamera()
        // Orthographic, not perspective: an ornament 40 points wide seen through
        // a perspective lens gets keystone distortion that reads as a wonky
        // object rather than as depth.
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 0.62
        camera.zNear = 0.01
        camera.zFar = 100
        node.camera = camera
        // Very slightly above eye level, the way you look at a shelf.
        node.position = SCNVector3(0, 0.5, 3)
        node.eulerAngles = SCNVector3(-0.06, 0, 0)
        return node
    }

    private static func lights() -> [SCNNode] {
        // Upper left, matching the drawn spines and the drawn objects. Three
        // lights, because one makes everything look like a product photo on a
        // white background and the shelf is a dark wooden box.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 4
        key.light?.shadowColor = UIColor.black.withAlphaComponent(0.45)
        key.position = SCNVector3(-2, 3, 2)
        key.look(at: SCNVector3(0, 0.4, 0))

        // Fill from the right, weak and cool, so the shadow side isn't dead.
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 260
        fill.light?.color = UIColor(red: 0.75, green: 0.8, blue: 1, alpha: 1)
        fill.position = SCNVector3(3, 1, 2)
        fill.look(at: SCNVector3(0, 0.4, 0))

        // Warm bounce off the plank below.
        let bounce = SCNNode()
        bounce.light = SCNLight()
        bounce.light?.type = .ambient
        bounce.light?.intensity = 220
        bounce.light?.color = UIColor(red: 1, green: 0.86, blue: 0.7, alpha: 1)

        return [key, fill, bounce]
    }

    /// Push the object's hue through the model's materials.
    ///
    /// Multiplied rather than replaced: a model's own texture and shading stay,
    /// and the hue shifts it — replacing the diffuse would flatten a detailed
    /// model back into the silhouette this feature is trying to get away from.
    private static func apply(tint: Double, to node: SCNNode) {
        // Weak on purpose. A multiply at the saturation the *drawings* use
        // repaints a sculpted model in flat colour and throws away the thing it
        // was brought in for. At this strength it reads as the material being a
        // warmer or cooler stone, which is what a tint should do to something
        // already shaded.
        let colour = UIColor(hue: CGFloat(tint) / 360, saturation: 0.20, brightness: 1, alpha: 1)
        node.enumerateHierarchy { child, _ in
            for material in child.geometry?.materials ?? [] {
                material.multiply.contents = colour
                material.lightingModel = .physicallyBased
            }
        }
    }
}
