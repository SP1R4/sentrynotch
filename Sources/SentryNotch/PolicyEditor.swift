import SwiftUI
import SentryNotchCore

/// Editor for the declarative policy (allow / deny / ask rules evaluated before
/// the auto-allow tiers). Self-contained so it can live outside `Dashboard`'s
/// file-private helpers. Rules are checked top-to-bottom, first match wins, so
/// order is meaningful and the list offers move up/down.
struct PolicyEditor: View {
    @ObservedObject var settings: AppSettings

    private let tools = ["Bash", "Write", "Edit", "MultiEdit", "Read", "WebFetch", "WebSearch"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cap("POLICY ENGINE")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evaluate rules before auto-allow")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(CC.text)
                    Text("A deny is honoured even out of scope; an allow still surfaces on a scope breach; an ask forces the prompt open.")
                        .font(.system(size: 11)).foregroundStyle(CC.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $settings.policyEnabled).labelsHidden().tint(settings.accentColor)
            }
            .padding(12).background(card)

            if settings.policyRules.isEmpty {
                emptyState
            } else {
                Text("Checked top to bottom — the first matching rule wins. A rule with no conditions matches everything.")
                    .font(.system(size: 11)).foregroundStyle(CC.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(settings.policyRules.indices, id: \.self) { i in
                    ruleCard(i).opacity(settings.policyEnabled ? 1 : 0.5)
                }
                HStack(spacing: 8) {
                    addButton
                    Spacer()
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No rules yet. Every tool call falls through to the per-project auto-allow tiers.")
                .font(.system(size: 12)).foregroundStyle(CC.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { settings.policyRules = starterPolicy() } label: {
                    Label("Load starter policy", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(settings.accentColor))
                }.buttonStyle(.plain)
                addButton
            }
        }
        .padding(12).background(card)
    }

    private var addButton: some View {
        Button { settings.policyRules.append(PolicyRule(name: "New rule", effect: .prompt)) } label: {
            Label("Add rule", systemImage: "plus")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(CC.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(CC.surfaceHi))
        }.buttonStyle(.plain)
    }

    // MARK: - One rule

    private func ruleCard(_ i: Int) -> some View {
        let rule = settings.policyRules[i]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle("", isOn: bool(\.enabled, i)).labelsHidden().tint(settings.accentColor)
                    .scaleEffect(0.85)
                TextField("Rule name", text: str(\.name, i))
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CC.text)
                Spacer(minLength: 6)
                effectMenu(i)
                moveButtons(i)
                Button { settings.policyRules.remove(at: i) } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(CC.textDim)
                }.buttonStyle(.plain).help("Delete rule")
            }

            // Conditions
            VStack(spacing: 6) {
                condRow("Tools", TextField("any (comma-separated)", text: toolsBinding(i)))
                condRow("Path glob", TextField("e.g. **/.ssh/**", text: optStr(\.pathGlob, i)))
                condRow("Command ~", TextField("regex, e.g. git\\s+push", text: optStr(\.commandRegex, i)))
                condRow("Host glob", TextField("e.g. *.evil.com", text: optStr(\.hostGlob, i)))
                HStack(spacing: 8) {
                    Text("Min risk").font(.system(size: 11)).foregroundStyle(CC.textDim)
                        .frame(width: 90, alignment: .leading)
                    riskMenu(i)
                    Spacer(minLength: 12)
                    Text("Scope").font(.system(size: 11)).foregroundStyle(CC.textDim)
                    scopeMenu(i)
                    Spacer()
                }
            }

            if !rule.isValid {
                warn("Invalid command regex — this rule can never match.", .red)
            } else if rule.isUnconditional {
                warn("No conditions — this rule matches every call and short-circuits the rest.", CC.coral)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(effectColor(rule.effect).opacity(0.35), lineWidth: 1))
    }

    private func condRow<F: View>(_ label: String, _ field: F) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(CC.textDim)
                .frame(width: 90, alignment: .leading)
            field.textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(CC.text)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(CC.surfaceHi))
        }
    }

    private func moveButtons(_ i: Int) -> some View {
        HStack(spacing: 2) {
            Button { if i > 0 { settings.policyRules.swapAt(i, i - 1) } } label: {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(i > 0 ? CC.textDim : CC.textFaint)
            }.buttonStyle(.plain).disabled(i == 0)
            Button { if i < settings.policyRules.count - 1 { settings.policyRules.swapAt(i, i + 1) } } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(i < settings.policyRules.count - 1 ? CC.textDim : CC.textFaint)
            }.buttonStyle(.plain).disabled(i == settings.policyRules.count - 1)
        }
    }

    // MARK: - Menus

    private func effectMenu(_ i: Int) -> some View {
        let e = settings.policyRules[i].effect
        return Menu {
            ForEach(PolicyEffect.allCases) { eff in
                Button(eff.label) { settings.policyRules[i].effect = eff }
            }
        } label: {
            Text(e.label).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(effectColor(e)))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func riskMenu(_ i: Int) -> some View {
        let levels: [(String, RiskLevel?)] = [("Any", nil), ("Low", .low), ("Medium", .medium), ("High", .high)]
        let cur = settings.policyRules[i].minRisk
        let name = levels.first { $0.1 == cur }?.0 ?? "Any"
        return Menu {
            ForEach(levels, id: \.0) { l in Button(l.0) { settings.policyRules[i].minRisk = l.1 } }
        } label: { pill(name) }.menuStyle(.borderlessButton).fixedSize()
    }

    private func scopeMenu(_ i: Int) -> some View {
        let opts: [(String, ScopeMatch?)] = [("Any", nil), ("In scope", .inScope), ("Out of scope", .outOfScope)]
        let cur = settings.policyRules[i].scope
        let name = opts.first { $0.1 == cur }?.0 ?? "Any"
        return Menu {
            ForEach(opts, id: \.0) { o in Button(o.0) { settings.policyRules[i].scope = o.1 } }
        } label: { pill(name) }.menuStyle(.borderlessButton).fixedSize()
    }

    private func pill(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .medium)).foregroundStyle(CC.text)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(CC.surfaceHi))
    }

    private func warn(_ s: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            Text(s).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(color)
    }

    private func effectColor(_ e: PolicyEffect) -> Color {
        switch e {
        case .allow:  return Color(red: 0.35, green: 0.72, blue: 0.5)
        case .deny:   return Color(red: 0.85, green: 0.32, blue: 0.30)
        case .prompt: return settings.accentColor
        }
    }

    private var card: some View { RoundedRectangle(cornerRadius: 10).fill(CC.surface) }
    private func cap(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .bold)).tracking(0.4).foregroundStyle(CC.textDim)
    }

    // MARK: - Bindings into settings.policyRules[i]

    // All bindings are index-guarded: ForEach(indices) + delete/reorder can fire
    // a stale binding after the array has shrunk, and an unchecked subscript
    // there is an out-of-range crash.
    private func bool(_ kp: WritableKeyPath<PolicyRule, Bool>, _ i: Int) -> Binding<Bool> {
        Binding(get: { settings.policyRules.indices.contains(i) ? settings.policyRules[i][keyPath: kp] : false },
                set: { if settings.policyRules.indices.contains(i) { settings.policyRules[i][keyPath: kp] = $0 } })
    }
    private func str(_ kp: WritableKeyPath<PolicyRule, String>, _ i: Int) -> Binding<String> {
        Binding(get: { settings.policyRules.indices.contains(i) ? settings.policyRules[i][keyPath: kp] : "" },
                set: { if settings.policyRules.indices.contains(i) { settings.policyRules[i][keyPath: kp] = $0 } })
    }
    private func optStr(_ kp: WritableKeyPath<PolicyRule, String?>, _ i: Int) -> Binding<String> {
        Binding(get: { settings.policyRules.indices.contains(i) ? (settings.policyRules[i][keyPath: kp] ?? "") : "" },
                set: { if settings.policyRules.indices.contains(i) { settings.policyRules[i][keyPath: kp] = $0.isEmpty ? nil : $0 } })
    }
    private func toolsBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { settings.policyRules.indices.contains(i) ? (settings.policyRules[i].tools ?? []).joined(separator: ", ") : "" },
            set: { s in
                guard settings.policyRules.indices.contains(i) else { return }
                let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                settings.policyRules[i].tools = parts.isEmpty ? nil : parts
            })
    }
}
