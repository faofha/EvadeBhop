import sys,struct,re
import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'parse.py')).read().split("tree=open")[0].replace("data=open(sys.argv[1],'rb').read(); out=sys.argv[2]","data=open(sys.argv[1],'rb').read()"))
def attrs(b):
    if not b: return {}
    n,=struct.unpack('<I',b[:4]);q=4;d={}
    for _ in range(n):
        l,=struct.unpack('<I',b[q:q+4]);q+=4;k=b[q:q+l].decode();q+=l;t=b[q];q+=1
        if t==2: l,=struct.unpack('<I',b[q:q+4]);q+=4;v=b[q:q+l].decode('utf8','replace');q+=l
        elif t==3: v=bool(b[q]);q+=1
        elif t==6: v,=struct.unpack('<d',b[q:q+8]);q+=8
        elif t==5: v,=struct.unpack('<f',b[q:q+4]);q+=4
        elif t==4: v,=struct.unpack('<i',b[q:q+4]);q+=4
        else: d[k]=f'type{t}';break
        d[k]=v
    return d
pat=re.compile(sys.argv[2])
for r,c in cls.items():
    p=path(r)
    if pat.search(p):
        sp=strprops.get(r,{})
        print(p,c,sp.get('AnimationId',b'').decode() if 'AnimationId' in sp else sp.get('SoundId',b'').decode() if 'SoundId' in sp else '',attrs(sp.get('AttributesSerialize',b'')))
