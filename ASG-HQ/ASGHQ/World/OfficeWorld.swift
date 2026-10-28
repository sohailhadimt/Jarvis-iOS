import SceneKit
import UIKit

/// Procedural night office. Geometry is SceneKit primitives only. See ASG-HQ/LICENSES.md.
final class OfficeWorld: NSObject {
    let scene = SCNScene()
    let camera = SCNNode()
    let player = SCNNode()
    var onTalk: ((String) -> Void)?

    private let lookTarget = SCNNode()
    private let body = SCNNode()
    private let torsoNode = SCNNode()
    private let jacketNode = SCNNode()
    private let legsNode = SCNNode()
    private let shoesNode = SCNNode()
    private let armsNode = SCNNode()
    private let collarNode = SCNNode()
    private let pinNode = SCNNode()
    private let glassesNode = SCNNode()
    private let cornerDoor = SCNNode()
    private let liftDoor = SCNNode()
    private let furnitureRoot = SCNNode()
    private var holoMaterials: [String: SCNMaterial] = [:]

    private let lock = NSLock()
    private var x: Float = 0
    private var z: Float = 4.2
    private var yaw: Float = 0
    private var onRoof = false
    private var cooldown: Float = 0
    private var destination: SIMD2<Float>?
    private var joystick = SIMD2<Float>(repeating: 0)
    private var paused = false
    private var cornerOpen = false
    private var roofOpen = false
    private var accessDirty = false
    private var pendingOutfit: Outfit?
    private var pendingFurniture: [FurniturePlacement]?
    private var pendingHolos: [String: UIImage] = [:]
    private var publishedPrompt: WorldPrompt?
    private var publishedZone = "office"
    private var groundBlockers: [AABB] = []
    private var roofBlockers: [AABB] = []
    private var lastTime: TimeInterval = 0
    private var bob: Float = 0
    private var camX: Float = 0
    private var camY: Float = 3.05
    private var camZ: Float = 10.5

