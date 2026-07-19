import SwiftUI
import TipKit

/// Idée 21 (batch G1) — onboarding gestuel : des tips contextuels **TipKit**
/// (framework système), découvrables et jamais bloquants — pas de tutoriel
/// plein écran. Chaque tip est ancré sur la surface qu'il explique et
/// s'invalide dès que le geste est accompli ; TipKit ne le remontre plus.
/// Remise à zéro possible dans ⚙️ (« Revoir les astuces »).
enum OnboardingTips {
    /// À appeler une fois au lancement — sans configuration, TipKit ne
    /// montre rien.
    static func configure() {
        try? Tips.configure()
    }

    /// « Revoir les astuces » : vide le datastore TipKit puis reconfigure,
    /// les tips redeviennent éligibles immédiatement.
    static func reset() {
        try? Tips.resetDatastore()
        try? Tips.configure()
    }
}

/// ① Le geste accélérateur du viewer. Ancré sur la barre de tri : elle
/// n'existe qu'en mode tri, là où le geste agit.
struct SwipeKeepTip: Tip {
    var title: Text { Text("Balayez vers le haut pour garder") }
    var message: Text? {
        Text("La photo est gardée et la suivante s'affiche. Les boutons restent toujours disponibles.")
    }
    var image: Image? { Image(systemName: "hand.draw") }

    var options: [Option] {
        MaxDisplayCount(3)
    }
}

/// ② La passe en lot, quand la grille contient un vrai travail de tri.
struct QuickCullTip: Tip {
    /// Nombre de photos affichées — en dessous de 20, le viewer suffit et le
    /// tip ferait du bruit.
    @Parameter static var photoCount: Int = 0

    var title: Text { Text("Essayez le Tri rapide") }
    var message: Text? {
        Text("Une carte par photo : balayez à droite pour garder, à gauche pour rejeter, vers le haut pour repasser plus tard.")
    }
    var image: Image? { Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled") }

    var options: [Option] {
        MaxDisplayCount(3)
    }

    var rules: [Rule] {
        #Rule(Self.$photoCount) { $0 >= 20 }
    }
}

/// ③ La bascule pleine résolution, montrée après le premier zoom manuel —
/// c'est là qu'on cherche à juger la netteté.
struct ZoomFullResTip: Tip {
    @Parameter static var hasZoomed: Bool = false

    var title: Text { Text("Double-tapez pour la pleine résolution") }
    var message: Text? {
        Text("Au zoom, l'image bascule en pleine résolution à la demande — le RAW est décodé pour juger la netteté.")
    }
    var image: Image? { Image(systemName: "plus.magnifyingglass") }

    var options: [Option] {
        MaxDisplayCount(3)
    }

    var rules: [Rule] {
        #Rule(Self.$hasZoomed) { $0 == true }
    }
}

/// ④ Les piles de rafales. Ancré sur la première pile affichée : pas de
/// pile, pas de tip.
struct BurstPileTip: Tip {
    var title: Text { Text("Ouvrez la pile pour élire la meilleure") }
    var message: Text? {
        Text("Les photos prises en rafale sont regroupées. « Élire » garde la photo affichée et rejette le reste ; « Duel » les départage.")
    }
    var image: Image? { Image(systemName: "square.stack") }

    var options: [Option] {
        MaxDisplayCount(3)
    }
}

/// Pose le tip ④ sur une cellule **seulement** quand elle est la première
/// pile — `popoverTip` ne prend pas de tip optionnel, d'où le modifier.
struct BurstTipAnchor: ViewModifier {
    let isFirstStack: Bool

    func body(content: Content) -> some View {
        if isFirstStack {
            content.popoverTip(BurstPileTip())
        } else {
            content
        }
    }
}
