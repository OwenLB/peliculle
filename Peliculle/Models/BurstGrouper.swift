import Foundation

/// Idée 3 — groupement de rafales en **piles** : toute photo prise à moins de
/// `threshold` secondes de la précédente rejoint sa pile (chaînage : une
/// rafale de 3 s à 10 i/s reste une seule pile). Basé sur la date de fichier,
/// déjà lue au scan — aucune lecture EXIF. Une pile = 2 photos ou plus.
enum BurstGrouper {

    /// Une position d'une liste repliée : photo isolée, ou pile **entière**
    /// émise une seule fois, à la place de son premier membre rencontré
    /// (`anchor` — la grille en fait sa couverture de repli).
    enum Entry {
        case single(PhotoItem)
        case stack(members: [PhotoItem], anchor: PhotoItem)
    }

    /// Replie une liste **ordonnée** en entrées, en préservant son ordre.
    /// `among` = la population sur laquelle les piles sont détectées (la
    /// session complète pour la grille : une pile ne se dissout pas quand un
    /// filtre en masque des membres) ; par défaut, la liste elle-même.
    /// Partagé par la grille (`GridEntry`) et le Tri rapide (`Card`).
    static func entries(
        in ordered: [PhotoItem],
        among population: [PhotoItem]? = nil,
        threshold: TimeInterval
    ) -> [Entry] {
        guard threshold > 0 else { return ordered.map { .single($0) } }
        let stacks = stacks(in: population ?? ordered, threshold: threshold)
        var stackIndexByItem: [PhotoItem.ID: Int] = [:]
        for (index, stack) in stacks.enumerated() {
            for item in stack { stackIndexByItem[item.id] = index }
        }

        var seen = Set<Int>()
        var entries: [Entry] = []
        for item in ordered {
            guard let index = stackIndexByItem[item.id] else {
                entries.append(.single(item))
                continue
            }
            guard !seen.contains(index) else { continue }
            seen.insert(index)
            entries.append(.stack(members: stacks[index], anchor: item))
        }
        return entries
    }

    static func stacks(in items: [PhotoItem], threshold: TimeInterval) -> [[PhotoItem]] {
        guard threshold > 0 else { return [] }
        // Idée 18 — les vidéos ne font pas des rafales : un clip démarré à
        // la seconde d'une photo n'a rien d'une pile à départager.
        let dated = items
            .filter { $0.fileDate != nil && !$0.isVideo }
            .sorted { $0.fileDate! < $1.fileDate! }

        var result: [[PhotoItem]] = []
        var current: [PhotoItem] = []
        for item in dated {
            if let last = current.last?.fileDate,
               item.fileDate!.timeIntervalSince(last) <= threshold {
                current.append(item)
            } else {
                if current.count >= 2 { result.append(current) }
                current = [item]
            }
        }
        if current.count >= 2 { result.append(current) }
        return result
    }
}
