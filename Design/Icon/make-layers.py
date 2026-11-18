import math, sys

# Draws the app icon's two layers, a laptop and two sparkles, into an Icon Composer document.
# Run from the repo root: python3 Design/Icon/make-layers.py Kleyn/AppIcon.icon
# It writes Assets/laptop.svg and Assets/sparkles.svg there; copy them to Design/Icon too.
out = sys.argv[1]

def f(v): return f"{v:.1f}".rstrip('0').rstrip('.')

def rounded_polygon(pts, r):
    """A closed path through pts with each corner rounded by r (clamped to half the shorter edge)."""
    n = len(pts); d = ""
    for i in range(n):
        p0, p1, p2 = pts[i-1], pts[i], pts[(i+1) % n]
        def toward(a, b, dist):
            dx, dy = b[0]-a[0], b[1]-a[1]; L = math.hypot(dx, dy); k = min(dist, L/2)/L
            return (a[0]+dx*k, a[1]+dy*k)
        a = toward(p1, p0, r); b = toward(p1, p2, r)
        d += ("M" if i == 0 else "L") + f"{f(a[0])} {f(a[1])}Q{f(p1[0])} {f(p1[1])} {f(b[0])} {f(b[1])}"
    return d + "Z"

def rect(x0, y0, x1, y1, r): return rounded_polygon([(x0,y0),(x1,y0),(x1,y1),(x0,y1)], r)

parts = []
# Screen: a frame, its glass left open so the blue shows through. As wide as the back edge
# of the base, as on a real laptop, where the lid closes onto it.
parts.append(rect(212, 176, 812, 540, 48))
parts.append(rect(248, 212, 776, 504, 16))
# Base, seen from above: wider at the front.
top_y, bot_y = 566, 820
top = (212, 812); bot = (140, 884)
def deck_x(y, t):
    k = (y - top_y) / (bot_y - top_y)
    left = top[0] + (bot[0]-top[0])*k; right = top[1] + (bot[1]-top[1])*k
    return left + (right-left)*t
parts.append(rounded_polygon([(top[0],top_y),(top[1],top_y),(bot[1],bot_y),(bot[0],bot_y)], 44))
# Keys: rows follow the perspective, as in the old icon (two rows of six, then a space bar).
margin = 0.07
rows = [(600, 650, [1]*6), (668, 720, [1]*6), (738, 792, [1, 4, 1])]
gap = 0.022
for y0, y1, widths in rows:
    usable = 1 - 2*margin; total = sum(widths); n = len(widths)
    unit = (usable - gap*(n-1)) / total
    t = margin
    for w in widths:
        t0, t1 = t, t + unit*w
        parts.append(rounded_polygon([(deck_x(y0,t0),y0),(deck_x(y0,t1),y0),(deck_x(y1,t1),y1),(deck_x(y1,t0),y1)], 12))
        t = t1 + gap
laptop = f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n  <path fill="#FFFFFF" fill-rule="evenodd" d="{"".join(parts)}"/>\n</svg>\n'

def sparkle(cx, cy, R):
    c = 0.2*R
    return (f"M{f(cx)} {f(cy-R)}Q{f(cx+c)} {f(cy-c)} {f(cx+R)} {f(cy)}Q{f(cx+c)} {f(cy+c)} {f(cx)} {f(cy+R)}"
            f"Q{f(cx-c)} {f(cy+c)} {f(cx-R)} {f(cy)}Q{f(cx-c)} {f(cy-c)} {f(cx)} {f(cy-R)}Z")
# Inside the screen: the big one lower right, the small one upper left, as before.
sparkles = f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n  <path fill="#FFFFFF" d="{sparkle(583, 368, 112)}{sparkle(441, 290, 52)}"/>\n</svg>\n'

open(f"{out}/Assets/laptop.svg", "w").write(laptop)
open(f"{out}/Assets/sparkles.svg", "w").write(sparkles)
# Point the document at laptop.svg, keeping Icon Composer's formatting.
path = f"{out}/icon.json"
text = open(path).read()
text = text.replace('"image-name" : "keyboard.svg"', '"image-name" : "laptop.svg"').replace('"name" : "keyboard"', '"name" : "laptop"')
open(path, "w").write(text)
