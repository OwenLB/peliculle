import AVKit
import SwiftUI

/// Image plein écran d'une photo (F3), zoomable (F4). Affiche d'abord le preview
/// embarqué / un downsampling ≈2048 px (quasi instantané, même sur RAW), puis
/// charge la **pleine résolution à la demande** au premier zoom pour vérifier
/// le piqué. Remonte l'état de zoom (pour masquer les barres) et le swipe vers
/// le haut (= garder).
///
/// Idée 18 — une **vidéo** remplace le duo zoom/pleine résolution par un
/// lecteur natif (`VideoPlayer`, contrôles système, son coupé par défaut) ;
/// la pagination, le tri et la fermeture du viewer sont inchangés.
struct PhotoDetailImage: View {
    let item: PhotoItem
    /// Hors plein écran, la photo se présente comme une **carte** : la vue
    /// épouse le ratio de l'image (via `aspectRatio`) pour que l'arrondi porte
    /// sur la photo elle-même, pas sur le cadre plein écran letterboxé.
    var framed = false
    var cornerRadius: CGFloat = 0
    /// Hauteur de la pilule d'en-tête qui **flotte** sur la zone photo : la
    /// carte se centre dans la zone libre sous la pilule tant qu'elle y tient,
    /// et ne déborde derrière que si elle y gagne de la hauteur (portrait).
    var topInset: CGFloat = 0
    var onZoomChange: (Bool) -> Void
    /// Tap simple sur la photo : le viewer bascule le HUD (chrome). On en
    /// profite pour charger la pleine résolution — l'utilisateur inspecte la
    /// photo plein écran, autant lui servir le vrai piqué.
    var onSingleTap: () -> Void
    var onSwipeUp: () -> Void

    @State private var preview: UIImage?
    @State private var fullRes: UIImage?
    @State private var isLoadingFull = false
    @State private var didRequestFull = false

    private let previewPixels = 2048

    var body: some View {
        if item.isVideo, let url = item.url {
            VideoDetailPage(url: url)
                // Même traitement que les photos : la vue du lecteur épouse le
                // format **exact** du clip — plus aucun letterbox interne (les
                // bandes noires AVKit, choquantes en mode clair), les contrôles
                // se posent sur la vidéo. Deux différences volontaires :
                // arrondi à 0 (la barre AVKit s'étend jusqu'aux bords de la
                // vue, un coin arrondi la rognerait) et carte plafonnée à la
                // zone **sous** la pilule (jamais derrière — les boutons
                // muet/AirPlay du haut resteraient inaccessibles à l'œil).
                .modifier(FramedPhoto(
                    framed: framed,
                    aspect: item.videoAspect,
                    cornerRadius: 0,
                    topInset: topInset,
                    fitsBelowInset: true
                ))
                .task(id: item.id) {
                    if item.videoAspect == nil {
                        item.videoAspect = await VideoInfo.aspectRatio(of: url)
                    }
                }
        } else {
            photoBody
        }
    }

    /// Ratio largeur/hauteur de l'image chargée (nil tant que rien n'est
    /// disponible) — sert à dimensionner la carte pour qu'elle épouse la photo.
    private var imageAspect: CGFloat? {
        guard let size = (fullRes ?? preview)?.size, size.width > 0, size.height > 0 else {
            return nil
        }
        return size.width / size.height
    }

    private var photoBody: some View {
        ZStack {
            ZoomableImageView(
                image: fullRes ?? preview,
                onZoomChange: { zoomed in
                    onZoomChange(zoomed)
                    if zoomed { requestFullResolution() }
                },
                onSingleTap: {
                    requestFullResolution()
                    onSingleTap()
                },
                onSwipeUp: onSwipeUp
            )

            if preview == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if isLoadingFull {
                loadingBadge
            }
        }
        .modifier(FramedPhoto(
            framed: framed,
            aspect: imageAspect,
            cornerRadius: cornerRadius,
            topInset: topInset
        ))
        .task(id: item.id) {
            preview = await ThumbnailLoader.load(item: item, maxPixel: previewPixels)
        }
    }

    /// Badge en haut de l'écran, sous la Dynamic Island : cette zone est libre
    /// pendant le zoom (barres masquées), contrairement au bas où vit la
    /// pastille « Trier ». Fond noir opaque plutôt que glass : lisible quelle
    /// que soit la photo derrière.
    private var loadingBadge: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Pleine résolution…")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.75), in: .capsule)
            .padding(.top, 72)
            Spacer()
        }
    }

    private func requestFullResolution() {
        guard !didRequestFull else { return }
        didRequestFull = true
        isLoadingFull = true
        Task {
            let image = await FullResLoader.load(item: item)
            fullRes = image
            isLoadingFull = false
        }
    }
}

