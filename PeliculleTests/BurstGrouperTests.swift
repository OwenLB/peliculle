import Foundation
import Testing
@testable import Peliculle

struct BurstGrouperTests {

    private let epoch = Date(timeIntervalSinceReferenceDate: 700_000_000)

    @Test func photosProchesChaînentEnUneSeulePile() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // 0 s, 0,5 s, 1,0 s : chaque écart ≤ 1 s → une seule pile de 3,
        // même si le premier et le dernier sont à 1 s d'écart (chaînage).
        let a = try Fixtures.photo(named: "IMG_0001.jpg", in: folder, date: epoch)
        let b = try Fixtures.photo(named: "IMG_0002.jpg", in: folder, date: epoch.addingTimeInterval(0.5))
        let c = try Fixtures.photo(named: "IMG_0003.jpg", in: folder, date: epoch.addingTimeInterval(1.0))
        // 5 s : hors seuil, isolée → pas de pile pour elle.
        let d = try Fixtures.photo(named: "IMG_0004.jpg", in: folder, date: epoch.addingTimeInterval(5))

        let stacks = BurstGrouper.stacks(in: [d, c, a, b], threshold: 1)

        #expect(stacks.count == 1)
        #expect(stacks[0] == [a, b, c])
    }

    @Test func seuilNulDésactiveLeGroupement() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try Fixtures.photo(named: "IMG_0001.jpg", in: folder, date: epoch)
        let b = try Fixtures.photo(named: "IMG_0002.jpg", in: folder, date: epoch)

        #expect(BurstGrouper.stacks(in: [a, b], threshold: 0).isEmpty)
    }

    @Test func lesVidéosNeFontPasDesRafales() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try Fixtures.photo(named: "IMG_0001.jpg", in: folder, date: epoch)
        let clip = try Fixtures.photo(named: "MVI_0002.mov", in: folder, date: epoch.addingTimeInterval(0.2))
        let b = try Fixtures.photo(named: "IMG_0003.jpg", in: folder, date: epoch.addingTimeInterval(0.4))

        #expect(clip.isVideo)
        let stacks = BurstGrouper.stacks(in: [a, clip, b], threshold: 1)
        // Le clip est écarté ; les deux photos restent à 0,4 s → une pile.
        #expect(stacks == [[a, b]])
    }

    @Test func entriesPréserventLOrdreEtÉmettentLaPileUneFois() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try Fixtures.photo(named: "IMG_0001.jpg", in: folder, date: epoch)
        let b = try Fixtures.photo(named: "IMG_0002.jpg", in: folder, date: epoch.addingTimeInterval(0.5))
        let c = try Fixtures.photo(named: "IMG_0003.jpg", in: folder, date: epoch.addingTimeInterval(60))

        // Ordre d'affichage inversé (tri décroissant) : c, b, a.
        let entries = BurstGrouper.entries(in: [c, b, a], threshold: 1)

        #expect(entries.count == 2)
        guard case .single(let single) = entries[0] else {
            Issue.record("attendu .single en tête") ; return
        }
        #expect(single == c)
        guard case .stack(let members, let anchor) = entries[1] else {
            Issue.record("attendu .stack en seconde position") ; return
        }
        // Membres dans l'ordre chronologique de la pile, ancre = premier
        // membre rencontré dans l'ordre d'affichage (b).
        #expect(members == [a, b])
        #expect(anchor == b)
    }

    @Test func amongDétecteLesPilesSurLaPopulationEntière() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try Fixtures.photo(named: "IMG_0001.jpg", in: folder, date: epoch)
        let b = try Fixtures.photo(named: "IMG_0002.jpg", in: folder, date: epoch.addingTimeInterval(0.5))

        // Un filtre masque b : la pile ne se dissout pas pour autant.
        let filtered = BurstGrouper.entries(in: [a], among: [a, b], threshold: 1)
        guard case .stack(let members, let anchor) = filtered.first else {
            Issue.record("attendu une pile complète malgré le filtre") ; return
        }
        #expect(members == [a, b])
        #expect(anchor == a)

        // Sans population élargie, a est seule → pas de pile.
        let alone = BurstGrouper.entries(in: [a], threshold: 1)
        guard case .single = alone.first else {
            Issue.record("attendu .single sans population élargie") ; return
        }
    }
}
