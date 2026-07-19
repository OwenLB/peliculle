/**
 * Animations GSAP de la page.
 * Tout est en `gsap.from(...)` : sans JavaScript (ou en reduced-motion),
 * le contenu reste parfaitement visible.
 */
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';

export function initAnimations() {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  gsap.registerPlugin(ScrollTrigger);

  heroIntro();
  scrollReveals();
  swipeDemo();
  wordmarkPlay();
}

/* --- Entrée du hero ------------------------------------------------------ */

function heroIntro() {
  const tl = gsap.timeline({ defaults: { ease: 'power3.out' } });

  tl.from('[data-hero-line]', {
    yPercent: 110,
    opacity: 0,
    duration: 0.9,
    stagger: 0.12,
  })
    .from(
      '[data-hero-item]',
      {
        y: 24,
        opacity: 0,
        duration: 0.7,
        stagger: 0.1,
      },
      '-=0.5'
    )
    .from(
      '[data-hero-phone]',
      {
        y: 60,
        opacity: 0,
        duration: 1.1,
        ease: 'power2.out',
      },
      '-=0.9'
    )
    .from(
      '[data-hero-chip]',
      {
        y: 18,
        opacity: 0,
        scale: 0.85,
        duration: 0.6,
        ease: 'back.out(1.8)',
        stagger: 0.12,
      },
      '-=0.5'
    )
    .from(
      '[data-hero-paren]',
      {
        scale: 1.6,
        opacity: 0,
        duration: 1.2,
        ease: 'power2.out',
        stagger: 0.08,
      },
      '-=0.9'
    );

  // Les parenthèses « respirent » doucement autour de la carte
  gsap.to('.hero-paren--open', {
    x: -14,
    duration: 3.2,
    ease: 'sine.inOut',
    yoyo: true,
    repeat: -1,
  });
  gsap.to('.hero-paren--close', {
    x: 14,
    duration: 3.2,
    ease: 'sine.inOut',
    yoyo: true,
    repeat: -1,
  });
}

/* --- Révélations au scroll ------------------------------------------------ */

function scrollReveals() {
  document.querySelectorAll('[data-reveal]').forEach((element) => {
    gsap.from(element, {
      y: 32,
      opacity: 0,
      duration: 0.85,
      ease: 'power3.out',
      scrollTrigger: { trigger: element, start: 'top 82%' },
    });
  });

  document.querySelectorAll('[data-reveal-group]').forEach((group) => {
    gsap.from(group.children, {
      y: 32,
      opacity: 0,
      duration: 0.75,
      ease: 'power3.out',
      stagger: 0.09,
      scrollTrigger: { trigger: group, start: 'top 82%' },
    });
  });
}

/* --- Démo « Tri rapide » : la pile de photos triée en boucle infinie ------ */

