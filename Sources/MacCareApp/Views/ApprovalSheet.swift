import SwiftUI
import MacCareCore

/// Arkusz operacji: pokazuje, co się stanie, zanim cokolwiek zostanie wykonane. Kategorie wrażliwe wymagają osobnego potwierdzenia.
/// W trybie tylko do odczytu to wyłącznie PODGLĄD: przycisk zatwierdzenia jest wyłączony (z wyjaśnieniem), nic nie jest wykonywane.
struct ApprovalSheet: View {
    @EnvironmentObject var model: AppModel
    let content: SheetContent
    @State private var confirmed: Set<SensitiveCategory> = []

    private var simple: Bool { model.viewMode == .simple }
    private func shown(_ s: String) -> String { simple ? SimplePresentation.plain(s) : s }
    private var canApprove: Bool { !content.readOnly && Set(content.separate).isSubset(of: confirmed) && !model.operationRunning }

    var body: some View {
        let p = content.preview
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: content.readOnly ? "eye.fill" : "checkmark.shield.fill").font(.system(size: 22)).foregroundStyle(Theme.Palette.accent)
                    Text(content.readOnly ? String(localized: "Podgląd zmian") : String(localized: "Zatwierdź operację")).font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
                }
                Text(p.title).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                HStack(spacing: Theme.Space.xs) {
                    if !simple { RiskBadge(risk: p.risk) }
                    Pill(text: p.reversible ? String(localized: "odwracalne") : String(localized: "nieodwracalne"), color: p.reversible ? Theme.Palette.ok : Theme.Palette.critical, symbol: p.reversible ? "arrow.uturn.backward" : "exclamationmark.octagon")
                    if !simple { Pill(text: content.origin, color: Theme.Palette.textSecondary) }
                }
            }
            .padding(Theme.Space.xl)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    row(String(localized: "Cel"), shown(p.purpose))
                    row(String(localized: "Spodziewany efekt"), shown(p.expectedEffect))
                    row(String(localized: "Jak cofnąć"), shown(p.undoDescription))
                    if let b = p.estimatedBytes { row(content.toolName == "trash_selected" ? String(localized: "Rozmiar przenoszonych elementów (miejsce wróci po opróżnieniu Kosza)") : String(localized: "Szacowane miejsce do odzyskania"), ByteFormat.string(b)) }
                    let perms = content.permissions.filter { $0 != .none }
                    if !perms.isEmpty && !simple { row(String(localized: "Wymagane uprawnienia"), perms.map { $0.label }.joined(separator: ", ")) }
                    if !p.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ostrzeżenia").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.warning)
                            ForEach(p.warnings.prefix(20), id: \.self) { w in
                                Label(shown(w), systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning).fixedSize(horizontal: false, vertical: true)
                            }
                            if p.warnings.count > 20 { Text("…i \(p.warnings.count - 20) kolejnych").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary) }
                        }
                    }
                    if !p.affectedItems.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Elementy (\(p.affectedItems.count))").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
                            ForEach(p.affectedItems.prefix(100), id: \.self) { Text(simple ? ($0 as NSString).lastPathComponent : $0).font(Theme.Typo.mono).foregroundStyle(Theme.Palette.text).lineLimit(1).truncationMode(.middle) }
                            if p.affectedItems.count > 100 { Text("…i \(p.affectedItems.count - 100) kolejnych").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary) }
                        }
                        .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                    }
                    if !content.separate.isEmpty && !content.readOnly {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text("Wymagane osobne potwierdzenie").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.critical)
                            ForEach(content.separate, id: \.self) { cat in
                                Toggle(isOn: Binding(get: { confirmed.contains(cat) }, set: { if $0 { confirmed.insert(cat) } else { confirmed.remove(cat) } })) {
                                    Text("Rozumiem: \(cat.label)").font(Theme.Typo.body).foregroundStyle(Theme.Palette.text)
                                }.toggleStyle(.largeCheckbox)
                            }
                        }
                        .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Palette.critical.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                    }
                }
                .padding(Theme.Space.xl)
            }
            Divider()
            HStack {
                if content.readOnly {
                    VStack(alignment: .leading, spacing: 3) {
                        Label((content.reason ?? ExecutionGuard.message) + String(localized: ". To tylko podgląd – nic nie zostanie zmienione."), systemImage: "lock.fill")
                            .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.info).fixedSize(horizontal: false, vertical: true)
                        if let note = content.futureNote { Text(note).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true) }
                    }
                } else {
                    Text("Nic nie zostanie wykonane przed kliknięciem „\(content.approveTitle)”.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                if model.operationRunning { ProgressView().controlSize(.small) }
                if content.readOnly && content.canEnableEdit {
                    Button("Włącz edycję…") { Task { await model.requestEditModeFromPreview() } }.buttonStyle(.soft)
                        .help("Zamyka podgląd i pokazuje potwierdzenie trybu Edycja.")
                }
                Button(content.readOnly ? String(localized: "Zamknij") : String(localized: "Anuluj")) { Task { await model.decline() } }.keyboardShortcut(.cancelAction).buttonStyle(.soft)
                Button(content.approveTitle) { Task { await model.approve(confirmed: confirmed) } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.prominent(.cleanup, large: true)).disabled(!canApprove)
                    .help(content.readOnly ? String(localized: "Wyłączone: \(content.reason ?? ExecutionGuard.message).") : "")
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 600, height: 620)
        .background(Theme.Palette.background)
    }

    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
            Text(v).font(Theme.Typo.body).foregroundStyle(Theme.Palette.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
