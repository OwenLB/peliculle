import Foundation
import Testing
@testable import Peliculle

struct TripModeTests {

    private let calendar = Calendar.current
    /// Un jour fixe, à midi (évite tout aléa de bord de journée).
    private var day: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 12))!
    }

    private func trip(start: Date, end: Date?) -> TripMode {
        TripMode(isActive: true, name: "Test", startDate: start, endDate: end)
    }

    @Test func inactifLaisseToutPasser() {
        var mode = TripMode()
        mode.isActive = false
        #expect(mode.matches(nil))
        #expect(mode.matches(.distantPast))
        #expect(mode.matches(.distantFuture))
    }

    @Test func actifExclutLesPhotosSansDate() {
        #expect(!trip(start: day, end: nil).matches(nil))
    }

    @Test func bornesIncluses() {
        let end = calendar.date(byAdding: .day, value: 2, to: day)!
        let mode = trip(start: day, end: end)

        // Premier jour à 00:00 : dedans (la borne de début est au jour).
        #expect(mode.matches(calendar.startOfDay(for: day)))
        // Veille : dehors.
        #expect(!mode.matches(calendar.date(byAdding: .day, value: -1, to: day)!))
        // Dernier jour en toute fin de journée : dedans (borne incluse).
        let lastEvening = calendar.date(
            bySettingHour: 23, minute: 59, second: 0,
            of: calendar.startOfDay(for: end)
        )!
        #expect(mode.matches(lastEvening))
        // Lendemain de la fin à 00:00 : dehors.
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        #expect(!mode.matches(dayAfter))
    }

    @Test func finOuverteResteEnCours() {
        let mode = trip(start: day, end: nil)
        #expect(mode.matches(day))
        #expect(mode.matches(.distantFuture))
        #expect(!mode.matches(.distantPast))
    }
}
