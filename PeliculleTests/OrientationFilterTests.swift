import Foundation
import Testing
@testable import Peliculle

struct OrientationFilterTests {

    @Test func orientationDérivéeDesDimensions() {
        var landscape = PhotoExif()
        landscape.pixelWidth = 6_000
        landscape.pixelHeight = 4_000
        #expect(landscape.orientation == .landscape)

        var portrait = PhotoExif()
        portrait.pixelWidth = 4_000
        portrait.pixelHeight = 6_000
        #expect(portrait.orientation == .portrait)

        // Carré → paysage (largeur ≥ hauteur), convention assumée.
        var square = PhotoExif()
        square.pixelWidth = 1_000
        square.pixelHeight = 1_000
        #expect(square.orientation == .landscape)

        // Dimensions inconnues → orientation indéterminée.
        #expect(PhotoExif().orientation == nil)
    }

    @Test func filtreMatcheSelonOrientation() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let portrait = try Fixtures.photo(named: "PORTRAIT.jpg", in: folder, size: 10)
        var exif = PhotoExif()
        exif.pixelWidth = 4_000
        exif.pixelHeight = 6_000
        portrait.exif = exif

        #expect(OrientationFilter.all.matches(portrait))
        #expect(OrientationFilter.portrait.matches(portrait))
        #expect(OrientationFilter.landscape.matches(portrait) == false)

        // Non indexée (dimensions inconnues) → ne matche que « Toutes ».
        let bare = try Fixtures.photo(named: "BARE.jpg", in: folder, size: 10)
        #expect(OrientationFilter.all.matches(bare))
        #expect(OrientationFilter.portrait.matches(bare) == false)
        #expect(OrientationFilter.landscape.matches(bare) == false)
    }
}
