import SwiftUI

extension Binding where Value == Bool {
    /// Présence d'une valeur optionnelle sous forme de booléen — le patron
    /// des `alert`/`sheet` pilotées par un état optionnel : vrai tant que la
    /// valeur est là, la fermeture (`false`) la remet à nil.
    /// `Wrapped: Sendable` : les closures d'un `Binding(get:set:)` sont
    /// `@Sendable`, le binding source doit pouvoir les accompagner.
    init<Wrapped: Sendable>(isPresenting source: Binding<Wrapped?>) {
        self.init(
            get: { source.wrappedValue != nil },
            set: { if !$0 { source.wrappedValue = nil } }
        )
    }
}
