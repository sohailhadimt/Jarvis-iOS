import SwiftUI

struct WardrobePanel: View {
    @ObservedObject var session: HQSession
    @State private var section = 0
    @State private var lookName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wardrobe").font(.title3.weight(.bold)).foregroundStyle(HQTheme.gold)
                Spacer()
                Button("Close") { session.closeWardrobe() }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HQTheme.gold)
            }
            HStack(spacing: 16) {
                Mannequin(outfit: session.look)
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.look.name).font(.headline).foregroundStyle(HQTheme.ink)
                    Text(session.zoneName == "apartment" ? "Apartment" : "Wearing this in HQ")
                        .font(.caption)
                        .foregroundStyle(HQTheme.ink.opacity(0.7))
                }
                Spacer()
            }
            Picker("Section", selection: $section) {
                Text("Outfit").tag(0)
                Text("Room").tag(1)
            }
            .pickerStyle(.segmented)
            if section == 0 {
                outfitEditor
            } else {
                roomEditor
            }
        }
        .padding(16)
        .frame(width: 460)
        .frame(maxHeight: .infinity)
        .background(HQTheme.panel)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(HQTheme.gold), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var outfitEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pieceRow("Top", pieces: Catalog.tops, selected: session.look.top) { id in
                    var copy = session.look
                    copy.top = id
                    session.preview(outfit: copy)
                }
                pieceRow("Bottoms", pieces: Catalog.bottoms, selected: session.look.bottoms) { id in
                    var copy = session.look
                    copy.bottoms = id
                    session.preview(outfit: copy)
                }
                pieceRow("Shoes", pieces: Catalog.shoes, selected: session.look.shoes) { id in
                    var copy = session.look
                    copy.shoes = id
                    session.preview(outfit: copy)
                }
                pieceRow("Jacket", pieces: Catalog.jackets, selected: session.look.jacket) { id in
                    var copy = session.look
                    copy.jacket = id
                    session.preview(outfit: copy)
                }
                pieceRow("Accessory", pieces: Catalog.accessories, selected: session.look.accessory) { id in
                    var copy = session.look
                    copy.accessory = id
                    session.preview(outfit: copy)
                }
                Text("Colours").font(.caption.weight(.bold)).foregroundStyle(HQTheme.gold)
                colorRow("Top", selected: session.look.topColor, cloth: true) { color in
                    var copy = session.look
                    copy.topColor = color
                    session.preview(outfit: copy)
                }
                colorRow("Bottoms", selected: session.look.bottomsColor, cloth: true) { color in
                    var copy = session.look
                    copy.bottomsColor = color
                    session.preview(outfit: copy)
                }
                colorRow("Shoes", selected: session.look.shoesColor, cloth: true) { color in
                    var copy = session.look
                    copy.shoesColor = color
                    session.preview(outfit: copy)
                }
                colorRow("Jacket", selected: session.look.jacketColor, cloth: true) { color in
                    var copy = session.look
                    copy.jacketColor = color
                    session.preview(outfit: copy)
                }
                HStack {
                    TextField("Name this look", text: $lookName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { session.saveNamedLook(lookName); lookName = "" }
                        .buttonStyle(GoldButtonStyle())
                        .disabled(lookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(session.looks, id: \.name) { saved in
                    HStack {
                        Button(saved.name) { session.wear(saved) }
                            .foregroundStyle(HQTheme.ink)
                        Spacer()
                        Button("Remove") { session.deleteLook(saved) }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(HQTheme.gold)
                    }
                }
            }
        }
    }

    private var roomEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Place and recolour a few pieces in the apartment. Locked pieces open with real perks.")
                    .font(.caption)
                    .foregroundStyle(HQTheme.ink.opacity(0.75))
                ForEach(session.furniture) { piece in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(piece.slot.capitalized).font(.caption.weight(.bold)).foregroundStyle(HQTheme.gold)
                        pieceRow(piece.slot, pieces: Catalog.furnitureItems, selected: piece.item, furniture: true) { id in
                            var items = session.furniture
                            if let index = items.firstIndex(where: { $0.slot == piece.slot }) {
                                items[index].item = id
                                session.preview(furniture: items)
                            }
                        }
                        colorRow(piece.slot, selected: piece.color, cloth: false) { color in
                            var items = session.furniture
                            if let index = items.firstIndex(where: { $0.slot == piece.slot }) {
                                items[index].color = color
                                session.preview(furniture: items)
                            }
                        }
                    }
                }
            }
        }
    }

    private func pieceRow(_ title: String, pieces: [Catalog.Piece], selected: String, furniture: Bool = false, choose: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !furniture {
                Text(title).font(.caption.weight(.bold)).foregroundStyle(HQTheme.gold)
            }
            HStack(spacing: 8) {
                ForEach(pieces) { piece in
                    let locked = furniture
                        ? Catalog.furnitureLocked(piece.id, perks: session.perkSet)
                        : Catalog.pieceLocked(piece.id, perks: session.perkSet)
                    Button {
                        if !locked { choose(piece.id) }
                    } label: {
                        HStack(spacing: 4) {
                            if locked { Image(systemName: "lock.fill").font(.caption2) }
                            Text(piece.title).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(selected == piece.id ? Color.black : HQTheme.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(selected == piece.id ? HQTheme.gold : Color.white.opacity(0.08)))
                    }
                    .disabled(locked)
                }
            }
        }
    }

    private func colorRow(_ title: String, selected: String, cloth: Bool, choose: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(Catalog.colors, id: \.self) { color in
                let locked = cloth && Catalog.colorLocked(color, perks: session.perkSet)
                Button {
                    if !locked { choose(color) }
                } label: {
                    ZStack {
                        Circle().fill(Catalog.color(color)).frame(width: 22, height: 22)
                        if selected == color {
                            Circle().stroke(Color.white, lineWidth: 2).frame(width: 26, height: 26)
                        }
                        if locked {
                            Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.white)
                        }
                    }
                }
                .disabled(locked)
                .accessibilityLabel(color)
            }
        }
    }
}

private struct Mannequin: View {
    var outfit: Outfit

    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(Color(red: 0.78, green: 0.70, blue: 0.60)).frame(width: 28, height: 28)
            RoundedRectangle(cornerRadius: 4)
                .fill(Catalog.color(outfit.jacket == "none" ? outfit.topColor : outfit.jacketColor))
                .frame(width: 46, height: 40)
                .overlay(alignment: .top) {
                    if outfit.accessory == "pin" {
                        Circle().fill(HQTheme.gold).frame(width: 6, height: 6).padding(6)
                    }
                }
            HStack(spacing: 4) {
                leg
                leg
            }
            HStack(spacing: 4) {
                shoe
                shoe
            }
        }
    }

    private var leg: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Catalog.color(outfit.bottomsColor))
            .frame(width: 14, height: outfit.bottoms == "chinos" ? 22 : 28)
    }

    private var shoe: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Catalog.color(outfit.shoesColor))
            .frame(width: 16, height: outfit.shoes == "trainers" ? 8 : 6)
    }
}
