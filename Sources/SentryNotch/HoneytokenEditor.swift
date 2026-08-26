import SwiftUI
import AppKit
import SentryNotchCore

/// Manage honeytokens — decoy paths an agent must never touch. Off by default;
/// arming it turns any access to a decoy into an incident (deny + panic).
struct HoneytokenEditor: View {
    @ObservedObject var settings: AppSettings
    @State private var newPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleRow
            Text("A decoy an agent should never read — a fake key, a bait `.env`. Any access is denied and the panic brake is armed. Add a full path, or a bare filename to match anywhere.")
                .font(.system(size: 10)).foregroundStyle(CC.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(settings.honeytokens) { t in
                HStack(spacing: 8) {
                    Image(systemName: "drop.fill").font(.system(size: 10)).foregroundStyle(CC.coral)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(CC.text)
                        Text(t.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(CC.textDim)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { settings.honeytokens.removeAll { $0.id == t.id } } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(CC.textDim)
                    }.buttonStyle(.plain)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(CC.surfaceHi))
            }

            HStack(spacing: 8) {
                TextField("~/work/project/.env.prod  or  prod-root.pem", text: $newPath)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(CC.text).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(CC.surfaceHi))
                    .onSubmit(addPath)
                Button("Add", action: addPath).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(CC.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CC.surfaceHi))
                    .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(!settings.honeytokensEnabled).opacity(settings.honeytokensEnabled ? 1 : 0.5)

            Button(action: plantStarter) {
                Label("Plant starter decoys…", systemImage: "drop.triangle")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(settings.accentColor))
            }.buttonStyle(.plain)
                .disabled(!settings.honeytokensEnabled)
        }
    }

    private var toggleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Arm honeytokens").font(.system(size: 13, weight: .semibold)).foregroundStyle(CC.text)
                Text("Deny + panic on any access to a decoy").font(.system(size: 11)).foregroundStyle(CC.textDim)
            }
            Spacer()
            Toggle("", isOn: $settings.honeytokensEnabled).labelsHidden().tint(settings.accentColor)
        }
    }

    private func addPath() {
        let p = newPath.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        let label = (p as NSString).lastPathComponent
        settings.honeytokens.append(Honeytoken(path: p, label: label.isEmpty ? p : label))
        newPath = ""
    }

    /// Write the starter bait into a directory the user picks, and register each
    /// as a honeytoken. Deliberately explicit — it writes real (harmless) files.
    private func plantStarter() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Plant decoys here"
        panel.message = "Choose where to write the bait files. They contain fake credentials only."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for (name, contents) in starterHoneytokenFiles() {
            let url = dir.appendingPathComponent(name)
            guard (try? contents.write(to: url, atomically: true, encoding: .utf8)) != nil else { continue }
            if !settings.honeytokens.contains(where: { $0.path == url.path }) {
                settings.honeytokens.append(Honeytoken(path: url.path, label: name))
            }
        }
    }
}
