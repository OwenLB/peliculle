import Foundation

/// Patron commun des « listes récentes » persistées en JSON dans
/// `UserDefaults` — albums (`RecentAlbum`), dossiers (`RecentFolder`),
/// voyages (`SavedTrip`) : décodage tolérant (liste vide en cas d'échec),
/// dédoublonnage par `id`, insertion en tête, liste bornée, encodage.
/// Chaque type reste la façade (`RecentAlbum.load()`…), seul le patron est
/// mutualisé.
enum RecentList {
    static func load<Element: Decodable>(key: String) -> [Element] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Element].self, from: data) else {
            return []
        }
        return list
    }

    static func save<Element: Encodable>(_ list: [Element], key: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Remonte `entry` en tête (dédoublonnée par `id`), borne la liste à
    /// `limit` et la persiste.
    static func record<Element: Codable & Identifiable>(
        _ entry: Element, in list: inout [Element], key: String, limit: Int
    ) {
        list.removeAll { $0.id == entry.id }
        list.insert(entry, at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        save(list, key: key)
    }

    /// Retire l'entrée d'`id` donné et persiste — symétrique de `record`, pour
    /// les listes « récents » que l'utilisateur peut nettoyer à la main
    /// (accueil « Reprendre », hub Sources). No-op si l'`id` est absent.
    static func remove<Element: Codable & Identifiable>(
        id: Element.ID, from list: inout [Element], key: String
    ) {
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return }
        save(list, key: key)
    }
}
