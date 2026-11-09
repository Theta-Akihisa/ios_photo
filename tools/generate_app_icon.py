# Generates the LuxCam app icon (design "E3": square frame + lens). Requires Pillow.
# Usage: python3 tools/generate_app_icon.py  -> writes E1/E2/E3.png in the current directory;
# E3.png is the icon used in LuxCam/Assets.xcassets/AppIcon.appiconset/AppIcon.png.
import math, random
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops
S=2048; OUT=1024
RED=(227,13,20); ORANGE=(244,112,28); WHITE=(236,236,232)
FONT="/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
random.seed(3)

def noise(size, scale=1.0, blur=0):
    n=Image.effect_noise((size[0],size[1]),64*scale).convert("L")
    if blur: n=n.filter(ImageFilter.GaussianBlur(blur))
    return n

def brushed(w,h,base=178,spread=40,vertical_grad=True):
    # horizontal streaks
    n=Image.effect_noise((w,h),50).convert("L").resize((w,max(1,h)),Image.BILINEAR)
    n=n.filter(ImageFilter.BoxBlur(0)).resize((max(1,w//60),h)).resize((w,h),Image.BILINEAR)
    img=Image.new("RGB",(w,h)); px=img.load(); npx=n.load()
    for y in range(h):
        g=base+ (int(spread*(0.5-y/h)) if vertical_grad else 0)
        for x in range(0,w):
            v=g+(npx[x,y]-128)//6
            px[x,y]=(v,v,v+3)
    return img

def leather(w,h):
    n=noise((w,h),1.0,blur=1.6)
    img=Image.new("RGB",(w,h),(18,18,19))
    tex=Image.merge("RGB",(n,n,n)).point(lambda v:int(v*0.12))
    return ImageChops.add(img,tex)

def lens(img,cx,cy,R,ring_col=(60,60,62)):
    d=ImageDraw.Draw(img)
    # chrome outer ring
    ch=brushed(int(R*3.2),int(R*3.2),base=170,spread=60)
    m=Image.new("L",ch.size,0); md=ImageDraw.Draw(m)
    o=R*1.55; c0=ch.size[0]/2
    md.ellipse([c0-o,c0-o,c0+o,c0+o],fill=255); md.ellipse([c0-R*1.36,c0-R*1.36,c0+R*1.36,c0+R*1.36],fill=0)
    img.paste(ch,(int(cx-c0),int(cy-c0)),m)
    # knurl
    for i in range(140):
        a=2*math.pi*i/140; r1,r2=R*1.40,R*1.53
        d.line([(cx+r1*math.cos(a),cy+r1*math.sin(a)),(cx+r2*math.cos(a),cy+r2*math.sin(a))],fill=(95,95,98),width=max(1,int(R*0.012)))
    # black inner barrel
    for r,col in [(R*1.36,(16,16,18)),(R*1.2,(34,34,36)),(R*1.12,(14,14,16))]:
        d.ellipse([cx-r,cy-r,cx+r,cy+r],fill=col)
    # engraved scale ticks
    for i in range(36):
        a=2*math.pi*i/36; r1=R*1.14; r2=R*(1.19 if i%3 else 1.22)
        d.line([(cx+r1*math.cos(a),cy+r1*math.sin(a)),(cx+r2*math.cos(a),cy+r2*math.sin(a))],fill=(150,150,150),width=max(1,int(R*0.008)))
    # glass
    g=Image.new("RGB",img.size); gd=ImageDraw.Draw(g); n=70
    for i in range(n):
        r=R-i*R/n*0.95; t=i/n
        gd.ellipse([cx-r,cy-r,cx+r,cy+r],fill=(int(6+10*t),int(10+18*t),int(22+42*t)))
    m=Image.new("L",img.size,0); ImageDraw.Draw(m).ellipse([cx-R,cy-R,cx+R,cy+R],fill=255)
    img.paste(g,(0,0),m)
    d=ImageDraw.Draw(img)
    for f,w in [(0.74,6),(0.5,5)]:
        r=R*f; d.ellipse([cx-r,cy-r,cx+r,cy+r],outline=(40,52,82),width=w)
    hl=Image.new("L",img.size,0); hd=ImageDraw.Draw(hl)
    hd.pieslice([cx-R*0.88,cy-R*0.88,cx+R*0.88,cy+R*0.88],200,250,fill=95)
    hd.ellipse([cx-R*0.7,cy-R*0.7,cx+R*0.7,cy+R*0.7],fill=0)
    img.paste((200,215,255),(0,0),hl.filter(ImageFilter.GaussianBlur(R*0.06)))
    hl2=Image.new("L",img.size,0); ImageDraw.Draw(hl2).ellipse([cx-R*0.42,cy-R*0.56,cx-R*0.2,cy-R*0.34],fill=130)
    img.paste((230,235,255),(0,0),hl2.filter(ImageFilter.GaussianBlur(R*0.04)))

def circle(d,x,y,r,col): d.ellipse([x-r,y-r,x+r,y+r],fill=col)

def text(d,x,y,t,size,col,anchor="mm"):
    f=ImageFont.truetype(FONT,size); d.text((x,y),t,fill=col,font=f,anchor=anchor)

# E1: Hasselblad V-style square: chrome frame, leather front, Leica lens, red dot + orange shutter
def e1():
    img=Image.new("RGB",(S,S),(10,10,11))
    # chrome frame around whole icon
    fr=brushed(S,S,base=176,spread=70); img.paste(fr,(0,0))
    inset=150
    lt=leather(S-2*inset,S-2*inset); img.paste(lt,(inset,inset))
    d=ImageDraw.Draw(img)
    d.rectangle([inset,inset,S-inset,S-inset],outline=(70,70,72),width=6)
    lens(img,S/2,S/2-30,440)
    d=ImageDraw.Draw(img)
    circle(d,S-inset-170,inset+170,64,RED)
    # orange shutter on top-left chrome edge
    circle(d,inset+170,inset+170,70,ORANGE)
    d.ellipse([inset+100,inset+100,inset+240,inset+240],outline=(120,50,10),width=6)
    text(d,S/2,S-inset-120,"L U X",96,(205,205,200))
    return img

# E2: Leica-like rounded body proportion inside square: silver top plate + black leather, lens centre, orange shutter on top plate, red dot on front
def e2():
    img=Image.new("RGB",(S,S),(12,12,13))
    top=int(S*0.30)
    img.paste(brushed(S,top,base=182,spread=50),(0,0))
    img.paste(leather(S,S-top),(0,top))
    d=ImageDraw.Draw(img)
    d.line([(0,top),(S,top)],fill=(60,60,62),width=10)
    # engraved LUX on top plate
    text(d,S*0.30,top*0.55,"L U X",120,(40,40,42))
    # orange shutter button on top plate
    circle(d,S*0.78,top*0.55,110,(120,120,124)); circle(d,S*0.78,top*0.55,80,ORANGE)
    lens(img,S/2,top+(S-top)/2+10,410)
    d=ImageDraw.Draw(img)
    circle(d,S*0.86,top+150,60,RED)
    return img

# E3: minimal: square silver frame ring (Hasselblad square) + Leica round lens + red dot, black bg, orange small accent
def e3():
    img=Image.new("RGB",(S,S),(10,10,11)); d=ImageDraw.Draw(img)
    for y in range(S):
        v=int(22-14*y/S); d.line([(0,y),(S,y)],fill=(v,v,v+1))
    # square chrome frame (rounded square)
    sq=brushed(S,S,base=176,spread=60)
    m=Image.new("L",(S,S),0); md=ImageDraw.Draw(m)
    a=360; md.rounded_rectangle([a,a-60,S-a,S-a-60],radius=150,fill=255)
    md.rounded_rectangle([a+48,a-12,S-a-48,S-a-108],radius=110,fill=0)
    img.paste(sq,(0,0),m)
    lens(img,S/2,S/2-60,380)
    d=ImageDraw.Draw(img)
    circle(d,S-a-90,a+30,58,RED)
    text(d,S/2,S-a+150,"L U X",110,WHITE)
    circle(d,a+30,S-a-20+0,0,ORANGE)
    d.rectangle([S/2-90,S-a+250,S/2+90,S-a+262],fill=ORANGE)
    return img

def save(im,n): im=im.resize((OUT,OUT),Image.LANCZOS).convert("RGB"); im.save(n); return im
ims=[save(e1(),"E1.png"),save(e2(),"E2.png"),save(e3(),"E3.png")]
def rounded(im,size=340):
    im=im.resize((size,size),Image.LANCZOS); m=Image.new("L",(size*4,size*4),0)
    ImageDraw.Draw(m).rounded_rectangle([0,0,size*4,size*4],radius=int(size*4*0.2237),fill=255)
    m=m.resize((size,size),Image.LANCZOS); out=Image.new("RGB",(size,size),(242,242,247)); out.paste(im,(0,0),m); return out
W=60+3*(340+50)+130; sheet=Image.new("RGB",(W,340+150),(242,242,247)); sd=ImageDraw.Draw(sheet)
f=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",30)
labels=["E1  Square body","E2  Top plate","E3  Square frame"]
for i,im in enumerate(ims):
    x=60+i*(340+50); sheet.paste(rounded(im),(x,40)); sd.text((x,400),labels[i],fill=(30,30,30),font=f)
for i,im in enumerate(ims):
    sheet.paste(rounded(im,100),(W-120,40+i*120))
sheet.save("icon_candidates3.png")
