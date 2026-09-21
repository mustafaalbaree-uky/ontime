# Draws OnTime's app icon: the steps of a run laid round a dial that closes at
# 12, the deadline. What is behind the hand is the app's "done" white (30%),
# what is left is white. Slots and hand share one width.
import math, subprocess, sys
CX = CY = 512
R, W = 318, 100          # ring centre radius and thickness
SLOT = 56                # width of the cuts between steps, and of the hand
HAND = 228               # hand length from the centre
JOINTS = [0, 60, 200, 280]   # degrees clockwise from 12 where a step ends
DONE_UNTIL = 60          # the hand sits on this joint

def pt(theta, r):
    t = math.radians(theta); return (CX + r*math.sin(t), CY - r*math.cos(t))
def arc(a0, a1):
    x0,y0 = pt(a0,R); x1,y1 = pt(a1,R); large = 1 if (a1-a0) > 180 else 0
    return f"M {x0:.2f} {y0:.2f} A {R} {R} 0 {large} 1 {x1:.2f} {y1:.2f}"
out = ['<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">',
       '  <rect width="1024" height="1024" fill="#000"/>',
       f'  <path d="{arc(0, DONE_UNTIL)}" fill="none" stroke="#fff" stroke-opacity="0.30" stroke-width="{W}"/>',
       f'  <path d="{arc(DONE_UNTIL, 359.99)}" fill="none" stroke="#fff" stroke-width="{W}"/>']
for j in JOINTS:
    x0,y0 = pt(j, R-W); x1,y1 = pt(j, R+W)
    out.append(f'  <path d="M {x0:.2f} {y0:.2f} L {x1:.2f} {y1:.2f}" stroke="#000" stroke-width="{SLOT}"/>')
hx,hy = pt(DONE_UNTIL, HAND)
out.append(f'  <path d="M {CX} {CY} L {hx:.2f} {hy:.2f}" stroke="#fff" stroke-width="{SLOT}"/>')
out.append('</svg>')
open(sys.argv[1] if len(sys.argv)>1 else 'AppIcon.svg','w').write("\n".join(out)+"\n")
