import Foundation
import Testing
@testable import Peliculle

/// Persistance de la dernière source (`storageValue` / `fromStorage`) :
/// c'est elle qui restaure la session au lancement — un aller-retour raté
/// rouvre l'app sur l'accueil.
struct StorageValueTests {

    @Test func libraryScopeAllersRetours() {
        #expect(LibraryScope.fromStorage("library") == .all)
        #expect(LibraryScope.fromStorage(LibraryScope.all.storageValue) == .all)

        let days = LibraryScope.lastDays(30)
        #expect(LibraryScope.fromStorage(days.storageValue) == days)

        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let end = start.addingTimeInterval(86_400 * 6)
        let range = LibraryScope.range(start: start, end: end)
        #expect(LibraryScope.fromStorage(range.storageValue) == range)

        // Fin ouverte (voyage en cours) : le « - » redonne bien nil.
        let open = LibraryScope.range(start: start, end: nil)
        #expect(LibraryScope.fromStorage(open.storageValue) == open)
    }

    @Test func libraryScopeRejetteLesValeursInvalides() {
        #expect(LibraryScope.fromStorage("") == nil)
        #expect(LibraryScope.fromStorage("folder") == nil)
        #expect(LibraryScope.fromStorage("album|x|y") == nil)
        #expect(LibraryScope.fromStorage("library|days|0") == nil)
        #expect(LibraryScope.fromStorage("library|days|abc") == nil)
        #expect(LibraryScope.fromStorage("library|range|abc|-") == nil)
        #expect(LibraryScope.fromStorage("library|inconnu|1") == nil)
    }

    @Test func bornesDeFetchDeLaPlage() {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 3, hour: 15))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 9))!

        let bounds = LibraryScope.range(start: start, end: end).fetchBounds
        // Début ramené à 00:00 ; fin **exclusive** au lendemain 00:00 (la
        // borne utilisateur est incluse jour entier).
        #expect(bounds.start == calendar.startOfDay(for: start))
        let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        #expect(bounds.end == dayAfterEnd)

        let openBounds = LibraryScope.range(start: start, end: nil).fetchBounds
        #expect(openBounds.end == nil)
        #expect(LibraryScope.all.fetchBounds.start == nil)
    }

    @Test func photoSourceAlbumAllersRetours() {
        let source = PhotoSource.album(id: "ABC-123", title: "Portugal")
        #expect(PhotoSource.fromStorage(source.storageValue) == source)

        // Un titre contenant le séparateur reste intact (découpe au premier |).
        let piped = PhotoSource.album(id: "ID", title: "Été | Portugal")
        #expect(PhotoSource.fromStorage(piped.storageValue) == piped)
    }

    @Test func photoSourceRejetteLesValeursInvalides() {
        // Un dossier ne se restaure jamais par cette voie (bookmark dédié).
        #expect(PhotoSource.fromStorage("folder") == nil)
        #expect(PhotoSource.fromStorage("album|") == nil)
        #expect(PhotoSource.fromStorage("album||Sans identifiant") == nil)
        #expect(PhotoSource.fromStorage("n'importe quoi") == nil)
    }

    @Test func photoSourceLibraryPasseParLeScope() {
        let scoped = PhotoSource.library(.lastDays(7))
        #expect(PhotoSource.fromStorage(scoped.storageValue) == scoped)
        #expect(PhotoSource.fromStorage("library") == .library(.all))
    }
}
