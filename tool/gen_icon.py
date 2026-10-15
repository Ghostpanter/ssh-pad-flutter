# Generates launcher icons from a single geometry (also emits SVG source).
from PIL import Image, ImageDraw
import os
NAVY=(11,31,77,255); WHITE=(255,255,255,255); BLACK=(0,0,0,255); GREEN=(57,229,92,255)
def geom(tw):  # tablet width in 1024 units, centered
    th=tw*0.78; x0=512-tw/2; y0=512-th/2; s=tw/335
    return dict(tw=tw,th=th,x0=x0,y0=y0,s=s)
def draw(size, tw, bg=None, mono=False, rounded=False):
    SS=4; N=1024*SS; k=N/1024
    im=Image.new('RGBA',(N,N),(0,0,0,0)); d=ImageDraw.Draw(im)
    if bg: 
        if rounded: d.rounded_rectangle([0,0,N-1,N-1],radius=int(225*k),fill=bg)
        else: d.rectangle([0,0,N,N],fill=bg)
    g=geom(tw); s=g['s']; x0,y0,w,h=g['x0'],g['y0'],g['tw'],g['th']
    fg=WHITE; scr=(0,0,0,0) if mono else BLACK; gr=WHITE if mono else GREEN
    R=lambda a:[v*k for v in a]
    d.rounded_rectangle(R([x0,y0,x0+w,y0+h]),radius=22*s*k,fill=fg)
    b=14*s; bt=24*s
    d.rounded_rectangle(R([x0+b,y0+bt,x0+w-b,y0+h-b]),radius=12*s*k,fill=scr)
    cx=x0+w/2; r=4.5*s
    d.ellipse(R([cx-r,y0+bt/2-r,cx+r,y0+bt/2+r]),fill=scr if not mono else (0,0,0,0))
    sx=x0+b+24*s; sy=y0+bt+44*s; lw=int(7*s*k)
    d.line(R([sx,sy,sx+26*s,sy+18*s,sx,sy+36*s]),fill=gr,width=lw,joint='curve')
    d.line(R([sx+34*s,sy+40*s,sx+62*s,sy+40*s]),fill=gr,width=lw)
    d.rectangle(R([sx+70*s,sy,sx+92*s,sy+50*s]),fill=gr)
    dy=sy+104*s
    for i in range(4):
        a=sx+i*30*s; d.line(R([a,dy,a+18*s,dy]),fill=gr,width=lw)
    return im.resize((size,size),Image.LANCZOS)
res='android/app/src/main/res'
dens={'mdpi':1,'hdpi':1.5,'xhdpi':2,'xxhdpi':3,'xxxhdpi':4}
for n,f in dens.items():
    p=f'{res}/mipmap-{n}'; os.makedirs(p,exist_ok=True)
    draw(int(48*f),840,NAVY,rounded=True).save(f'{p}/ic_launcher.png')
    c=draw(int(48*f),700,NAVY); m=Image.new('L',c.size,0); ImageDraw.Draw(m).ellipse([0,0,c.size[0]-1,c.size[1]-1],fill=255)
    o=Image.new('RGBA',c.size,(0,0,0,0)); o.paste(c,(0,0),m); o.save(f'{p}/ic_launcher_round.png')
    draw(int(108*f),480).save(f'{p}/ic_launcher_foreground.png')
    draw(int(108*f),480,mono=True).save(f'{p}/ic_launcher_monochrome.png')
draw(1024,840,NAVY,rounded=True).save('assets/branding/app_icon_1024.png')
draw(1024,480).save('assets/branding/app_icon_foreground_1024.png')
# preview
fgi=draw(512,480,NAVY); m=Image.new('L',(512,512),0); ImageDraw.Draw(m).ellipse([0,0,511,511],fill=255)
pv=Image.new('RGBA',(1064,552),(240,240,240,255)); pv.paste(fgi,(20,20),m)
pv.alpha_composite(draw(512,840,NAVY,rounded=True),(532,20)); pv.save('/workspace/artifacts/logo_preview.png')
# SVG source (1024 legacy layout)
g=geom(840); s=g['s']; x0,y0,w,h=g['x0'],g['y0'],g['tw'],g['th']; b=14*s; bt=24*s; sx=x0+b+24*s; sy=y0+bt+44*s; dy=sy+104*s
dash=''.join(f'<line x1="{sx+i*30*s:.1f}" y1="{dy:.1f}" x2="{sx+i*30*s+18*s:.1f}" y2="{dy:.1f}"/>' for i in range(4))
open('assets/branding/app_icon.svg','w').write(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<rect width="1024" height="1024" rx="225" fill="#0B1F4D"/>
<rect x="{x0:.1f}" y="{y0:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{22*s:.1f}" fill="#fff"/>
<rect x="{x0+b:.1f}" y="{y0+bt:.1f}" width="{w-2*b:.1f}" height="{h-b-bt:.1f}" rx="{12*s:.1f}" fill="#000"/>
<circle cx="512" cy="{y0+bt/2:.1f}" r="{4.5*s:.1f}" fill="#000"/>
<g stroke="#39E55C" stroke-width="{7*s:.1f}" fill="none" stroke-linejoin="round">
<polyline points="{sx:.1f},{sy:.1f} {sx+26*s:.1f},{sy+18*s:.1f} {sx:.1f},{sy+36*s:.1f}"/>
<line x1="{sx+34*s:.1f}" y1="{sy+40*s:.1f}" x2="{sx+62*s:.1f}" y2="{sy+40*s:.1f}"/>{dash}</g>
<rect x="{sx+70*s:.1f}" y="{sy:.1f}" width="{22*s:.1f}" height="{50*s:.1f}" fill="#39E55C"/>
</svg>
''')