    override init() {
        super.init()
        scene.background.contents = UIColor(red: 0.015, green: 0.02, blue: 0.05, alpha: 1)
        scene.fogColor = UIColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1)
        scene.fogStartDistance = 24
        scene.fogEndDistance = 42
        buildScene()
        groundBlockers = Self.ground(cornerOpen: false, roofOpen: false)
        roofBlockers = Self.roof()
        resetCamera(x: 0, z: 4.2, yaw: 0)
    }

    func installAccess(corner: Bool, roof: Bool) {
        cornerOpen = corner
        roofOpen = roof
        groundBlockers = Self.ground(cornerOpen: corner, roofOpen: roof)
        cornerDoor.isHidden = corner
        liftDoor.isHidden = roof
        accessDirty = false
    }

    func setAccess(corner: Bool, roof: Bool) {
        lock.lock()
        if corner != cornerOpen || roof != roofOpen {
            cornerOpen = corner
            roofOpen = roof
            accessDirty = true
        }
        lock.unlock()
    }

    func apply(outfit: Outfit) {
        paint(outfit)
    }

    func enqueue(outfit: Outfit) {
        lock.lock()
        pendingOutfit = outfit
        lock.unlock()
    }

    func apply(furniture: [FurniturePlacement]) {
        place(furniture)
    }

    func enqueue(furniture: [FurniturePlacement]) {
        lock.lock()
        pendingFurniture = furniture
        lock.unlock()
    }

    func setHologram(bot: String, text: String) {
        let profile = HQBot.find(bot)
        let image = SceneArt.hologram(title: profile.name, body: text, tint: profile.tint)
        lock.lock()
        pendingHolos[bot] = image
        lock.unlock()
    }

    func setJoystick(x: Float, y: Float) {
        lock.lock()
        joystick = SIMD2(x, y)
        if x * x + y * y > 0.02 { destination = nil }
        lock.unlock()
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        if value { destination = nil }
        lock.unlock()
    }

    func closestBot() -> String {
        lock.lock()
        let px = x
        let pz = z
        let roof = onRoof
        lock.unlock()
        if roof { return "jarvis" }
        let bots: [(String, Float, Float)] = [
            ("jarvis", -6.6, -2.15), ("friday", -2.2, -2.15),
            ("ultron", 2.2, -2.15), ("edith", 6.6, -2.15),
        ]
        var best = "jarvis"
        var bestDistance = Float.greatestFiniteMagnitude
        for bot in bots {
            let distance = (px - bot.1) * (px - bot.1) + (pz - bot.2) * (pz - bot.2)
            if distance < bestDistance {
                bestDistance = distance
                best = bot.0
            }
        }
        return bestDistance > 36 ? "jarvis" : best
    }

    func chrome() -> (WorldPrompt?, String) {
        lock.lock()
        defer { lock.unlock() }
        return (publishedPrompt, publishedZone)
    }

    func handleTap(in view: SCNView, at point: CGPoint) {
        lock.lock()
        let isPaused = paused
        let px = x
        let pz = z
        lock.unlock()
        guard !isPaused else { return }
        let hits = view.hitTest(point, options: [
            SCNHitTestOption.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue),
            SCNHitTestOption.boundingBoxOnly: true,
        ])
        for hit in hits {
            let name = lineageName(hit.node)
            if name.hasPrefix("npc.") || name.hasPrefix("holo.") {
                let bot = String(name.split(separator: ".").last ?? "jarvis")
                let spot = botPoint(bot)
                let dx = px - spot.0
                let dz = pz - spot.1
                if dx * dx + dz * dz < 1.9 * 1.9 {
                    onTalk?(bot)
                } else {
                    setDestination(spot.0, spot.1)
                }
                return
            }
        }
        guard let floor = hits.first(where: { lineageName($0.node) == "walk" }) else { return }
        setDestination(Float(floor.worldCoordinates.x), Float(floor.worldCoordinates.z))
    }

    func tick(time: TimeInterval) {
        let dt: Float
        if lastTime == 0 {
            dt = 1 / 60
        } else {
            dt = min(0.05, max(0, Float(time - lastTime)))
        }
        lastTime = time

        lock.lock()
        let stick = joystick
        var dest = destination
        let isPaused = paused
        var px = x
        var pz = z
        var facing = yaw
        var roof = onRoof
        var cool = cooldown
        let corner = cornerOpen
        let roofUnlocked = roofOpen
        let outfit = pendingOutfit
        let furniture = pendingFurniture
        let holos = pendingHolos
        let refreshAccess = accessDirty
        pendingOutfit = nil
        pendingFurniture = nil
        pendingHolos.removeAll()
        if refreshAccess { accessDirty = false }
        if stick.x * stick.x + stick.y * stick.y > 0.03 {
            destination = nil
            dest = nil
        }
        lock.unlock()

        if refreshAccess {
            groundBlockers = Self.ground(cornerOpen: corner, roofOpen: roofUnlocked)
            cornerDoor.isHidden = corner
            liftDoor.isHidden = roofUnlocked
        }
        if let outfit { paint(outfit) }
        if let furniture { place(furniture) }
        for (bot, image) in holos {
            holoMaterials[bot]?.diffuse.contents = image
            holoMaterials[bot]?.emission.contents = image
        }

        var arrived = false
        if !isPaused {
            integrate(
                dt: dt, stick: stick, dest: &dest, x: &px, z: &pz, yaw: &facing,
                roof: &roof, cool: &cool, roofOpen: roofUnlocked, arrived: &arrived
            )
        }

        let zone = zoneName(x: px, z: pz, roof: roof, cornerOpen: corner)
        let prompt = isPaused ? nil : nearestPrompt(x: px, z: pz, roof: roof, cornerOpen: corner, roofOpen: roofUnlocked)
        lock.lock()
        x = px
        z = pz
        yaw = facing
        onRoof = roof
        cooldown = cool
        if arrived { destination = nil }
        publishedPrompt = prompt
        publishedZone = zone
        lock.unlock()

        if !isPaused {
            let moving = stick.x * stick.x + stick.y * stick.y > 0.03 || dest != nil
            bob += moving ? dt * 9 : 0
            body.position.y = moving ? sin(bob) * 0.035 : 0
            player.position = SCNVector3(px, 0, pz)
            player.eulerAngles.y = facing
            let blend = 1 - exp(-4.8 * dt)
            let fx = sin(facing)
            let fz = -cos(facing)
            camX += (px - fx * 6.3 - camX) * blend
            camY += (3.05 - camY) * blend
            camZ += (pz - fz * 6.3 - camZ) * blend
            camera.position = SCNVector3(camX, camY, camZ)
            lookTarget.position = SCNVector3(px, 1.4, pz)
        }
    }

    private func setDestination(_ dx: Float, _ dz: Float) {
        lock.lock()
        destination = SIMD2(dx, dz)
        lock.unlock()
    }

    private func integrate(
        dt: Float,
        stick: SIMD2<Float>,
        dest: inout SIMD2<Float>?,
        x: inout Float,
        z: inout Float,
        yaw: inout Float,
        roof: inout Bool,
        cool: inout Float,
        roofOpen: Bool,
        arrived: inout Bool
    ) {
        cool = max(0, cool - dt)
        var wish = SIMD2<Float>(0, 0)
        let speed: Float = 3.35
        if stick.x * stick.x + stick.y * stick.y > 0.03 {
            // Up walks forward. Left and right turn. Strafe is tap-to-walk.
            yaw += stick.x * 2.6 * dt
            let forward = SIMD2<Float>(sin(yaw), -cos(yaw))
            wish = forward * (stick.y * speed * dt)
        } else if var target = dest {
            let delta = target - SIMD2(x, z)
            let distance = sqrt(delta.x * delta.x + delta.y * delta.y)
            if distance < 0.2 {
                dest = nil
                arrived = true
            } else {
                wish = delta / distance * min(speed * dt, distance)
                yaw = approach(yaw, atan2(delta.x, -delta.y), dt)
            }
        }
        let blockers = roof ? roofBlockers : groundBlockers
        let distance = sqrt(wish.x * wish.x + wish.y * wish.y)
        let steps = max(1, Int(ceil(distance / 0.22)))
        let step = wish / Float(steps)
        if distance > 0 {
            for _ in 0..<steps {
                x += step.x
                for box in blockers { push(&x, &z, box) }
                z += step.y
                for box in blockers { push(&x, &z, box) }
            }
        }
        if roof {
            x = min(max(x, 41.3), 54.7)
            z = min(max(z, -5.05), 5.05)
        } else {
            x = min(max(x, -18.05), 9.4)
            z = min(max(z, -6.4), 6.4)
        }
        guard cool == 0 else { return }
        if !roof && roofOpen && x > 8.85 && abs(z) < 0.7 {
            roof = true
            x = 48
            z = 0.2
            cool = 0.9
            dest = nil
            arrived = true
        } else if roof && abs(x - 48) < 1.15 && z > 4.35 {
            roof = false
            x = 7.3
            z = 0
            cool = 0.9
            dest = nil
            arrived = true
        }
    }

    private func push(_ x: inout Float, _ z: inout Float, _ box: AABB) {
        let radius: Float = 0.36
        let closestX = min(max(x, box.minX), box.maxX)
        let closestZ = min(max(z, box.minZ), box.maxZ)
        let dx = x - closestX
        let dz = z - closestZ
        let distanceSquared = dx * dx + dz * dz
        if distanceSquared >= radius * radius { return }
        if distanceSquared < 1e-6 {
            let left = x - box.minX
            let right = box.maxX - x
            let down = z - box.minZ
            let up = box.maxZ - z
            let nearest = min(left, right, down, up)
            if nearest == left { x = box.minX - radius }
            else if nearest == right { x = box.maxX + radius }
            else if nearest == down { z = box.minZ - radius }
            else { z = box.maxZ + radius }
            return
        }
        let distance = sqrt(distanceSquared)
        let scale = (radius - distance) / distance
        x += dx * scale
        z += dz * scale
    }

    private func approach(_ current: Float, _ target: Float, _ dt: Float) -> Float {
        var delta = target - current
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return current + delta * (1 - exp(-12 * dt))
    }

    private func zoneName(x: Float, z: Float, roof: Bool, cornerOpen: Bool) -> String {
        if roof { return "rooftop" }
        if x < -10.1 { return "apartment" }
        if cornerOpen && x > 5.8 && z > 3.25 && x < 9.4 && z < 6.4 { return "corner" }
        return "office"
    }

    private func nearestPrompt(x: Float, z: Float, roof: Bool, cornerOpen: Bool, roofOpen: Bool) -> WorldPrompt? {
        if roof { return nil }
        var spots: [(Float, Float, Float, WorldPrompt)] = [
            (-6.6, -2.15, 1.9, WorldPrompt(title: "Talk", detail: "J.A.R.V.I.S.", action: .talk("jarvis"))),
            (-2.2, -2.15, 1.9, WorldPrompt(title: "Talk", detail: "F.R.I.D.A.Y.", action: .talk("friday"))),
            (2.2, -2.15, 1.9, WorldPrompt(title: "Talk", detail: "U.L.T.R.O.N.", action: .talk("ultron"))),
            (6.6, -2.15, 1.9, WorldPrompt(title: "Talk", detail: "E.D.I.T.H.", action: .talk("edith"))),
            (-16.4, 3.9, 1.6, WorldPrompt(title: "Wardrobe", detail: "Mix a look", action: .wardrobe)),
            (-12.3, 3.9, 1.6, WorldPrompt(title: "Mirror", detail: "Outfit station", action: .wardrobe)),
        ]
        if !cornerOpen {
            spots.append((7.7, 2.35, 1.7, WorldPrompt(title: "Locked", detail: "Corner office unlocks at level 5", action: .none)))
        }
        if !roofOpen {
            spots.append((8.2, 0, 1.7, WorldPrompt(title: "Locked", detail: "Rooftop terrace unlocks at level 8", action: .none)))
        }
        var best: (Float, WorldPrompt)?
        for spot in spots {
            let distance = (x - spot.0) * (x - spot.0) + (z - spot.1) * (z - spot.1)
            if distance <= spot.2 * spot.2, best == nil || distance < best!.0 {
                best = (distance, spot.3)
            }
        }
        return best?.1
    }

    private func botPoint(_ bot: String) -> (Float, Float) {
        switch bot {
        case "friday": return (-2.2, -2.15)
        case "ultron": return (2.2, -2.15)
        case "edith": return (6.6, -2.15)
        default: return (-6.6, -2.15)
        }
    }

    private func lineageName(_ node: SCNNode) -> String {
        var current: SCNNode? = node
        while let item = current {
            if let name = item.name, name == "walk" || name.contains(".") { return name }
            current = item.parent
        }
        return ""
    }

    private func resetCamera(x: Float, z: Float, yaw: Float) {
        let fx = sin(yaw)
        let fz = -cos(yaw)
        camX = x - fx * 6.3
        camY = 3.05
        camZ = z - fz * 6.3
        camera.position = SCNVector3(camX, camY, camZ)
        lookTarget.position = SCNVector3(x, 1.4, z)
    }

    private func paint(_ outfit: Outfit) {
        torsoNode.geometry?.firstMaterial?.diffuse.contents = Catalog.uiColor(outfit.topColor)
        legsNode.geometry?.firstMaterial?.diffuse.contents = Catalog.uiColor(outfit.bottomsColor)
        shoesNode.geometry?.firstMaterial?.diffuse.contents = Catalog.uiColor(outfit.shoesColor)
        jacketNode.geometry?.firstMaterial?.diffuse.contents = Catalog.uiColor(outfit.jacketColor)
        jacketNode.isHidden = outfit.jacket == "none"
        let sleeve = outfit.jacket == "none" ? Catalog.uiColor(outfit.topColor) : Catalog.uiColor(outfit.jacketColor)
        armsNode.geometry?.firstMaterial?.diffuse.contents = sleeve
        collarNode.isHidden = outfit.top == "tee"
        pinNode.isHidden = outfit.accessory != "pin"
        glassesNode.isHidden = outfit.accessory != "glasses"
        shoesNode.scale = SCNVector3(1, outfit.shoes == "trainers" ? 1.35 : 1, 1)
        legsNode.scale = SCNVector3(1, outfit.bottoms == "chinos" ? 0.86 : 1, 1)
    }

    private func place(_ items: [FurniturePlacement]) {
        furnitureRoot.childNodes.forEach { $0.removeFromParentNode() }
        for piece in items where piece.item != "none" {
            furnitureRoot.addChildNode(furnitureNode(piece))
        }
    }
}

