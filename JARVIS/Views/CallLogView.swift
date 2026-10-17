import SwiftUI

struct CallLogView: View {
    @Environment(AssistantEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var rows: [StoredCall] = []
    @State private var openID: String?

    var body: some View {
        List {
            if rows.isEmpty {
                Text("No calls yet. Say call someone and tell them the message.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .listRowBackground(Color.black)
            }
            ForEach(rows) { row in
                callRow(row)
                    .listRowBackground(Color.black)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Calls")
        .toolbar(.visible, for: .navigationBar)
        .tint(settings.primaryColor)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") { engine.refreshOpenCalls() }
            }
        }
        .onAppear {
            rows = CallLogStore.entries()
            engine.refreshOpenCalls()
        }
        .onChange(of: engine.callLogTick) { _, _ in
            rows = CallLogStore.entries()
        }
    }

    private func callRow(_ row: StoredCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                openID = openID == row.id ? nil : row.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        if row.direction == "inbound" {
                            Text("In")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(settings.accentColor)
                        }
                        Spacer()
                        Text(row.titleStatus)
                            .font(.caption)
                            .foregroundStyle(settings.accentColor)
                    }
                    Text(row.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if openID == row.id {
                Text(row.number)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
                if let reason = row.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.white)
                } else {
                    Text(row.brief)
                        .font(.footnote)
                        .foregroundStyle(.white)
                }
                if !row.summary.isEmpty {
                    Text(row.summary)
                        .font(.body)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                ForEach(row.transcript) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(settings.primaryColor)
                        Text(line.text)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }
                }
                Button("Delete", role: .destructive) {
                    CallLogStore.remove(id: row.id)
                    if openID == row.id { openID = nil }
                    rows = CallLogStore.entries()
                }
                .font(.footnote)
            }
        }
    }
}

/// Approval for one briefed call. Say yes, or tap Approve. Other actions stay on their own cards.
struct CallBriefBar: View {
    @Environment(AssistantEngine.self) private var engine

    var body: some View {
        if let brief = engine.pendingCallBrief {
            VStack(alignment: .leading, spacing: 8) {
                Text("Call \(brief.contactName)?")
                    .font(.subheadline.weight(.semibold))
                Text(brief.number)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(brief.brief)
                    .font(.subheadline)
                Text("Say yes, or tap Approve. Say no to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Decline") {
                        JarvisHaptics.tap()
                        engine.declinePendingCall()
                    }
                    .buttonStyle(.bordered)
                    Button("Approve") {
                        JarvisHaptics.tap()
                        engine.approvePendingCall()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
