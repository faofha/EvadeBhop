import sys,struct,re,lz4.block,zstandard
data=open(sys.argv[1],'rb').read(); pat=re.compile(sys.argv[2])
def chunks():
    p=32
    while p<len(data):
        name=data[p:p+4]; cl,ul=struct.unpack('<II',data[p+4:p+12]); p+=16
        if cl==0: body=data[p:p+ul]; p+=ul
        else:
            raw=data[p:p+cl]; p+=cl
            body=zstandard.ZstdDecompressor().decompress(raw,max_output_size=ul) if raw[:4]==b'\x28\xb5\x2f\xfd' else lz4.block.decompress(raw,uncompressed_size=ul)
        yield name,body
        if name==b'END\x00':break
def u32s(b,n): return [(b[i]<<24)|(b[n+i]<<16)|(b[2*n+i]<<8)|b[3*n+i] for i in range(n)]
def i32s(b,n): return [(v>>1)^(-(v&1)) for v in u32s(b,n)]
def f32s(b,n):
    o=[]
    for v in u32s(b,n):
        v=((v>>1)|((v&1)<<31))&0xffffffff; o.append(round(struct.unpack('>f',struct.pack('>I',v))[0],4))
    return o
def refs(b,n):
    acc=0;o=[]
    for v in i32s(b,n): acc+=v;o.append(acc)
    return o
classes={};props={};parent={}
allc=list(chunks())
for name,body in allc:
    if name==b'INST':
        cid,ln=struct.unpack('<II',body[:8]);cn=body[8:8+ln].decode();q=9+ln
        n,=struct.unpack('<I',body[q:q+4]);q+=4;classes[cid]=(cn,refs(body[q:q+4*n],n))
    elif name==b'PRNT':
        n,=struct.unpack('<I',body[1:5]);c=refs(body[5:5+4*n],n);pa=refs(body[5+4*n:5+8*n],n);parent.update(zip(c,pa))
for name,body in allc:
    if name!=b'PROP':continue
    cid,ln=struct.unpack('<II',body[:8]);pn=body[8:8+ln].decode();q=8+ln;t=body[q];q+=1
    if cid not in classes: continue
    rs=classes[cid][1];n=len(rs);b=body[q:];vals=None
    try:
        if t==1:
            vals=[];k=0
            for _ in range(n):
                l,=struct.unpack('<I',b[k:k+4]);k+=4;vals.append(b[k:k+l].decode('utf8','replace')[:80]);k+=l
        elif t==2: vals=[bool(x) for x in b[:n]]
        elif t==3: vals=i32s(b,n)
        elif t==4: vals=f32s(b,n)
        elif t==6: s=f32s(b,n);o=i32s(b[4*n:],n);vals=[f'UDim({a},{c})' for a,c in zip(s,o)]
        elif t==7:
            sx=f32s(b,n);sy=f32s(b[4*n:],n);ox=i32s(b[8*n:],n);oy=i32s(b[12*n:],n)
            vals=[f'{{{a},{c},{bb},{d}}}' for a,bb,c,d in zip(sx,sy,ox,oy)]
        elif t==0xC: r=f32s(b,n);g=f32s(b[4*n:],n);bl=f32s(b[8*n:],n);vals=[f'rgb({round(x*255)},{round(y*255)},{round(z*255)})' for x,y,z in zip(r,g,bl)]
        elif t==0xD: x=f32s(b,n);y=f32s(b[4*n:],n);vals=[f'({a},{c})' for a,c in zip(x,y)]
        elif t==0x12: vals=u32s(b,n)
        elif t==0x1A: vals=[f'rgb({b[i]},{b[n+i]},{b[2*n+i]})' for i in range(n)]
        elif t==0x20:
            vals=[];k=0
            for _ in range(n):
                l,=struct.unpack('<I',b[k:k+4]);k+=4;fam=b[k:k+l].decode();k+=l
                w,=struct.unpack('<H',b[k:k+2]);k+=2;st=b[k];k+=1
                l,=struct.unpack('<I',b[k:k+4]);k+=4+l;vals.append(f'Font({fam.split("/")[-1]},{w},{st})')
        elif t==0x16:
            vals=[];k=0  # ColorSequence
            for _ in range(n):
                c,=struct.unpack('<I',b[k:k+4]);k+=4;kp=[]
                for _ in range(c):
                    tt,r,g,bb,e=struct.unpack('<fffff',b[k:k+20]);k+=20;kp.append(f'{round(tt,2)}:rgb({round(r*255)},{round(g*255)},{round(bb*255)})')
                vals.append('CS['+' '.join(kp)+']')
        elif t==0x17:
            vals=[f'NR({round(struct.unpack("<f",b[8*i:8*i+4])[0],3)},{round(struct.unpack("<f",b[8*i+4:8*i+8])[0],3)})' for i in range(n)]
        elif t==0x0E: x=f32s(b,n);y=f32s(b[4*n:],n);z=f32s(b[8*n:],n);vals=[f'V3({a},{c},{d})' for a,c,d in zip(x,y,z)]
        elif t==0x15:
            vals=[];k=0
            for _ in range(n):
                c,=struct.unpack('<I',b[k:k+4]);k+=4;kp=[]
                for _ in range(c):
                    tt,v,e=struct.unpack('<fff',b[k:k+12]);k+=12;kp.append(f'{round(tt,2)}:{round(v,2)}')
                vals.append('NS['+' '.join(kp)+']')
    except Exception as e: vals=None; print('ERR',pn,t,e,file=sys.stderr)
    if vals:
        for r,v in zip(rs,vals): props.setdefault(r,{})[pn]=v
cls={r:c for c,(cn,rs) in classes.items() for r in rs}
cn={r:classes[c][0] for c,(x,rs) in classes.items() for r in rs}
def path(r):
    s=[]
    while r in cn: s.append(props.get(r,{}).get('Name','?'));r=parent.get(r,-1)
    return '/'.join(reversed(s))
SKIP={'Name','AttributesSerialize','Tags','SourceAssetId','HistoryId','UniqueId','Capabilities','DefinesCapabilities','Sandboxed','AutoLocalize','RootLocalizationTable','Archivable','SelectionGroup','Selectable','SelectionOrder','NextSelectionDown','NextSelectionLeft','NextSelectionRight','NextSelectionUp','Localize','Draggable','Active','ClipsDescendants'}
for r in sorted(cn,key=path):
    p=path(r)
    if pat.search(p):
        print(f'== {p} [{cn[r]}]')
        print('   '+'; '.join(f'{k}={v}' for k,v in sorted(props.get(r,{}).items()) if k not in SKIP and v not in ('',)))