private struct AABB {
    var minX: Float
    var maxX: Float
    var minZ: Float
    var maxZ: Float
}

private struct Seed {
    var state: UInt64
    mutating func unit() -> Float {
        state = state &* 6364136223846793005 &+ 1
        return Float(state % 10_000) / 10_000
    }
}

private enum SceneArt {
    static func lambert(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = color
        material.locksAmbientWithDiffuse = true
        return material
    }

    static func emissive(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        return material
    }

    static func glass() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 0.55, green: 0.72, blue: 0.95, alpha: 1)
        material.isDoubleSided = true
        material.transparency = 0.18
        material.writesToDepthBuffer = false
        return material
    }

    static func hologram(title: String, body: String, tint: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400))
        return renderer.image { ctx in
            UIColor(red: 0.02, green: 0.04, blue: 0.08, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            tint.setStroke()
            let border = UIBezierPath(roundedRect: CGRect(x: 12, y: 12, width: 616, height: 376), cornerRadius: 24)
            border.lineWidth = 8
            border.stroke()
            let heading: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 32, weight: .bold),
                .foregroundColor: tint,
            ]
            NSString(string: title).draw(in: CGRect(x: 36, y: 28, width: 568, height: 46), withAttributes: heading)
            let copy: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor.white,
            ]
            NSString(string: String(body.prefix(320))).draw(in: CGRect(x: 36, y: 88, width: 568, height: 280), withAttributes: copy)
        }
    }

    static func sign(_ text: String) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 220))
        return renderer.image { _ in
            let style: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 132, weight: .black),
                .foregroundColor: UIColor(red: 1, green: 0.84, blue: 0.45, alpha: 1),
            ]
            let string = NSString(string: text)
            let bounds = string.boundingRect(with: CGSize(width: 1000, height: 200), options: .usesLineFragmentOrigin, attributes: style, context: nil)
            string.draw(in: CGRect(x: (1024 - bounds.width) / 2, y: (220 - bounds.height) / 2, width: bounds.width, height: bounds.height), withAttributes: style)
        }
    }

    static func windows() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 256))
        return renderer.image { ctx in
            UIColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 256))
            var rng = Seed(state: 99)
            for column in 0..<6 {
                for row in 0..<12 {
                    if rng.unit() < 0.42 { continue }
                    let gold = rng.unit() > 0.72
                    let color = gold
                        ? UIColor(red: 0.95, green: 0.75, blue: 0.35, alpha: 1)
                        : UIColor(red: 0.75, green: 0.86, blue: 1, alpha: 0.85)
                    color.setFill()
                    ctx.fill(CGRect(x: 8 + column * 20, y: 8 + row * 20, width: 10, height: 12))
                }
            }
        }
    }
}

