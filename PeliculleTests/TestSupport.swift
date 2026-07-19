import Foundation
@testable import Peliculle

/// Fabrique de photos de test : `PhotoItem` lit ses métadonnées (type, date,
/// taille) sur disque à l'init → on crée de **vrais fichiers temporaires**,
/// avec date de modification et taille contrôlées.
enum Fixtures {

    /// Dossier temporaire isolé — à supprimer par l'appelant (`defer`).
    static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeliculleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Crée un fichier de `size` octets nommé `name` (l'extension pilote le
    /// `contentType` : .jpg = image, .mov = vidéo) et renvoie son `PhotoItem`.
    @discardableResult
    static func photo(
        named name: String,
        in folder: URL,
        date: Date? = nil,
        size: Int = 4
    ) throws -> PhotoItem {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: size).write(to: url)
        if let date {
            try FileManager.default.setAttributes(
                [.modificationDate: date], ofItemAtPath: url.path
            )
        }
        return PhotoItem(url: url)
    }
}
