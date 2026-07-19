import CoreLocation
import MapKit

/// Jalon 8 (bonus GPS) — géocodage inverse avec cache par « case » d'environ
/// 1 km : toutes les photos d'un même lieu ne coûtent qu'**une** requête
/// (entorse réseau assumée, voir ROADMAP §Jalon 8). Les requêtes sont
/// **sérialisées** (politesse envers le service, même esprit que l'ancien
/// CLGeocoder mono-requête) et les échecs sont mémorisés pour ne pas
/// retenter en boucle hors connexion.
///
/// SDK 26 : `MKReverseGeocodingRequest` (MapKit) remplace `CLGeocoder`,
/// déprécié. Une requête = un objet jetable ; `cityName` / `regionName`
/// tiennent lieu de `locality` / région-pays du placemark.
actor PlaceResolver {
    static let shared = PlaceResolver()

    /// `nil` en valeur = résolution tentée et échouée (on ne retente pas).
    private var cache: [String: String?] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]
    /// Queue de sérialisation : chaque requête attend la précédente.
    private var chain: Task<String?, Never>?

    /// Nom court du lieu (ville, à défaut région/pays), ou nil sans réseau /
    /// en pleine mer.
    func place(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "%.2f|%.2f", latitude, longitude)
        if let cached = cache[key] { return cached }
        if let pending = inFlight[key] { return await pending.value }

        let previous = chain
        let task = Task { () -> String? in
            _ = await previous?.value
            let location = CLLocation(latitude: latitude, longitude: longitude)
            guard let request = MKReverseGeocodingRequest(location: location) else {
                return nil
            }
            let item = (try? await request.mapItems)?.first
            return item?.addressRepresentations?.cityName
                ?? item?.addressRepresentations?.regionName
        }
        chain = task
        inFlight[key] = task
        let name = await task.value
        inFlight[key] = nil
        cache[key] = name
        return name
    }
}