extension OfficeWorld {
    fileprivate static func ground(cornerOpen: Bool, roofOpen: Bool) -> [AABB] {
        var boxes = [
            AABB(minX: -10.4, maxX: 10.4, minZ: -7.45, maxZ: -6.55),
            AABB(minX: -10.4, maxX: 10.4, minZ: 6.5, maxZ: 7.35),
            AABB(minX: -10.4, maxX: -9.55, minZ: -7.3, maxZ: 0.25),
            AABB(minX: -10.4, maxX: -9.55, minZ: 2.05, maxZ: 7.3),
            AABB(minX: -18.75, maxX: -18.15, minZ: -1.45, maxZ: 5.75),
            AABB(minX: -18.75, maxX: -9.55, minZ: -1.45, maxZ: -0.85),
            AABB(minX: -18.75, maxX: -9.55, minZ: 5.15, maxZ: 5.75),
            desk(-6.6, -3.5), desk(-2.2, -3.5), desk(2.2, -3.5), desk(6.6, -3.5),
            AABB(minX: -17.7, maxX: -15.1, minZ: -0.55, maxZ: 1.2),
            AABB(minX: -11.5, maxX: -11.05, minZ: 3.3, maxZ: 4.55),
            AABB(minX: 5.35, maxX: 5.75, minZ: 2.85, maxZ: 6.55),
            AABB(minX: 6.7, maxX: 8.7, minZ: 4.5, maxZ: 5.7),
        ]
        if roofOpen {
            boxes.append(AABB(minX: 9.5, maxX: 10.35, minZ: -7.3, maxZ: -0.85))
            boxes.append(AABB(minX: 9.5, maxX: 10.35, minZ: 0.85, maxZ: 7.3))
        } else {
            boxes.append(AABB(minX: 9.5, maxX: 10.35, minZ: -7.3, maxZ: 7.3))
        }
        if cornerOpen {
            boxes.append(AABB(minX: 5.35, maxX: 7.15, minZ: 2.85, maxZ: 3.2))
            boxes.append(AABB(minX: 8.35, maxX: 9.55, minZ: 2.85, maxZ: 3.2))
        } else {
            boxes.append(AABB(minX: 5.35, maxX: 9.55, minZ: 2.85, maxZ: 3.2))
        }
        return boxes
    }

