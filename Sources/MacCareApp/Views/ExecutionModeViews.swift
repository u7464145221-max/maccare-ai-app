import SwiftUI
import MacCareCore

// MARK: - Tryb wykonania (W4): „Tylko odczyt” ↔ „Edycja”

/// Wybór w przełączniku trybu wykonania.
enum ExecutionChoice: String, CaseIterable, Hashable {
    case readOnly = "Tylko odczyt", edit = "Edycja"
}

/// Przełącznik „Tylko odczyt / Edycja” (pasek u góry i Ustawienia). Wybór „Edycja” NIE włącza trybu od razu – otwiera arkusz potwierdzenia.
/// Powrót do „Tylko odczyt” jest natychmiastowy. Kolor zaznaczenia niesie stan: niebieski = odczyt, bursztynowy = Edycja.
struct ExecutionModeSwitch: View {
    @EnvironmentObject var model: AppModel
    var width: CGFloat = 230

    var body: some View {
        SegmentedSwitch(
            selection: Binding(
                get: { model.isReadOnlyMode ? ExecutionChoice.readOnly : .edit },
                set: { choice in
                    switch choice {
                    case .edit: model.requestEditMode()
                    case .readOnly: model.leaveEditMode()
                    }
                }),
            options: ExecutionChoice.allCases, title: { $0.title },
            moduleFor: { $0 == .readOnly ? .protection : .performance },
            width: width, accessibilityName: String(localized: "Tryb wykonania"))
            .help(model.isReadOnlyMode
                  ? String(localized: "Tylko odczyt: MacCare niczego nie zmienia w systemie. „Edycja” odblokowuje wyłącznie przenoszenie do Kosza (Moje pliki, Porządki, odinstalowanie).")
                  : String(localized: "Edycja: działa tylko „Przenieś do Kosza” (Moje pliki, Porządki, odinstalowanie); wszystko inne czeka na zakończenie poprawek bezpieczeństwa kwarantanny."))
            .id(model.executionRevision)                       // wymusza odświeżenie po zmianie trybu z zewnątrz (np. automatyczny powrót po bezczynności)
    }
}

/// Stały, wyraźny wskaźnik trybu: ikona + napis (+ odliczanie do automatycznego powrotu w Edycji). W Edycji w kolorze ostrzegawczym.
struct ExecutionModeIndicator: View {
    @EnvironmentObject var model: AppModel

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        if model.isReadOnlyMode {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "lock.fill")
                Text("Tryb tylko do odczytu – analiza i podgląd, bez zmian w systemie").font(Theme.Typo.caption.weight(.semibold)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "pencil.circle.fill")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = model.executionState.remainingIdle.map { String(localized: " · powrót do odczytu za \(Self.clock($0))") } ?? ""
                    Text("Edycja włączona – tylko „Przenieś do Kosza” (Moje pliki, Porządki, Aplikacje)\(left)").font(Theme.Typo.caption.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                }
            }
            .foregroundStyle(Theme.Palette.warning)
        }
    }
}

/// Informacja po automatycznym powrocie do odczytu.
struct EditNoticeBar: View {
    @EnvironmentObject var model: AppModel
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(Theme.Palette.info)
            Text(text).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.text)
            Spacer()
            Button { model.editNotice = nil } label: { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }.accessibilityLabel("Zamknij informację")
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary).help("Zamknij")
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 4)
        .background(Theme.Palette.surfaceAlt)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Palette.hairline).frame(height: 1) }
    }
}

/// P2-7: ostrzeżenie o bazie historii (uszkodzona – zarchiwizowana / niedostępna).
struct StorageWarningBar: View {
    @EnvironmentObject var model: AppModel
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Palette.warning)
            Text(text).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.text).lineLimit(2)
            Spacer()
            Button { model.storageWarning = nil } label: { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary).help("Zamknij").accessibilityLabel("Zamknij ostrzeżenie")
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 4)
        .background(Theme.Palette.surfaceAlt)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Palette.hairline).frame(height: 1) }
    }
}

/// Pasek po włączeniu Edycji: gdzie znaleźć „Przenieś do Kosza” (skrót do „Moje pliki”; w trybie Prostym przełącza widok na Profesjonalny).
struct EditFilesShortcutBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.gearshape").foregroundStyle(Theme.Palette.warning)
            Text(model.viewMode == .simple
                 ? String(localized: "Edycja włączona. Zaznaczone pliki przeniesiesz do Kosza w „Moje pliki” (widok Profesjonalny).")
                 : String(localized: "Edycja włączona. Zaznacz pliki w „Moje pliki”, aby przenieść je do Kosza."))
                .font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.text).lineLimit(2)
            Spacer()
            Button("Przejdź do Moje pliki") { model.openMyFiles() }.buttonStyle(.soft)
            Button { model.filesShortcutDismissed = true } label: { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary).help("Zamknij").accessibilityLabel("Zamknij podpowiedź")
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 4)
        .background(Theme.Palette.surfaceAlt)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Palette.hairline).frame(height: 1) }
    }
}

/// Arkusz potwierdzenia włączenia Edycji: co się odblokowuje, co nadal jest zablokowane, kiedy Edycja sama się wyłączy.
struct EditModeSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "pencil.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.Palette.warning)
                Text("Włączyć tryb Edycja?").font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
            }
            Text("Domyślnie MacCare niczego nie zmienia. Edycja odblokowuje wyłącznie przenoszenie do Kosza.").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)

            point("checkmark.circle.fill", Theme.Palette.ok, String(localized: "Odblokowane: „Przenieś do Kosza”"),
                  String(localized: "Pliki i foldery zaznaczone w „Moje pliki”, pozycje zaznaczone w Porządkach i odinstalowanie wybranej aplikacji – zawsze po Twoim potwierdzeniu. Trafiają do Kosza macOS, więc możesz je stamtąd przywrócić (Finder → Kosz → Odłóż). Nic nie jest kasowane na stałe."))
            point("lock.fill", Theme.Palette.textSecondary, String(localized: "Nadal zablokowane – dostępne po zakończeniu poprawek bezpieczeństwa kwarantanny"),
                  String(localized: "Czyszczenie przez kwarantannę, trwałe usuwanie, opróżnianie Kosza, wyłączanie agentów autostartu i polecenia administratora."))
            point("timer", Theme.Palette.info, String(localized: "Edycja wyłącza się sama"),
                  String(localized: "Po \(model.editAutoReturnMinutes) min bezczynności i zawsze przy następnym uruchomieniu MacCare. Asystent AI nigdy nie włącza ani nie wyłącza Edycji."))

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Anuluj") { model.cancelEditConfirmation() }.keyboardShortcut(.cancelAction).buttonStyle(.soft)
                Button("Włącz edycję") { model.confirmEditMode() }.keyboardShortcut(.defaultAction).buttonStyle(.prominent(.performance, large: true))
            }
        }
        .padding(Theme.Space.xl).frame(width: 560)
        .background(Theme.Palette.background)
    }

    private func point(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Text(detail).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }
}