/// Carte photo hors plein écran : contraint la vue au ratio de l'image et
/// arrondit ses coins. Sans image encore chargée (`aspect` nil) ou en plein
/// écran (`framed` faux), la photo reste bord à bord comme avant.
///
/// Deux invariants, tous deux nécessaires pour ne pas bloquer le snap du
/// pager « entre deux » pendant qu'une page voisine charge en plein swipe :
/// - **taille externe stable** : le `GeometryReader` occupe toujours tout
///   l'espace proposé, la page du `TabView` ne change jamais de taille ;
/// - **structure stable** : pas de branche `if` autour du contenu — un
///   changement de branche (ratio qui arrive, bascule du cadre) recréait le
///   sous-arbre, donc la `ZoomableImageView` UIKit, en plein défilement.
///   Seules des **valeurs** changent (taille de carte, rayon d'arrondi).
private struct FramedPhoto: ViewModifier {
    let framed: Bool
    let aspect: CGFloat?
    let cornerRadius: CGFloat
    var topInset: CGFloat = 0
    /// Vrai pour une vidéo : la carte reste **toujours** dans la zone libre
    /// sous la pilule, jamais derrière — les boutons AVKit du haut du lecteur
    /// (muet, AirPlay) ne doivent pas se retrouver sous la pilule. Une photo,
    /// sans contrôle à recouvrir, garde le droit d'y glisser son haut.
    var fitsBelowInset = false

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let size = cardSize(in: geo.size)
            // Zone libre : sous la pilule flottante (`topInset`), au-dessus
            // des contrôles. Centrage **intelligent** : la carte se centre
            // dans la zone libre tant qu'elle y tient (un paysage ne se glisse
            // jamais inutilement sous la pilule) ; si elle a besoin de plus de
            // hauteur (portrait), elle se centre dans la zone entière et son
            // haut passe derrière le verre de la pilule, façon Photos.app.
            let clearHeight = geo.size.height - topInset
            let centerY = size.height <= clearHeight
                ? topInset + clearHeight / 2
                : geo.size.height / 2
            content
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(
                    cornerRadius: (framed && aspect != nil) ? cornerRadius : 0,
                    style: .continuous
                ))
                .position(x: geo.size.width / 2, y: centerY)
        }
    }

    /// Taille de la carte : l'image ajustée dans l'espace disponible (pilule
    /// comprise, sauf `fitsBelowInset`) moins la marge latérale (2 × 6 pt).
    /// Hors mode carte ou ratio inconnu, la page entière — bord à bord.
    private func cardSize(in available: CGSize) -> CGSize {
        let maxHeight = fitsBelowInset ? available.height - topInset : available.height
        guard framed, let aspect,
              available.width > 12, maxHeight > 0 else { return available }
        let width = min(available.width - 12, maxHeight * aspect)
        return CGSize(width: width, height: width / aspect)
    }
}

/// Idée 18 — page vidéo du viewer (et carte du Tri rapide) : lecteur natif,
/// **pas d'autoplay** (on branche une carte pleine de clips, pas un feed),
/// son suivant le dernier choix muet/son de la session (`VideoAudio`, coupé
/// au premier clip). Le lecteur est libéré dès que la page quitte l'écran —
/// le pager recycle ses pages, dix clips ne doivent jamais garder dix
/// pipelines AVPlayer ouverts.
private struct VideoDetailPage: View {
    let url: URL

    @State private var player: AVPlayer?
    /// KVO sur `isMuted` : chaque bascule du bouton muet AVKit met à jour la
    /// session audio et la mémoire du choix (`VideoAudio.muteChanged`).
    @State private var muteObservation: NSKeyValueObservation?

    var body: some View {
        ZStack {
            // Fond adaptatif clair/sombre, cohérent avec le viewer.
            Color(.systemBackground)
            if let player {
                NativeVideoPlayer(player: player)
            }
        }
        .onAppear {
            let player = AVPlayer(url: url)
            player.isMuted = !VideoAudio.soundOn
            // Observation posée **après** le réglage initial : elle ne
            // signale que les bascules de l'utilisateur.
            muteObservation = player.observe(\.isMuted, options: [.new]) { _, change in
                guard let isMuted = change.newValue else { return }
                Task { @MainActor in VideoAudio.muteChanged(isMuted: isMuted) }
            }
            self.player = player
        }
        .onDisappear {
            muteObservation = nil
            player?.pause()
            player = nil
        }
    }
}

/// Lecteur AVKit complet (`AVPlayerViewController`) à la place du
/// `VideoPlayer` SwiftUI : mêmes contrôles (progression, muet, AirPlay),
/// plus le **bouton plein écran** système — avec rotation paysage — que
/// `VideoPlayer` n'expose pas. Intégré dans la page ; AVKit présente et
/// referme lui-même son plein écran.
private struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        // Fond transparent : la vue est ajustée au format exact du clip (pas
        // de letterbox à couvrir), et le noir AVKit flasherait en mode clair
        // avant le premier rendu de la vidéo.
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