    fileprivate static func roof() -> [AABB] {
        [
            AABB(minX: 40.7, maxX: 55.3, minZ: -5.75, maxZ: -5.2),
            AABB(minX: 40.7, maxX: 55.3, minZ: 5.2, maxZ: 5.75),
            AABB(minX: 40.7, maxX: 41.25, minZ: -5.75, maxZ: 5.75),
            AABB(minX: 54.75, maxX: 55.3, minZ: -5.75, maxZ: 5.75),
        ]
    }

    private static func desk(_ x: Float, _ z: Float) -> AABB {
        AABB(minX: x - 0.95, maxX: x + 0.95, minZ: z - 0.5, maxZ: z + 0.5)
    }

    fileprivate func buildScene() {
        let root = scene.rootNode
        light(.ambient, UIColor(red: 0.45, green: 0.52, blue: 0.68, alpha: 1), 520, 0, 2, 0)
        light(.omni, UIColor(red: 1, green: 0.78, blue: 0.42, alpha: 1), 780, 0, 2.8, 0.5)
        light(.omni, UIColor(red: 0.55, green: 0.7, blue: 1, alpha: 1), 560, 0, 2.2, -5.5)
        light(.omni, UIColor(red: 1, green: 0.72, blue: 0.38, alpha: 1), 280, -15, 2.3, 2)
        light(.omni, UIColor(red: 0.75, green: 0.82, blue: 1, alpha: 1), 420, 48, 3.2, 0)

        let floorMat = SceneArt.lambert(UIColor(red: 0.035, green: 0.045, blue: 0.07, alpha: 1))
        let wallMat = SceneArt.lambert(UIColor(red: 0.05, green: 0.065, blue: 0.1, alpha: 1))
        let gold = SceneArt.emissive(Catalog.uiColor("gold"))
        _ = add(root, "walk", box(20, 0.12, 14, floorMat), 0, -0.06, 0)
        _ = add(root, "walk", box(8.6, 0.12, 6.7, floorMat), -14.2, -0.06, 2.15)
        _ = add(root, "walk", box(14.2, 0.12, 10.6, SceneArt.lambert(UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1))), 48, -0.06, 0)
        _ = add(root, "", box(20.4, 0.12, 14.2, wallMat), 0, 3.28, 0)
        _ = add(root, "", box(8.8, 0.12, 6.9, wallMat), -14.2, 3.16, 2.15)

        _ = add(root, "", box(20.6, 0.8, 0.28, wallMat), 0, 0.4, -6.95)
        _ = add(root, "", box(20.6, 0.75, 0.28, wallMat), 0, 2.85, -6.95)
        for x in stride(from: Float(-8), through: 8, by: 3.2) {
            _ = add(root, "", box(0.08, 1.7, 0.1, wallMat), x - 1.4, 1.55, -6.64)
        }
        _ = add(root, "", box(20.6, 3.2, 0.28, wallMat), 0, 1.6, 6.9)
        _ = add(root, "", box(0.28, 3.2, 6.4, wallMat), -9.95, 1.6, -3.4)
        _ = add(root, "", box(0.28, 3.2, 4.6, wallMat), -9.95, 1.6, 4.55)
        _ = add(root, "", box(0.28, 3.2, 5.8, wallMat), 9.9, 1.6, -4.05)
        _ = add(root, "", box(0.28, 3.2, 5.8, wallMat), 9.9, 1.6, 4.05)
        _ = add(root, "", box(9, 3.05, 0.24, wallMat), -14.2, 1.52, -1.15)
        _ = add(root, "", box(9, 3.05, 0.24, wallMat), -14.2, 1.52, 5.45)
        _ = add(root, "", box(0.24, 3.05, 6.9, wallMat), -18.45, 1.52, 2.15)

        let glass = SceneArt.glass()
        for x in stride(from: Float(-8), through: 8, by: 3.2) {
            _ = add(root, "", plane(2.5, 1.7, glass), x, 1.55, -6.72)
        }
        _ = add(root, "", plane(4.4, 0.85, SceneArt.hologramMaterial(SceneArt.sign("ASG HQ"))), 0, 2.72, -6.68)

        _ = add(root, "", box(19.2, 0.06, 0.08, gold), 0, 0.08, -6.5)
        _ = add(root, "", box(19.2, 0.06, 0.08, gold), 0, 0.08, 6.45)
        for x in stride(from: Float(-6), through: 6, by: 4) {
            let lamp = SCNNode(geometry: tube(0.16, 0.04, gold))
            lamp.position = SCNVector3(x, 3.16, 0)
            root.addChildNode(lamp)
        }

