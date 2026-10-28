import SwiftUI
import UIKit

/// Piece ids match backend/src/hq.ts. Locked rows stay locked until a real perk arrives.
enum Catalog {
    struct Piece: Identifiable, Equatable {
        var id: String
        var title: String
    }

    static let colors = ["navy", "black", "white", "charcoal", "sand", "gold", "burgundy", "forest"]
    static let tops = [Piece(id: "oxford", title: "Oxford"), Piece(id: "knit", title: "Knit"), Piece(id: "tee", title: "Tee")]
    static let bottoms = [Piece(id: "trousers", title: "Trousers"), Piece(id: "chinos", title: "Chinos")]
    static let shoes = [Piece(id: "oxfords", title: "Oxfords"), Piece(id: "trainers", title: "Trainers")]
    static let jackets = [Piece(id: "none", title: "None"), Piece(id: "blazer", title: "Blazer"), Piece(id: "overcoat", title: "Overcoat")]
    static let accessories = [Piece(id: "none", title: "None"), Piece(id: "pin", title: "Lapel pin"), Piece(id: "glasses", title: "Glasses")]
    static let furnitureItems = [
        Piece(id: "none", title: "Empty"),
        Piece(id: "lamp", title: "Lamp"),
        Piece(id: "plant", title: "Plant"),
        Piece(id: "chair", title: "Chair"),
        Piece(id: "rug", title: "Rug"),
        Piece(id: "cart", title: "Bar cart"),
        Piece(id: "art", title: "Art"),
    ]
    static let slots = ["lamp", "plant", "chair", "rug", "cart", "art"]

    static func pieceLocked(_ id: String, perks: Set<String>) -> Bool {
        ["tee", "chinos", "trainers", "overcoat", "glasses"].contains(id) && !perks.contains("outfit_pack")
    }

    static func colorLocked(_ id: String, perks: Set<String>) -> Bool {
        ["gold", "burgundy", "forest"].contains(id) && !perks.contains("outfit_pack")
    }

    static func furnitureLocked(_ id: String, perks: Set<String>) -> Bool {
        if id == "cart" { return !perks.contains("outfit_pack") }
        if id == "art" { return !perks.contains("corner_office") }
        return false
    }

    static func sanitized(_ outfit: Outfit, perks: Set<String>) -> Outfit {
        var copy = outfit
        if pieceLocked(copy.top, perks: perks) { copy.top = "oxford" }
        if pieceLocked(copy.bottoms, perks: perks) { copy.bottoms = "trousers" }
        if pieceLocked(copy.shoes, perks: perks) { copy.shoes = "oxfords" }
        if pieceLocked(copy.jacket, perks: perks) { copy.jacket = "blazer" }
        if pieceLocked(copy.accessory, perks: perks) { copy.accessory = "pin" }
        if colorLocked(copy.topColor, perks: perks) { copy.topColor = "white" }
        if colorLocked(copy.bottomsColor, perks: perks) { copy.bottomsColor = "navy" }
        if colorLocked(copy.shoesColor, perks: perks) { copy.shoesColor = "black" }
        if colorLocked(copy.jacketColor, perks: perks) { copy.jacketColor = "navy" }
        return copy
    }

    static func sanitized(_ items: [FurniturePlacement], perks: Set<String>) -> [FurniturePlacement] {
        items.map { item in
            var copy = item
            if furnitureLocked(copy.item, perks: perks) { copy.item = "none" }
            if !colors.contains(copy.color) { copy.color = "navy" }
            return copy
        }
    }

    static func uiColor(_ name: String) -> UIColor {
        switch name {
        case "black": return UIColor(white: 0.08, alpha: 1)
        case "white": return UIColor(white: 0.93, alpha: 1)
        case "charcoal": return UIColor(white: 0.22, alpha: 1)
        case "sand": return UIColor(red: 0.76, green: 0.67, blue: 0.52, alpha: 1)
        case "gold": return UIColor(red: 0.83, green: 0.66, blue: 0.28, alpha: 1)
        case "burgundy": return UIColor(red: 0.45, green: 0.10, blue: 0.16, alpha: 1)
        case "forest": return UIColor(red: 0.10, green: 0.32, blue: 0.22, alpha: 1)
        default: return UIColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1)
        }
    }

    static func color(_ name: String) -> Color {
        Color(uiColor: uiColor(name))
    }
}

