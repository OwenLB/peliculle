import AVFoundation

/// Son des clips du viewer. Deux responsabilités :
/// - la **session audio** : l'app ne la configure jamais au lancement (la
///   musique de l'utilisateur continue pendant le tri) ; elle passe en
///   `.playback` — la catégorie qui ignore le commutateur silencieux, comme
///   Photos.app — au moment où le son d'un clip est réactivé, et se désactive
///   quand il est recoupé (`notifyOthersOnDeactivation` : la musique
///   d'arrière-plan reprend).
/// - la **mémoire du choix** : son coupé par défaut au premier clip, puis le
///   dernier état muet/son suit d'un clip à l'autre pendant la session.
@MainActor
enum VideoAudio {

    /// Dernier choix de l'utilisateur (bouton muet AVKit), appliqué aux
    /// lecteurs suivants. Coupé par défaut : on ouvre une carte pleine de
    /// clips, pas un feed — jamais de son non sollicité.
    static var soundOn = false

    /// À appeler à chaque bascule muet/son d'un lecteur (KVO sur `isMuted`).
    static func muteChanged(isMuted: Bool) {
        soundOn = !isMuted
        let session = AVAudioSession.sharedInstance()
        if isMuted {
            // Désactiver une session jamais activée échoue : sans effet, ignoré.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
    }
}
