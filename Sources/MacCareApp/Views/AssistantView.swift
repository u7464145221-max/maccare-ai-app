import SwiftUI
import MacCareCore
import MacCareAI

/// Ekran Asystenta AI (P2-9): pytanie → lokalny model zbiera dane narzędziami ODCZYTU → odpowiedź z dowodami i poziomem pewności.
/// Propozycje operacji są wyłącznie podglądem – asystent niczego nie zmienia i nie przełącza trybu Edycja.
struct AssistantView: View {
    @ObservedObject var store: AssistantStore
    @State private var question = ""

    var body: some View {
        VStack(spacing: 12) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.entries.isEmpty { intro }
                        ForEach(store.entries) { e in entry(e).id(e.id) }
                    }
                    .padding(16)
                }
                .onChange(of: store.entries.count) { _, _ in if let last = store.entries.last { Motion.perform { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.Palette.stroke, lineWidth: 1))
            inputBar
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 16)
        .task { if store.status == .unknown { await store.refreshStatus() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack { Circle().fill(AppModule.assistant.fill); Image(systemName: AppModule.assistant.symbol).foregroundStyle(AppModule.assistant.label) }.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Asystent").font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
                statusLine
            }
            Spacer()
            Button { Task { await store.refreshStatus() } } label: { Label("Sprawdź model", systemImage: "arrow.clockwise") }
                .buttonStyle(.soft).disabled(store.busy || store.status == .checking).fixedSize()
            Button { store.clear() } label: { Label("Wyczyść", systemImage: "trash.slash") }
                .buttonStyle(.soft).disabled(store.busy || store.entries.isEmpty).fixedSize()
                .help("Czyści rozmowę na ekranie (wpisy w Dzienniku operacji zostają).")
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch store.status {
        case .unknown, .checking:
            Label("Sprawdzam lokalny model…", systemImage: "hourglass").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
        case .ready(let name):
            Label("\(name) · działa lokalnie, dane nie opuszczają Maca", systemImage: "lock.shield").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.ok)
        case .unavailable(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.warning)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true).help(why)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zapytaj o stan Maca").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
            Text("Asystent czyta pomiary (procesor, pamięć, dysk, autostart, bateria) i odpowiada z dowodami. Każde twierdzenie ma poziom pewności; liczby są sprawdzane z pomiarami. Asystent niczego nie zmienia – propozycje operacji widzisz tylko jako podgląd.")
                .font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            FlowSuggestions(items: AssistantStore.suggestions) { q in store.ask(q) }
                .disabled(store.busy)
        }
    }

    private func entry(_ e: AssistantStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Spacer(minLength: 80); Text(e.question).font(Theme.Typo.body).foregroundStyle(Theme.Palette.text).padding(10)
                .background(Theme.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).textSelection(.enabled) }
            if let a = e.answer { answer(a) }
            else if let err = e.error { Label(err, systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.body).foregroundStyle(Theme.Palette.warning).fixedSize(horizontal: false, vertical: true) }
            else { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Zbieram pomiary i analizuję…").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) } }
        }
    }

    private func answer(_ a: AssistantAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if a.fallback { Pill(text: String(localized: "Odpowiedź z reguł (model nie odpowiedział poprawnie)"), color: Theme.Palette.warning) }
            Text(a.summary).font(Theme.Typo.body).foregroundStyle(Theme.Palette.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(a.claims.enumerated()), id: \.offset) { _, c in claim(c) }
            if !a.missingData.isEmpty {
                Text(String(localized: "Brakuje danych: ") + a.missingData.joined(separator: "; ")).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            ForEach(Array(a.previewOnly.enumerated()), id: \.offset) { _, p in
                Label("Propozycja (tylko podgląd, nic nie zostało zmienione): \(p.title)", systemImage: "eye").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.info)
            }
            ForEach(a.rejectedProposals, id: \.self) { r in
                Label("Odrzucona propozycja: \(r)", systemImage: "nosign").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            if !a.steps.isEmpty {
                DisclosureGroup("Przebieg (\(Plural.counted(a.steps.count, one: "krok", few: "kroki", many: "kroków")))") {
                    VStack(alignment: .leading, spacing: 3) { ForEach(Array(a.steps.enumerated()), id: \.offset) { _, s in Text(s).font(Theme.Typo.caption.monospaced()).foregroundStyle(Theme.Palette.textSecondary).lineLimit(3) } }
                }.font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(12)
        .background(Theme.Palette.surfaceAlt.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func claim(_ c: AssistantClaim) -> some View {
        let (label, color): (String, Color) = {
            switch c.certainty {
            case .confirmed: return (String(localized: "potwierdzone pomiarem"), Theme.Palette.ok)
            case .probable: return (String(localized: "prawdopodobne"), Theme.Palette.info)
            default: return (String(localized: "przypuszczenie"), Theme.Palette.warning)
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Pill(text: label, color: color)
                Text(c.text).font(Theme.Typo.body).foregroundStyle(Theme.Palette.text).fixedSize(horizontal: false, vertical: true)
            }
            if !c.evidence.isEmpty { Text("Dowody: " + c.evidence.joined(separator: ", ")).font(Theme.Typo.caption.monospaced()).foregroundStyle(Theme.Palette.textSecondary) }
            if let n = c.groundingNote { Text(n).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Zapytaj, np. „Dlaczego wentylator się kręci?”", text: $question, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.Typo.body).lineLimit(1...4)
                .padding(10).background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.Palette.stroke, lineWidth: 1))
                .onSubmit(send).disabled(store.busy)
                .accessibilityLabel("Pytanie do asystenta")
            if store.busy {
                Button("Zatrzymaj") { store.cancel() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
            } else {
                Button { send() } label: { Label("Zapytaj", systemImage: "paperplane.fill") }
                    .buttonStyle(.prominent(.assistant, large: true))
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.status == .checking)
            }
        }
    }

    private func send() { let q = question; question = ""; store.ask(q) }
}

/// Podpowiedzi pytań – zawijane w wiersze.
struct FlowSuggestions: View {
    let items: [String]
    let action: (String) -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(items, id: \.self) { q in chip(q) } }
            VStack(alignment: .leading, spacing: 8) { ForEach(items, id: \.self) { q in chip(q) } }
        }
    }
    private func chip(_ q: String) -> some View {
        Button(q) { action(q) }.buttonStyle(.soft)
    }
}