        for bot in HQBot.roster {
            let x = deskX(bot.id)
            buildDesk(bot: bot, x: x, z: -3.5)
        }
        buildPlayer()
        buildApartment()
        buildCorner()
        buildLift()
        buildRoof()
        skyline(centerX: 0, centerZ: -16, span: 34)
        skyline(centerX: 48, centerZ: 0, span: 26)
        root.addChildNode(furnitureRoot)
        root.addChildNode(lookTarget)
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 58
        camera.camera?.zNear = 0.08
        camera.camera?.zFar = 80
        let look = SCNLookAtConstraint(target: lookTarget)
        look.isGimbalLockEnabled = true
        camera.constraints = [look]
        root.addChildNode(camera)
    }

    private func deskX(_ bot: String) -> Float {
        switch bot {
        case "friday": return -2.2
        case "ultron": return 2.2
        case "edith": return 6.6
        default: return -6.6
        }
    }

    private func buildDesk(bot: HQBot, x: Float, z: Float) {
        let root = scene.rootNode
        let wood = SceneArt.lambert(UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))
        _ = add(root, "", box(1.7, 0.08, 0.78, wood, 0.01), x, 0.74, z)
        for corner in [SIMD2<Float>(-0.72, -0.28), SIMD2(0.72, -0.28), SIMD2(-0.72, 0.28), SIMD2(0.72, 0.28)] {
            _ = add(root, "", box(0.07, 0.7, 0.07, wood), x + corner.x, 0.35, z + corner.y)
        }
        let image = SceneArt.hologram(title: bot.name, body: bot.idle, tint: bot.tint)
        let material = SceneArt.hologramMaterial(image)
        holoMaterials[bot.id] = material
        let screen = add(root, "holo.\(bot.id)", plane(1.16, 0.72, material), x, 1.28, z + 0.46)
        let pulse = SCNAction.sequence([
            SCNAction.moveBy(x: 0, y: 0.025, z: 0, duration: 1.5),
            SCNAction.moveBy(x: 0, y: -0.025, z: 0, duration: 1.5),
        ])
        screen.runAction(SCNAction.repeatForever(pulse))
        _ = add(root, "", box(1.24, 0.04, 0.04, SceneArt.emissive(bot.tint)), x, 0.9, z + 0.46)

        let person = SCNNode()
        person.name = "npc.\(bot.id)"
        person.position = SCNVector3(x, 0, z - 0.85)
        root.addChildNode(person)
        let suit = SceneArt.lambert(UIColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1))
        let skin = SceneArt.lambert(UIColor(red: 0.78, green: 0.70, blue: 0.60, alpha: 1))
        _ = add(person, "", box(0.48, 0.08, 0.46, suit), 0, 0.46, 0.1)
        _ = add(person, "", box(0.4, 0.46, 0.22, suit), 0, 0.92, 0)
        _ = add(person, "", ball(0.13, skin), 0, 1.34, 0.04)
        _ = add(person, "", ball(0.14, SceneArt.lambert(UIColor(white: 0.07, alpha: 1))), 0, 1.42, -0.02)
        _ = add(person, "", box(0.18, 0.05, 0.04, SceneArt.emissive(bot.tint)), 0, 1.08, 0.12)
    }

    private func buildPlayer() {
        player.name = "player"
        player.position = SCNVector3(0, 0, 4.2)
        scene.rootNode.addChildNode(player)
        player.addChildNode(body)
        let skin = SceneArt.lambert(UIColor(red: 0.78, green: 0.70, blue: 0.60, alpha: 1))
        torsoNode.geometry = box(0.38, 0.48, 0.2, SceneArt.lambert(UIColor.white))
        torsoNode.position = SCNVector3(0, 1.18, 0)
        jacketNode.geometry = box(0.46, 0.54, 0.26, SceneArt.lambert(Catalog.uiColor("navy")), 0.02)
        jacketNode.position = SCNVector3(0, 1.18, 0.01)
        collarNode.geometry = box(0.16, 0.08, 0.06, SceneArt.lambert(UIColor.white))
        collarNode.position = SCNVector3(0, 1.4, -0.08)
        legsNode.geometry = box(0.34, 0.56, 0.18, SceneArt.lambert(Catalog.uiColor("navy")))
        legsNode.position = SCNVector3(0, 0.58, 0)
        shoesNode.geometry = box(0.36, 0.1, 0.28, SceneArt.lambert(UIColor.black), 0.02)
        shoesNode.position = SCNVector3(0, 0.06, -0.03)
        armsNode.geometry = box(0.58, 0.12, 0.12, SceneArt.lambert(Catalog.uiColor("navy")))
        armsNode.position = SCNVector3(0, 1.28, 0)
        pinNode.geometry = ball(0.025, SceneArt.emissive(Catalog.uiColor("gold")))
        pinNode.position = SCNVector3(-0.1, 1.28, -0.14)
        glassesNode.geometry = box(0.16, 0.04, 0.02, SceneArt.emissive(UIColor(white: 0.9, alpha: 1)))
        glassesNode.position = SCNVector3(0, 1.6, -0.13)
        glassesNode.isHidden = true
        let head = SCNNode(geometry: ball(0.13, skin))
        head.position = SCNVector3(0, 1.58, 0)
        let hair = SCNNode(geometry: ball(0.14, SceneArt.lambert(UIColor(white: 0.08, alpha: 1))))
        hair.position = SCNVector3(0, 1.66, 0.04)
        let nose = SCNNode(geometry: box(0.04, 0.04, 0.04, skin))
        nose.position = SCNVector3(0, 1.56, -0.13)
        for node in [torsoNode, jacketNode, collarNode, legsNode, shoesNode, armsNode, pinNode, glassesNode, head, hair, nose] {
            body.addChildNode(node)
        }
    }

    private func buildApartment() {
        let root = scene.rootNode
        let frame = SceneArt.emissive(Catalog.uiColor("gold"))
        let cloth = SceneArt.lambert(UIColor(red: 0.1, green: 0.12, blue: 0.18, alpha: 1))
        let sheet = SceneArt.lambert(UIColor(red: 0.14, green: 0.16, blue: 0.24, alpha: 1))
        _ = add(root, "", box(2.2, 0.28, 1.45, cloth), -16.4, 0.28, 0.3)
        _ = add(root, "", box(2.05, 0.18, 1.25, sheet), -16.4, 0.48, 0.3)
        _ = add(root, "", box(0.55, 0.14, 0.32, SceneArt.lambert(UIColor.white)), -17.1, 0.62, 0.15)
        _ = add(root, "", box(0.12, 2.2, 1.5, frame), -18.15, 1.2, 3.9)
        _ = add(root, "", box(0.9, 2.2, 0.1, frame), -17.7, 1.2, 3.15)
        _ = add(root, "", box(0.9, 2.2, 0.1, frame), -17.7, 1.2, 4.65)
        let rail = SCNNode(geometry: tube(0.02, 1.1, frame))
        rail.eulerAngles.z = .pi / 2
        rail.position = SCNVector3(-17.7, 1.55, 3.9)
        root.addChildNode(rail)
        _ = add(root, "", box(0.08, 1.7, 0.7, frame), -11.25, 1.25, 3.9)
        _ = add(root, "", plane(0.5, 1.45, SceneArt.glass()), -11.18, 1.25, 3.9)
    }

    private func buildCorner() {
        let root = scene.rootNode
        let glass = SceneArt.glass()
        let frame = SceneArt.emissive(Catalog.uiColor("gold"))
        _ = add(root, "", plane(3.4, 2.2, glass), 7.55, 1.35, 3.05)
        _ = add(root, "", box(0.08, 2.3, 3.4, frame), 5.5, 1.2, 4.7)
        _ = add(root, "", box(1.6, 0.08, 0.7, SceneArt.lambert(UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1))), 7.7, 0.78, 5.1)
        let panel = SCNNode(geometry: box(1.15, 2.15, 0.08, SceneArt.lambert(UIColor(red: 0.12, green: 0.1, blue: 0.06, alpha: 1))))
        panel.position = SCNVector3(7.75, 1.1, 3.02)
        cornerDoor.addChildNode(panel)
        root.addChildNode(cornerDoor)
    }

    private func buildLift() {
        let root = scene.rootNode
        let frame = SceneArt.emissive(Catalog.uiColor("gold"))
        _ = add(root, "", box(0.08, 2.4, 0.08, frame), 9.55, 1.2, -0.85)
        _ = add(root, "", box(0.08, 2.4, 0.08, frame), 9.55, 1.2, 0.85)
        _ = add(root, "", box(0.08, 0.08, 1.7, frame), 9.55, 2.35, 0)
        let panel = SCNNode(geometry: box(0.1, 2.2, 1.55, SceneArt.lambert(UIColor(red: 0.1, green: 0.09, blue: 0.05, alpha: 1))))
        panel.position = SCNVector3(9.55, 1.15, 0)
        liftDoor.addChildNode(panel)
        root.addChildNode(liftDoor)
    }

    private func buildRoof() {
        let root = scene.rootNode
        let frame = SceneArt.emissive(Catalog.uiColor("gold"))
        let rail = SceneArt.lambert(UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1))
        _ = add(root, "", box(14.4, 0.08, 0.08, frame), 48, 0.08, -5.25)
        _ = add(root, "", box(14.4, 0.08, 0.08, frame), 48, 0.08, 5.25)
        _ = add(root, "", box(0.08, 0.9, 10.4, rail), 41.05, 0.5, 0)
        _ = add(root, "", box(0.08, 0.9, 10.4, rail), 54.95, 0.5, 0)
        _ = add(root, "", box(14, 0.9, 0.08, rail), 48, 0.5, -5.45)
        _ = add(root, "", box(14, 0.9, 0.08, rail), 48, 0.5, 5.45)
        _ = add(root, "", tube(0.18, 0.22, SceneArt.lambert(UIColor.darkGray)), 44, 0.12, -2)
        _ = add(root, "", cone(0.35, 0.7, SceneArt.lambert(Catalog.uiColor("forest"))), 44, 0.55, -2)
        _ = add(root, "", plane(2.2, 0.4, SceneArt.hologramMaterial(SceneArt.sign("ROOF"))), 48, 1.3, 4.7)
        _ = add(root, "", box(1.3, 2.2, 0.08, frame), 48, 1.15, 4.9)
    }

    private func skyline(centerX: Float, centerZ: Float, span: Float) {
        let material = SceneArt.lambert(UIColor(red: 0.025, green: 0.03, blue: 0.05, alpha: 1))
        material.emission.contents = SceneArt.windows()
        material.emission.intensity = 0.55
        var rng = Seed(state: UInt64(abs(Int(centerX) &* 13) + 11))
        for _ in 0..<16 {
            let width = 1.3 + rng.unit() * 1.8
            let depth = 1.3 + rng.unit() * 1.8
            let height = 2.8 + rng.unit() * 8
            let x = centerX + (rng.unit() - 0.5) * span
            let z = centerZ + (rng.unit() - 0.5) * span * 0.55
            if abs(x) < 13 && z > -8 && z < 10 { continue }
            if x > 39 && x < 57 && abs(z) < 8 { continue }
            _ = add(scene.rootNode, "sky", box(width, height, depth, material), x, height / 2, z)
        }
    }

    private func furnitureNode(_ piece: FurniturePlacement) -> SCNNode {
        let tint = Catalog.uiColor(piece.color)
        let group = SCNNode()
        switch piece.slot {
        case "lamp": group.position = SCNVector3(-15.2, 0, 1.5)
        case "plant": group.position = SCNVector3(-17.2, 0, 4.4)
        case "chair": group.position = SCNVector3(-14.2, 0, 3.5)
        case "rug": group.position = SCNVector3(-15.8, 0.03, 2.2)
        case "cart": group.position = SCNVector3(-13.6, 0, 0.7)
        default: group.position = SCNVector3(-18.05, 1.45, 2.2)
        }
        switch piece.item {
        case "lamp":
            let pole = SCNNode(geometry: tube(0.035, 0.9, SceneArt.lambert(UIColor.darkGray)))
            pole.position = SCNVector3(0, 0.45, 0)
            let shade = SCNNode(geometry: ball(0.12, SceneArt.emissive(tint)))
            shade.position = SCNVector3(0, 0.95, 0)
            group.addChildNode(pole)
            group.addChildNode(shade)
        case "plant":
            let pot = SCNNode(geometry: tube(0.12, 0.18, SceneArt.lambert(UIColor.darkGray)))
            pot.position = SCNVector3(0, 0.1, 0)
            let leaves = SCNNode(geometry: cone(0.24, 0.6, SceneArt.lambert(tint)))
            leaves.position = SCNVector3(0, 0.5, 0)
            group.addChildNode(pot)
            group.addChildNode(leaves)
        case "chair":
            let seat = SCNNode(geometry: box(0.42, 0.08, 0.42, SceneArt.lambert(tint)))
            seat.position = SCNVector3(0, 0.46, 0)
            let back = SCNNode(geometry: box(0.42, 0.4, 0.06, SceneArt.lambert(tint)))
            back.position = SCNVector3(0, 0.72, 0.16)
            group.addChildNode(seat)
            group.addChildNode(back)
        case "rug":
            group.addChildNode(SCNNode(geometry: box(1.8, 0.02, 1.2, SceneArt.lambert(tint))))
        case "cart":
            let top = SCNNode(geometry: box(0.7, 0.06, 0.38, SceneArt.lambert(tint)))
            top.position = SCNVector3(0, 0.62, 0)
            let lower = SCNNode(geometry: box(0.7, 0.06, 0.38, SceneArt.lambert(tint)))
            lower.position = SCNVector3(0, 0.32, 0)
            group.addChildNode(top)
            group.addChildNode(lower)
        default:
            group.addChildNode(SCNNode(geometry: box(0.05, 0.72, 0.54, SceneArt.emissive(Catalog.uiColor("gold")))))
            let canvas = SCNNode(geometry: box(0.02, 0.56, 0.4, SceneArt.emissive(tint)))
            canvas.position = SCNVector3(0.03, 0, 0)
            group.addChildNode(canvas)
        }
        return group
    }

    private func light(_ type: SCNLight.LightType, _ color: UIColor, _ intensity: CGFloat, _ x: Float, _ y: Float, _ z: Float) {
        let node = SCNNode()
        let lamp = SCNLight()
        lamp.type = type
        lamp.color = color
        lamp.intensity = intensity
        lamp.castsShadow = false
        node.light = lamp
        node.position = SCNVector3(x, y, z)
        scene.rootNode.addChildNode(node)
    }

    @discardableResult
    private func add(_ parent: SCNNode, _ name: String, _ geometry: SCNGeometry, _ x: Float, _ y: Float, _ z: Float) -> SCNNode {
        let node = SCNNode(geometry: geometry)
        if !name.isEmpty { node.name = name }
        node.position = SCNVector3(x, y, z)
        parent.addChildNode(node)
        return node
    }

    private func box(_ width: Float, _ height: Float, _ depth: Float, _ material: SCNMaterial, _ chamfer: Float = 0) -> SCNBox {
        let geometry = SCNBox(width: CGFloat(width), height: CGFloat(height), length: CGFloat(depth), chamferRadius: CGFloat(chamfer))
        geometry.materials = [material]
        return geometry
    }

    private func ball(_ radius: Float, _ material: SCNMaterial) -> SCNSphere {
        let geometry = SCNSphere(radius: CGFloat(radius))
        geometry.segmentCount = 12
        geometry.materials = [material]
        return geometry
    }

    private func tube(_ radius: Float, _ height: Float, _ material: SCNMaterial) -> SCNCylinder {
        let geometry = SCNCylinder(radius: CGFloat(radius), height: CGFloat(height))
        geometry.radialSegmentCount = 10
        geometry.materials = [material]
        return geometry
    }

    private func cone(_ radius: Float, _ height: Float, _ material: SCNMaterial) -> SCNCone {
        let geometry = SCNCone(topRadius: 0, bottomRadius: CGFloat(radius), height: CGFloat(height))
        geometry.radialSegmentCount = 8
        geometry.materials = [material]
        return geometry
    }

    private func plane(_ width: Float, _ height: Float, _ material: SCNMaterial) -> SCNPlane {
        let geometry = SCNPlane(width: CGFloat(width), height: CGFloat(height))
        geometry.materials = [material]
        return geometry
    }
}

private extension SceneArt {
    static func hologramMaterial(_ image: UIImage) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.emission.contents = image
        material.isDoubleSided = true
        return material
    }
}
