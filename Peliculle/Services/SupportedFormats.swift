import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// F7 — support multi-format **dynamique** : la liste des formats lisibles est
/// dérivée du système (`CGImageSourceCopyTypeIdentifiers`), jamais codée en dur.
/// Ainsi tout RAW que l'OS sait décoder est pris en charge sans maintenance.
/// Idée 18 (batch G3) : même principe pour la **vidéo** — les types que
/// AVFoundation déclare savoir lire (MOV, MP4, M4V…).
enum SupportedFormats {

    /// Types image que le système déclare savoir lire (JPEG, HEIC, PNG, TIFF,
    /// et les RAW reconnus : CR2, CR3, NEF, ARW, RAF, DNG, ORF, RW2…).
    static let readableTypes: [UTType] = {
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.compactMap { UTType($0) }
    }()

    /// Types **vidéo** lisibles par AVFoundation (l'audio pur est écarté :
    /// une carte d'appareil photo n'en contient pas, et l'app trie des
    /// images animées, pas des sons).
    static let readableVideoTypes: [UTType] = {
        AVURLAsset.audiovisualTypes()
            .compactMap { UTType($0.rawValue) }
            .filter { $0.conforms(to: .movie) }
    }()

    /// Un type uniforme est supporté s'il se conforme à un type lisible —
    /// image ou vidéo. nil (type illisible) = non supporté.
    static func isSupported(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return readableTypes.contains { type.conforms(to: $0) }
            || readableVideoTypes.contains { type.conforms(to: $0) }
    }

    /// Variante URL — lit le type du fichier ; préférer la variante type
    /// quand les propriétés sont déjà préfetchées (`FolderScanner`).
    static func isSupported(_ url: URL) -> Bool {
        isSupported(try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
    }
}