/// Ustawienia: model Asystenta – automatycznie albo wybrany zainstalowany model Ollamy (z rozmiarem i informacją, czy mieści się teraz w pamięci).
struct AssistantModelSettings: View {
    @ObservedObject var store: AssistantStore
    var body: some View {
        SurfaceCard(padding: 20, radius: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Asystent AI – model").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Picker("Model", selection: Binding(get: { store.preferredModel ?? "" }, set: { store.preferredModel = $0.isEmpty ? nil : $0 })) {
                    Text("Automatycznie (zalecane)").tag("")
                    ForEach(store.installedModels, id: \.name) { m in
                        Text("\(m.name) · \(ByteFormat.string(m.sizeBytes))\(store.fitsNow(m) ? "" : String(localized: " · teraz się nie mieści"))").tag(m.name)
                    }
                }
                .labelsHidden().frame(maxWidth: 520)
                Text("Modele działają lokalnie przez Ollamę (127.0.0.1) – dane nie opuszczają Maca, a MacCare niczego nie pobiera sam. „Automatycznie” wybiera zainstalowany model, który teraz zmieści się w pamięci (kolejno: qwen2.5, qwen3, Bielik, Llama 3, Mistral, Gemma).")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if store.installedModels.isEmpty { Text("Nie znaleziono modeli Ollamy (aplikacja Ollama nie działa albo nie ma pobranych modeli).").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning) }
            }
        }
        .task { await store.loadInstalledModels() }
    }
}