struct Outfit: Codable, Equatable {
    var name: String
    var top: String
    var bottoms: String
    var shoes: String
    var jacket: String
    var accessory: String
    var topColor: String
    var bottomsColor: String
    var shoesColor: String
    var jacketColor: String

    static let starter = Outfit(
        name: "HQ",
        top: "oxford",
        bottoms: "trousers",
        shoes: "oxfords",
        jacket: "blazer",
        accessory: "pin",
        topColor: "white",
        bottomsColor: "navy",
        shoesColor: "black",
        jacketColor: "navy"
    )
}

struct FurniturePlacement: Codable, Equatable, Identifiable {
    var slot: String
    var item: String
    var color: String
    var id: String { slot }

    static let starter: [FurniturePlacement] = [
        FurniturePlacement(slot: "lamp", item: "lamp", color: "sand"),
        FurniturePlacement(slot: "plant", item: "plant", color: "forest"),
        FurniturePlacement(slot: "chair", item: "chair", color: "navy"),
        FurniturePlacement(slot: "rug", item: "rug", color: "navy"),
        FurniturePlacement(slot: "cart", item: "none", color: "gold"),
        FurniturePlacement(slot: "art", item: "none", color: "gold"),
    ]
}

struct HQBot: Identifiable, Equatable {
    var id: String
    var name: String
    var role: String
    var idle: String
    var tint: UIColor

    static let roster: [HQBot] = [
        HQBot(id: "jarvis", name: "J.A.R.V.I.S.", role: "Coordination", idle: "COORDINATION\nStanding by.", tint: UIColor(red: 0.29, green: 0.66, blue: 0.93, alpha: 1)),
        HQBot(id: "friday", name: "F.R.I.D.A.Y.", role: "Websites and design", idle: "WEB / DESIGN\nStanding by.", tint: UIColor(red: 0.86, green: 0.68, blue: 0.29, alpha: 1)),
        HQBot(id: "ultron", name: "U.L.T.R.O.N.", role: "Pitches and outreach drafts", idle: "PITCHES\nStanding by.", tint: UIColor(red: 0.90, green: 0.24, blue: 0.28, alpha: 1)),
        HQBot(id: "edith", name: "E.D.I.T.H.", role: "Research", idle: "RESEARCH\nStanding by.", tint: UIColor(red: 0.25, green: 0.82, blue: 0.48, alpha: 1)),
    ]

    static func find(_ id: String) -> HQBot {
        roster.first { $0.id == id } ?? roster[0]
    }
}

struct WorldPrompt: Equatable {
    var title: String
    var detail: String
    var action: Action

    enum Action: Equatable {
        case talk(String)
        case wardrobe
        case none
    }
}

struct HQDaily: Codable, Equatable {
    var id: String
    var title: String
    var kind: String
    var target: Int
    var progress: Int
    var done: Bool
}

struct HQEvent: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var source: String
    var summary: String
    var xp: Int
    var bot: String?
    var createdAt: String
}

struct HQRemoteState: Codable, Equatable {
    var playerName: String
    var activeLook: Outfit
    var looks: [Outfit]
    var furniture: [FurniturePlacement]
    var updatedAt: String?
}

struct HQProgress: Codable, Equatable {
    var xp: Int
    var level: Int
    var xpIntoLevel: Int
    var xpToNext: Int
    var perks: [String]
    var daily: HQDaily
    var events: [HQEvent]
    var state: HQRemoteState?

    static let waiting = HQProgress(
        xp: 0,
        level: 1,
        xpIntoLevel: 0,
        xpToNext: 800,
        perks: [],
        daily: HQDaily(id: "", title: "Waiting for JARVIS", kind: "", target: 1, progress: 0, done: false),
        events: [],
        state: nil
    )
}

struct ChatLine: Identifiable, Equatable {
    var id = UUID()
    var bot: String
    var role: Role
    var text: String
    var needsApproval = false

    enum Role: Equatable {
        case player
        case bot
        case system
    }
}

struct TalkRequest: Equatable {
    var bot: String
    var mic: Bool
}

enum HQTheme {
    static let navy = Color(red: 0.03, green: 0.05, blue: 0.10)
    static let gold = Color(red: 0.86, green: 0.68, blue: 0.29)
    static let ink = Color(red: 0.94, green: 0.91, blue: 0.84)
    static let panel = Color.black.opacity(0.72)
}
