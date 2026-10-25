import AtlasCore
import SwiftUI

/// Offered when a newer release exists: what's new, then download, verify and restart.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ATLAS \(model.availableUpdate?.version ?? "") is available").font(.title3.weight(.semibold))
                    Text("You have \(Updater.currentVersion). Your data, settings and permissions stay as they are.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let notes = model.availableUpdate?.notes, !notes.isEmpty {
                ScrollView {
                    Text((try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notes))
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let status = model.updateStatus, model.updateBusy || status.contains("couldn't") || status.contains("wasn't") || status.contains("failed") || status.contains("can't") {
                HStack(spacing: 8) {
                    if model.updateBusy { ProgressView().controlSize(.small) }
                    Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if let page = model.availableUpdate?.page { Link("Release page", destination: page).font(.callout) }
                Spacer()
                Button("Later") { model.showUpdate = false }.keyboardShortcut(.cancelAction).disabled(model.updateBusy)
                Button("Install and restart") { Task { await model.installUpdate() } }
                    .keyboardShortcut(.defaultAction).disabled(model.updateBusy)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// Sidebar note while an update is waiting.
struct UpdatePill: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let r = model.availableUpdate {
            Button { model.showUpdate = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.live)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Update available").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("ATLAS \(r.version)").font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.live.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
