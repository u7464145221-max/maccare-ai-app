import SwiftUI
import MacCareCore

/// Kategoria na mapie dysku: kolor = rodzaj zawartości (paleta Okabe–Ito, odporna na daltonizm) + legenda.
enum MapCategory: String, CaseIterable, Identifiable {
    case video, image, archive, installer, document, code, app, aiModel, container, project, appData, other
    var id: String { rawValue }

    init(kind: FileKind?, isApp: Bool = false) {
        if isApp { self = .app; return }
        switch kind {
        case .video?, .audio?: self = .video
        case .image?: self = .image
        case .archive?: self = .archive
        case .installer?, .diskImage?: self = .installer
        case .document?: self = .document
        case .code?: self = .code
        case .application?: self = .app
        case .aiModel?: self = .aiModel
        case .container?: self = .container
        case .project?: self = .project
        case .appData?: self = .appData
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .video: return String(localized: "Wideo i audio"); case .image: return String(localized: "Obrazy"); case .archive: return String(localized: "Archiwa")
        case .installer: return String(localized: "Instalatory i obrazy dysków"); case .document: return String(localized: "Dokumenty"); case .code: return String(localized: "Kod")
        case .app: return String(localized: "Aplikacje"); case .aiModel: return String(localized: "Modele AI"); case .container: return String(localized: "Kontenery i maszyny wirtualne")
        case .project: return String(localized: "Projekty i zależności"); case .appData: return String(localized: "Dane aplikacji"); case .other: return String(localized: "Inne")
        }
    }
    var symbol: String {
        switch self {
        case .video: return "film"; case .image: return "photo"; case .archive: return "archivebox"; case .installer: return "shippingbox"
        case .document: return "doc.text"; case .code: return "chevron.left.forwardslash.chevron.right"; case .app: return "app"; case .other: return "folder"
        case .aiModel: return "brain"; case .container: return "shippingbox.and.arrow.backward"; case .project: return "hammer"; case .appData: return "internaldrive"
        }
    }
    /// Okabe–Ito (8) + 4 kolory dobrane obliczeniowo. Ten sam odcień w obu motywach.
    var hex: UInt32 {
        switch self {
        case .video: return 0xD55E00; case .image: return 0x0072B2; case .archive: return 0xE69F00; case .installer: return 0xCC79A7
        case .document: return 0x009E73; case .code: return 0x56B4E9; case .app: return 0xF0E442; case .other: return 0x7F7F7F
        // dodatkowe, dobrane obliczeniowo (max. odległość CIELAB, także przy protanopii/deuteranopii/tritanopii)
        case .aiModel: return 0x332288; case .container: return 0xEE8866; case .project: return 0x882255; case .appData: return 0x999933
        }
    }
    var fillColor: Color { Color(hex: hex) }
    /// Tekst na wypełnieniu: czarny albo biały – wg kontrastu.
    var labelHex: UInt32 { WCAG.readable(on: hex) }
    var labelColor: Color { Color(hex: labelHex) }
    /// Obrys bąbla: odcień wypełnienia dociągnięty do ≥ 3:1 względem karty (jasne wypełnienia na białej karcie nie giną).
    func outlineHex(dark: Bool) -> UInt32 {
        let surface = Theme.PaletteHex.surface.value(dark: dark)
        return WCAG.ensure(hex, against: [surface], min: WCAG.graphicMin, towardDark: !dark)
    }
    func outlineColor() -> Color { Theme.dynamic(light: outlineHex(dark: false), dark: outlineHex(dark: true)) }
}

/// Układ wykresu bąbelkowego: czysta funkcja (testowana). Wykres wypełnia kontener, etykiety mieszczą się w bąblach i nie nakładają.
enum BubbleLayout {
    struct Placed: Equatable {
        let center: CGPoint
        let radius: CGFloat
        /// Prostokąt etykiety wpisany w bąbel; nil = bąbel zbyt mały (nazwa tylko w podpowiedzi i na liście).
        let labelRect: CGRect?
    }

    static let minLabelRadius: CGFloat = 38

    /// - Returns: pozycje w układzie kontenera oraz promień okręgu opisanego na całości (w punktach).
    static func place(_ circles: [PackedCircle], in size: CGSize, padding: CGFloat = 6) -> (placed: [Placed], enclosingRadius: CGFloat) {
        guard !circles.isEmpty, size.width > 0, size.height > 0 else { return ([], 0) }
        let enc = CirclePacking.enclosing(circles)
        let side = max(1, min(size.width, size.height) - 2 * padding)
        let scale = enc.r > 0 ? side / 2 / CGFloat(enc.r) : 1
        let origin = CGPoint(x: size.width / 2, y: size.height / 2)
        let placed = circles.map { c -> Placed in
            let center = CGPoint(x: origin.x + CGFloat(c.x - enc.x) * scale, y: origin.y + CGFloat(c.y - enc.y) * scale)
            let r = CGFloat(c.r) * scale
            return Placed(center: center, radius: r, labelRect: r >= minLabelRadius ? labelRect(center: center, radius: r) : nil)
        }
        return (placed, CGFloat(enc.r) * scale)
    }

    /// Prostokąt 2-liniowy wpisany w okrąg z zapasem (przekątna ≤ 0,92·średnica).
    static func labelRect(center: CGPoint, radius r: CGFloat) -> CGRect {
        let w = r * 1.5
        let h = min(r * 1.0, 34)
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }
}
