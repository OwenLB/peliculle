import Foundation
import Testing
@testable import Peliculle

struct AlbumDestinationTests {

    private var today: String {
        Date.now.formatted(date: .abbreviated, time: .omitted)
    }

    @Test func modeDatéParDéfaut() {
        let destination = AlbumDestination()
        #expect(destination.mode == .dated)
        #expect(destination.resolvedTitle == "Peliculle — \(today)")
    }

    @Test func modePeliculleAlbumUnique() {
        var destination = AlbumDestination()
        destination.mode = .peliculle
        #expect(destination.resolvedTitle == "Peliculle")
    }

    @Test func modeNommé() {
        var destination = AlbumDestination()
        destination.mode = .named
        destination.customName = "  Portugal  "
        // Espaces rognés, pas de date sans l'option.
        #expect(destination.resolvedTitle == "Portugal")

        destination.appendDate = true
        #expect(destination.resolvedTitle == "Portugal — \(today)")
    }

    @Test func nomVideRetombeSurLeDaté() {
        var destination = AlbumDestination()
        destination.mode = .named
        destination.customName = "   "
        // Jamais d'album sans titre : repli sur le daté.
        #expect(destination.resolvedTitle == "Peliculle — \(today)")
    }

    @Test func modeAucunSansAlbum() {
        var destination = AlbumDestination()
        destination.mode = AlbumDestination.Mode.none
        #expect(destination.resolvedTitle == nil)
    }
}
