#!/usr/bin/env python3
"""Icône Peliculle v3 — style Aperçu/Preview d'Apple :
paysage plein cadre net + loupe avec vraie magnification."""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 4
W = 1024 * S


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def multi_gradient(h, stops):
    cols = []
    for y in range(h):
        t = y / (h - 1)
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                cols.append(lerp(c0, c1, (t - p0) / (p1 - p0)))
                break
        else:
            cols.append(stops[-1][1])
    return cols


def build_scene(w, h):
    """Paysage minimaliste : ciel dégradé, soleil haut-droite,
    deux montagnes enneigées, mer en bas."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    cols = multi_gradient(h, [
        (0.00, (0x3F, 0x96, 0xE4)),   # bleu ciel profond
        (0.45, (0x9E, 0xCE, 0xF0)),   # bleu pâle
        (0.60, (0xD8, 0xEC, 0xF8)),   # quasi blanc à l'horizon
        (0.62, (0x64, 0xB2, 0xD8)),   # mer claire
        (1.00, (0x2E, 0x7B, 0xB8)),   # mer profonde
    ])
    for y in range(h):
        c = cols[y]
        for x in range(w):
            px[x, y] = c

    d = ImageDraw.Draw(img, "RGBA")

    # Soleil haut-droite avec halo doux
    scx, scy, sr = int(w * 0.76), int(h * 0.22), int(w * 0.085)
    halo = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    hd.ellipse([scx - sr * 2.6, scy - sr * 2.6, scx + sr * 2.6, scy + sr * 2.6],
               fill=(255, 248, 220, 110))
    halo = halo.filter(ImageFilter.GaussianBlur(w * 0.035))
    img = Image.alpha_composite(img.convert("RGBA"), halo).convert("RGB")
    d = ImageDraw.Draw(img, "RGBA")
    d.ellipse([scx - sr, scy - sr, scx + sr, scy + sr], fill=(0xFF, 0xF5, 0xD9))

    horizon = h * 0.62

    def mountain(cx_ratio, peak_ratio, half_w_ratio, body, snow_ratio):
        cx = w * cx_ratio
        peak = h * peak_ratio
        hw = w * half_w_ratio
        pts = [(cx - hw, horizon), (cx, peak), (cx + hw, horizon)]
        d.polygon(pts, fill=body)
        # calotte de neige : triangle propre, proportionnel à la pente
        sh = (horizon - peak) * snow_ratio
        d.polygon([(cx, peak),
                   (cx - hw * snow_ratio, peak + sh),
                   (cx + hw * snow_ratio, peak + sh)],
                  fill=(0xF4, 0xF9, 0xFD))

    # Montagne arrière (gauche, plus claire) puis avant (droite, plus foncée)
    mountain(0.26, 0.32, 0.30, (0x6D, 0x9E, 0xCC), 0.32)
    mountain(0.63, 0.19, 0.40, (0x46, 0x74, 0xA6), 0.28)

    # fine ligne d'horizon lumineuse
    d.rectangle([0, horizon - S, w, horizon + S * 2], fill=(0xEA, 0xF6, 0xFC, 200))
    return img


scene = build_scene(W, W)
base = scene.convert("RGBA")

# --- Loupe : posée sur la ligne d'horizon (pente + horizon + mer dans le
# verre → la magnification se lit immédiatement) ---
LCX, LCY = int(W * 0.40), int(W * 0.585)
LR = int(W * 0.215)
RING = int(W * 0.042)

zoom = 1.7
crop_r = int(LR / zoom)
crop = scene.crop((LCX - crop_r, LCY - crop_r, LCX + crop_r, LCY + crop_r))
glass = crop.resize((LR * 2, LR * 2), Image.LANCZOS).convert("RGBA")
glass = Image.alpha_composite(glass, Image.new("RGBA", glass.size, (255, 255, 255, 18)))
gmask = Image.new("L", glass.size, 0)
ImageDraw.Draw(gmask).ellipse([0, 0, glass.width - 1, glass.height - 1], fill=255)

# Ombre portée douce (loupe + manche)
ang = math.radians(42)
hx0 = LCX + (LR + RING - S * 4) * math.cos(ang)
hy0 = LCY + (LR + RING - S * 4) * math.sin(ang)
hx1 = LCX + (LR + RING + W * 0.155) * math.cos(ang)
hy1 = LCY + (LR + RING + W * 0.155) * math.sin(ang)

shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
off = int(W * 0.014)
sd.ellipse([LCX - LR - RING + off, LCY - LR - RING + off * 2,
            LCX + LR + RING + off, LCY + LR + RING + off * 2],
           fill=(15, 35, 60, 95))
sd.line([hx0 + off, hy0 + off * 2, hx1 + off, hy1 + off * 2],
        fill=(15, 35, 60, 95), width=int(W * 0.055))
shadow = shadow.filter(ImageFilter.GaussianBlur(W * 0.016))
base.alpha_composite(shadow)

# Manche blanc, bout arrondi
handle = Image.new("RGBA", (W, W), (0, 0, 0, 0))
hd = ImageDraw.Draw(handle)
hd.line([hx0, hy0, hx1, hy1], fill=(0xFA, 0xFB, 0xFC, 255), width=int(W * 0.052))
hd.ellipse([hx1 - W * 0.026, hy1 - W * 0.026, hx1 + W * 0.026, hy1 + W * 0.026],
           fill=(0xFA, 0xFB, 0xFC, 255))
base.alpha_composite(handle)

# Anneau blanc + liseré gris très léger à l'intérieur pour le relief
rd = ImageDraw.Draw(base)
rd.ellipse([LCX - LR - RING, LCY - LR - RING, LCX + LR + RING, LCY + LR + RING],
           fill=(0xFA, 0xFB, 0xFC, 255))

# Verre magnifié
base.paste(glass, (LCX - LR, LCY - LR), gmask)

# Liseré intérieur discret (séparation verre/anneau)
rd.ellipse([LCX - LR, LCY - LR, LCX + LR, LCY + LR],
           outline=(160, 175, 190, 90), width=S * 2)

# Reflet du verre : arc doux haut-gauche
gloss = Image.new("RGBA", (W, W), (0, 0, 0, 0))
gd = ImageDraw.Draw(gloss)
gd.arc([LCX - LR + S * 16, LCY - LR + S * 16, LCX + LR - S * 16, LCY + LR - S * 16],
       start=200, end=270, fill=(255, 255, 255, 170), width=S * 10)
gloss = gloss.filter(ImageFilter.GaussianBlur(S * 6))
base.alpha_composite(gloss)

# --- Sortie ---
final = base.convert("RGB").resize((1024, 1024), Image.LANCZOS)
out = "/home/user/Peliculle/Peliculle/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
final.save(out, "PNG")

preview = final.resize((256, 256), Image.LANCZOS)
pmask = Image.new("L", (256, 256), 0)
ImageDraw.Draw(pmask).rounded_rectangle([0, 0, 255, 255], radius=57, fill=255)
pv = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
pv.paste(preview, (0, 0), pmask)
pv.save("/tmp/claude-0/-home-user-Peliculle/4f056d95-5f45-5768-ae97-acd0128db7ad/scratchpad/preview.png")
print("ok")
