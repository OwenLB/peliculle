import Foundation

/// Idée 20 (batch G1) — pré-vol d'enregistrement : annoncer le **poids du
/// lot** et vérifier l'**espace libre** de l'iPhone avant de lancer le batch,
/// plutôt que d'échouer à mi-course sur un téléphone plein. Best effort :
/// sans poids connu (assets photothèque : garder = ajout à l'album, aucune
/// copie) ou sans mesure d'espace, on laisse passer — le batch signale déjà
/// ses échecs un par un.
enum SavePreflight {

    /// Poids total des fichiers à copier, `nil` quand aucun poids n'est
    /// connu — on n'affiche rien plutôt que « zéro octet ».
    static func totalBytes(of items: [PhotoItem]) -> Int64? {
        var total: Int64 = 0
        var known = false
        for item in items {
            guard case .file = item.backing, let size = item.fileSize else { continue }
            total += Int64(size)
            known = true
        }
        return known ? total : nil
    }

    /// « 2,3 Go », prêt pour le CTA de confirmation d'enregistrement.
    static func formattedTotal(of items: [PhotoItem]) -> String? {
        totalBytes(of: items).map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
    }

    /// Espace réellement mobilisable (`importantUsage` : le système purge
    /// ses caches pour l'atteindre), `nil` si la mesure échoue.
    static func availableBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Message d'alerte prêt à afficher si l'espace ne suffit pas, `nil`
    /// quand le lot peut partir.
    static func insufficientSpaceMessage(for items: [PhotoItem]) -> String? {
        guard let needed = totalBytes(of: items),
              let available = availableBytes(),
              needed > available else { return nil }
        let neededText = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
        let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        return String(localized: "Espace insuffisant sur l'iPhone : \(neededText) à enregistrer, \(availableText) disponibles. Libérez de l'espace puis réessayez — rien n'a été enregistré.")
    }
}
