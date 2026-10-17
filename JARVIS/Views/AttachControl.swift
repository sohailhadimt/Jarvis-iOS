import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Paperclip for a photo, PDF or text file. The bytes wait on the engine until the next question.
struct AttachControl: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var showChoices = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        Button {
            showChoices = true
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(settings.accentColor)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach")
        .confirmationDialog("Attach", isPresented: $showChoices, titleVisibility: .visible) {
            Button("Photo") { showPhotos = true }
            Button("File") { showFiles = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image, .plainText, .text, .commaSeparatedText], allowsMultipleSelection: false) { result in
            importFile(result)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        if let picked = try? await item.loadTransferable(type: PickedImage.self) {
            engine.stageFile(name: "Photo", data: picked.data, ext: "jpg")
        } else {
            engine.errorMessage = "JARVIS couldn't read that photo."
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            engine.errorMessage = "JARVIS couldn't open that file."
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url) else {
                engine.errorMessage = "JARVIS couldn't read that file."
                return
            }
            engine.stageFile(name: url.lastPathComponent, data: data, ext: url.pathExtension)
        }
    }
}

private struct PickedImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PickedImage(data: data)
        }
    }
}

struct GeneratedPreview: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let data = engine.generatedPreview, let image = UIImage(data: data) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.accentColor.opacity(0.7), lineWidth: 1))
                Button {
                    engine.clearGenerated()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss picture")
                .padding(4)
            }
        }
    }
}

struct AttachmentChip: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let name = engine.attachmentName, !name.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .medium))
                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Button {
                    engine.clearAttachment()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove file")
            }
            .foregroundStyle(settings.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .overlay(Capsule().stroke(settings.accentColor.opacity(0.7), lineWidth: 1))
        }
    }
}