function swipeDemo() {
  const deck = document.querySelector('[data-swipe-deck]');
  if (!deck) return;

  const cards = Array.from(deck.querySelectorAll('[data-swipe-card]'));
  if (!cards.length) return;

  // Compteur en direct sous le téléphone : incrémenté à chaque carte triée.
  // Le titre « N à trier » de la maquette décompte, puis repart d'en haut
  // quand la pile a bouclé — comme une nouvelle session.
  const keptEl = document.querySelector('[data-swipe-kept]');
  const rejectedEl = document.querySelector('[data-swipe-rejected]');
  const remainingEl = document.querySelector('[data-swipe-remaining]');
  const counts = { kept: 0, rejected: 0 };
  let remaining = cards.length;

  const renderCounts = () => {
    if (keptEl) keptEl.textContent = String(counts.kept);
    if (rejectedEl) rejectedEl.textContent = String(counts.rejected);
    if (remainingEl) remainingEl.textContent = String(remaining);
  };

  // La pile peut contenir beaucoup de photos : visuellement on ne matérialise
  // que trois épaisseurs, les suivantes attendent cachées derrière la 3e.
  const depth = (i) => Math.min(i, 2);
  const stackY = (i) => depth(i) * 12;
  const stackScale = (i) => 1 - depth(i) * 0.05;

  // Boucle infinie : la carte triée repart discrètement sous la pile, le
  // compteur ne redescend jamais — comme une vraie session de tri qui défile.
  const order = [...cards];

  const applyZ = () => {
    order.forEach((card, i) => gsap.set(card, { zIndex: order.length - i }));
  };

  gsap.set(cards, { y: (i) => stackY(i), scale: (i) => stackScale(i), transformOrigin: '50% 80%' });
  applyZ();

  let active = null;
  let visible = false;

  const cycle = () => {
    if (!visible) {
      active = null;
      return;
    }

    const card = order[0];
    const keep = card.dataset.verdict === 'keep';
    const stamp = card.querySelector(keep ? '.swipe-stamp--keep' : '.swipe-stamp--reject');

    active = gsap.timeline({
      defaults: { ease: 'power2.inOut' },
      onComplete: () => {
        // Recyclage : la carte revient sous la pile, prête pour le prochain tour
        order.push(order.shift());
        applyZ();
        gsap.set(card, {
          x: 0,
          rotation: 0,
          opacity: 1,
          y: stackY(order.length - 1),
          scale: stackScale(order.length - 1),
        });
        gsap.set(card.querySelectorAll('.swipe-stamp'), { opacity: 0, scale: 1 });
        card.classList.remove('is-keep', 'is-reject');
        cycle();
      },
    });

    // La carte du dessus se penche, liseré + pastille de verdict, elle s'envole
    active
      .to(card, { rotation: keep ? 7 : -7, x: keep ? 26 : -26, duration: 0.45 }, 0)
      .call(() => card.classList.add(keep ? 'is-keep' : 'is-reject'), [], 0.2)
      .to(stamp, { opacity: 1, scale: 1.06, duration: 0.22, ease: 'back.out(2.5)' }, 0.25)
      .call(
        () => {
          counts[keep ? 'kept' : 'rejected'] += 1;
          remaining = remaining > 1 ? remaining - 1 : order.length;
          renderCounts();
        },
        [],
        0.3
      )
      .to(
        card,
        {
          x: keep ? 420 : -420,
          rotation: keep ? 24 : -24,
          opacity: 0,
          duration: 0.55,
          ease: 'power2.in',
        },
        0.75
      );

    // Les cartes du dessous remontent d'un cran (profondeur plafonnée)
    order.slice(1).forEach((below, d) => {
      active.to(below, { scale: stackScale(d), y: stackY(d), duration: 0.4 }, 0.9);
    });

    // Petite respiration avant la photo suivante
    active.to({}, { duration: 0.35 });
  };

  // La démo ne tourne que quand la pile est à l'écran
  new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        visible = entry.isIntersecting;
        if (visible) {
          if (active) active.resume();
          else cycle();
        } else if (active) {
          active.pause();
        }
      });
    },
    { threshold: 0.3 }
  ).observe(deck);
}

/* --- Footer : le (e) « gardé / rejeté » ----------------------------------- */

function wordmarkPlay() {
  const mark = document.querySelector('[data-footer-wordmark]');
  if (!mark) return;

  const e = mark.querySelector('.wordmark-e');
  const parens = mark.querySelectorAll('.wordmark-paren');
  if (!e || parens.length < 2) return;

  // Le « e » s'échappe des parenthèses puis revient — cull, puis repêché.
  const tl = gsap.timeline({
    repeat: -1,
    repeatDelay: 2.4,
    defaults: { ease: 'power2.inOut' },
    scrollTrigger: { trigger: mark, start: 'top 95%', toggleActions: 'play pause resume pause' },
  });

  tl.to(e, { y: -22, opacity: 0, duration: 0.5, ease: 'power2.in' })
    .to(parens[0], { x: '0.14em', duration: 0.4 }, '<0.15')
    .to(parens[1], { x: '-0.14em', duration: 0.4 }, '<')
    .to(parens, { x: 0, duration: 0.45 }, '+=0.9')
    .to(e, { y: 0, opacity: 1, duration: 0.55, ease: 'back.out(2)' }, '<0.1');
}
