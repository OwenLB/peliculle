import Foundation
import UniformTypeIdentifiers

/// Parcourt **récursivement** un dossier (F1) et renvoie les URLs des images
/// supportées, triées par nom de fichier (ordre déterministe, pas de lecture
/// EXIF). Lecture seule : aucune écriture n'est jamais effectuée.
enum FolderScanner {

    static func scan(_ root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            // Une seule lecture des propriétés (préfetchées par
            // l'énumérateur) : type et nature de fichier ensemble —
            // l'aller-retour par fichier comptait sur une grosse carte.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
                  values.isRegularFile == true,
                  SupportedFormats.isSupported(values.contentType) else { continue }
            urls.append(url)
        }

        return urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
