import MapKit
import SwiftUI

/// F9 — panneau d'informations de la photo courante, en **overlay** en bas du
/// viewer plutôt qu'en sheet UIKit : le panneau épouse la hauteur de son
/// contenu (pas d'espace vide sous les métadonnées), et quitter le viewer est
/// instantané (pas de présentation modale à défaire avant le pop). On continue
/// à parcourir les photos pendant qu'il est ouvert ; fiche façon drawer —
/// poignée en tête, glisser vers le bas (suit le doigt) pour fermer. Suit la
/// photo affichée et recharge ses métadonnées paresseusement.
///
/// Note d'implémentation : le `.task(id:)` est attaché à un conteneur
/// **toujours présent**. Attaché à une vue au contenu conditionnel vide, il ne
/// se déclencherait jamais tant que les métadonnées sont nulles.
struct ExifSheet: View {
    let item: PhotoItem
    var onClose: () -> Void

    @State private var metadata: PhotoMetadata?
    /// Suivi du doigt pendant le glisser-pour-fermer (sensation de drawer).
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            grabber
            header

            if let metadata {
                if metadata.isEmpty {
                    Text("Aucune donnée de prise de vue")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    exifContent(metadata)
                }
                analysisInfo
                locationInfo
                fileInfo(metadata)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .offset(y: max(0, dragOffset))
        .task(id: item.id) {
            // Fiche progressive : d'abord ce que l'index connaît déjà (zéro
            // I/O — plus de spinner à chaque page), puis la lecture complète
            // (vitesse, dimensions ; sur un asset, elle peut télécharger
            // l'original iCloud) vient enrichir.
            metadata = ExifReader.preliminary(from: item)
            metadata = await ExifReader.read(item.backing)
            // Esthétique (Jalon 7) calculée **à la demande**, ici : plus de
            // passe Vision par cellule au scroll (seul consommateur restant :
            // cette fiche et le tri esthétique de session). Pas sur une vidéo.
            if item.analysis == nil, !item.isVideo {
                item.analysis = await VisionAnalyzer.shared.analysis(for: item.backing)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    if value.translation.height > 60 {
                        onClose()
                    }
                    dragOffset = 0
                }
        )
        .animation(.snappy(duration: 0.2), value: dragOffset == 0)
    }

    /// Poignée de drawer : signale que la fiche se tire vers le bas.
    private var grabber: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(item.filename)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // Extension inconnue pour un asset photothèque (Jalon 10) : pas
            // de capsule vide.
            if !item.formatExtension.isEmpty {
                Text(item.formatExtension)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
        }
    }

    private func exifContent(_ meta: PhotoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let settings = [meta.aperture, meta.shutter, meta.iso, meta.focalLength]
                .compactMap { $0 }
            if !settings.isEmpty {
                HStack(spacing: 8) {
                    ForEach(settings, id: \.self) { value in
                        Text(value)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: .capsule)
                    }
                }
            }

            if let camera = meta.camera {
                row("camera", camera)
            }
            if let lens = meta.lens {
                row("camera.aperture", lens)
            }
            if let date = meta.dateText {
                row("calendar", date)
            }
            // Idée 18 — la fiche d'un clip : sa durée (l'EXIF image, lui,
            // est naturellement vide).
            if item.isVideo, let duration = item.videoDuration {
                row("video", VideoInfo.formattedDuration(duration))
            }
        }
    }

    /// Signaux d'analyse (Jalon 7), volet **informatif** : score esthétique
    /// 0–1 (Vision). Pur indicateur — ne déclenche aucune décision. Rien tant
    /// que la photo n'est pas analysée (le viewer déclenche l'analyse de la
    /// photo courante).
    @ViewBuilder
    private var analysisInfo: some View {
        if let analysis = item.analysis {
            let parts: [String] = [
                analysis.aestheticScore.map {
                    String(format: String(localized: "Esthétique %.2f"), $0)
                },
            ].compactMap { $0 }
            if !parts.isEmpty {
                row("sparkles", parts.joined(separator: " · "))
            }
        }
    }

    /// Lieu + mini-carte (Jalon 8, bonus GPS) — seulement si la photo a des
    /// coordonnées ; la plupart des reflex n'en écrivent pas, la fiche reste
    /// alors identique. Le nom du lieu est résolu par le viewer
    /// (`PlaceResolver`) ; en attendant, un libellé générique.
    @ViewBuilder
    private var locationInfo: some View {
        if let exif = item.exif,
           let latitude = exif.latitude, let longitude = exif.longitude {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            VStack(alignment: .leading, spacing: 8) {
                row("mappin.and.ellipse", item.place ?? String(localized: "Position GPS"))
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 2500,
                    longitudinalMeters: 2500
                ))) {
                    Marker(item.place ?? "", coordinate: coordinate)
                }
                .frame(height: 110)
                .clipShape(.rect(cornerRadius: 12))
                .allowsHitTesting(false)
                // La carte ne suit pas un binding de position : on la recrée
                // quand la photo change pour recadrer sur le nouveau point.
                .id(item.id)
            }
        }
    }

    @ViewBuilder
    private func fileInfo(_ meta: PhotoMetadata) -> some View {
        let parts = [meta.dimensions, meta.fileSize].compactMap { $0 }
        // Orientation à côté de la résolution : icône + libellé (portrait /
        // paysage) — repli sur l'orientation indexée de l'item si la lecture
        // fichier ne l'a pas fournie.
        let orientation = meta.orientation ?? item.orientation
        if !parts.isEmpty || orientation != nil {
            HStack(spacing: 8) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let orientation {
                    Label(orientation.label, systemImage: orientation.icon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: .capsule)
                }
            }
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
