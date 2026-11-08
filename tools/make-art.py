# ============================================================================
#  生成小鲸鱼桌宠的形象与图标（原创绘制，Pillow）
#  输出：
#    assets/whale.png   默认皮肤（透明背景，1024×1024）
#    assets/icon.png    应用图标（圆角蓝底 + 白色小鲸鱼，1024×1024）
#    assets/whale.ico   多尺寸图标（16–256）
#  用法：python tools/make-art.py
# ============================================================================
import os
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4
BASE = 1024
W = BASE * S
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(HERE, 'assets')


def sc(box):
    return tuple(int(v * S) for v in box)


def circle(cx, cy, r):
    return sc((cx - r, cy - r, cx + r, cy + r))


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vgrad(y0, y1, top, bottom):
    img = Image.new('RGB', (1, W))
    px = img.load()
    for y in range(W):
        if y <= y0 * S:
            t = 0.0
        elif y >= y1 * S:
            t = 1.0
        else:
            t = (y - y0 * S) / ((y1 - y0) * S)
        px[0, y] = lerp(top, bottom, t)
    return img.resize((W, W))


def rounded_mask(box, radius):
    m = Image.new('L', (W, W), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def catmull(points, samples=26):
    """闭合 Catmull-Rom 样条，返回平滑后的点列。"""
    pts = [points[-1]] + list(points) + [points[0], points[1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for j in range(samples):
            t = j / samples
            t2 = t * t
            t3 = t2 * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t
                       + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                       + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t
                       + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                       + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    return out


# 侧视鲸鱼轮廓（顺时针）：圆头在左，尾鳍在右
BODY = [
    (300, 350), (430, 368), (570, 420), (690, 490),
    (770, 520), (860, 470), (902, 540), (822, 590),
    (902, 642), (858, 712), (770, 672), (690, 722),
    (570, 772), (430, 802), (300, 812), (170, 772),
    (110, 660), (110, 520), (170, 410),
]

COLOR = {
    'top': (128, 210, 255),
    'bottom': (34, 102, 224),
    'outline': (21, 66, 152),
    'ow': 8,
    'belly': (234, 247, 255),
    'eye': (16, 28, 50),
    'blush': (255, 150, 175, 120),
    'bubble': (150, 214, 255, 225),
    'fin': (36, 106, 228),
}

MONO = {
    'top': (255, 255, 255),
    'bottom': (226, 243, 255),
    'outline': None,
    'ow': 0,
    'belly': (203, 231, 255),
    'eye': (17, 48, 92),
    'blush': (255, 165, 185, 120),
    'bubble': (255, 255, 255, 180),
    'fin': (232, 246, 255),
}


def render_whale(p):
    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))

    # ---------- 身体（平滑轮廓 + 渐变）----------
    poly = [(int(x * S), int(y * S)) for x, y in catmull(BODY)]
    mask = Image.new('L', (W, W), 0)
    ImageDraw.Draw(mask).polygon(poly, fill=255)
    grad = vgrad(350, 810, p['top'], p['bottom']).convert('RGBA')
    body = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    body.paste(grad, (0, 0), mask)
    img.alpha_composite(body)

    # ---------- 肚子 ----------
    belly_box = sc((120, 600, 540, 812))
    bm = Image.new('L', (W, W), 0)
    ImageDraw.Draw(bm).ellipse(belly_box, fill=255)
    bm = ImageChops.multiply(bm, mask)
    bel = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(bel).ellipse(belly_box, fill=p['belly'])
    img.paste(bel, (0, 0), bm)


    d = ImageDraw.Draw(img)

    # ---------- 眼睛 ----------
    d.ellipse(sc((222, 512, 282, 600)), fill=p['eye'])
    d.ellipse(circle(244, 538, 9), fill=(255, 255, 255, 255))
    d.ellipse(circle(268, 582, 6), fill=(255, 255, 255, 165))

    # ---------- 腮红 ----------
    blush = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(blush).ellipse(sc((150, 610, 240, 660)), fill=p['blush'])
    blush = blush.filter(ImageFilter.GaussianBlur(8 * S))
    img.alpha_composite(blush)

    # ---------- 微笑 ----------
    d.arc(sc((300, 612, 366, 676)), start=15, end=150, fill=p['eye'], width=int(8 * S))

    return img


def render_bubbles(p):
    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for (cx, cy, r) in ((700, 300, 24), (758, 232, 14), (786, 306, 9)):
        d.ellipse(circle(cx, cy, r), outline=p['bubble'], width=int(5 * S))
    return img


def fit_square(img, margin=0.06):
    bbox = img.split()[3].getbbox()
    if not bbox:
        return img.resize((BASE, BASE), Image.LANCZOS)
    crop = img.crop(bbox)
    w, h = crop.size
    side = int(max(w, h) * (1 + margin * 2))
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(crop, ((side - w) // 2, (side - h) // 2))
    return canvas.resize((BASE, BASE), Image.LANCZOS)


def add_outline(img, color, width=8):
    alpha = img.split()[3]
    ring = alpha.filter(ImageFilter.MaxFilter(width * 2 + 1))
    ring = ImageChops.subtract(ring, alpha)
    stroke = Image.new('RGBA', img.size, color)
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    out.paste(stroke, (0, 0), ring)
    out.alpha_composite(img)
    return out


def render_badge():
    bg = vgrad(0, BASE, (80, 160, 255), (34, 198, 232)).convert('RGBA')
    mask = rounded_mask(sc((0, 0, BASE, BASE)), 232 * S)
    badge = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    badge.paste(bg, (0, 0), mask)

    art = render_whale(MONO).resize((BASE, BASE), Image.LANCZOS)
    art.alpha_composite(render_bubbles(MONO).resize((BASE, BASE), Image.LANCZOS))
    art = fit_square(art, 0.05)
    size = int(W * 0.80)
    whale = art.resize((size, size), Image.LANCZOS)
    bubbles = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    x = int((W - size) / 2)
    y = int(W * 0.09)

    # 阴影
    alpha = whale.split()[3].point(lambda a: int(a * 0.32))
    shadow = Image.new('RGBA', (size, size), (8, 44, 110, 0))
    shadow.putalpha(alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(10 * S)))
    badge.alpha_composite(shadow, (x + int(2 * S), y + int(26 * S)))

    badge.alpha_composite(whale, (x, y))
    badge.alpha_composite(bubbles, (x, y))
    return badge


def main():
    os.makedirs(ASSETS, exist_ok=True)

    whale = render_whale(COLOR).resize((BASE, BASE), Image.LANCZOS)
    if COLOR['outline']:
        whale = add_outline(whale, COLOR['outline'] + (255,), COLOR['ow'])
    bubb = render_bubbles(COLOR).resize((BASE, BASE), Image.LANCZOS)
    whale.alpha_composite(bubb)
    whale = fit_square(whale, 0.05)
    whale.save(os.path.join(ASSETS, 'whale.png'))

    badge = render_badge().resize((BASE, BASE), Image.LANCZOS)
    badge.save(os.path.join(ASSETS, 'icon.png'))

    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    badge.save(os.path.join(ASSETS, 'whale.ico'), sizes=sizes)

    print('ok: whale.png / icon.png / whale.ico')


if __name__ == '__main__':
    main()
