import sys, struct, lz4.block, zstandard, os, json, re
data=open(sys.argv[1],'rb').read(); out=sys.argv[2]
p=32
classes={}; inst={}; props={}  # ref->class
def rd_inter(b,n):
    res=[]
    for i in range(n):
        v=(b[i]<<24)|(b[n+i]<<16)|(b[2*n+i]<<8)|b[3*n+i]
        v=(v>>1)^(-(v&1))
        res.append(v)
    return res
def refs(b,n):
    r=rd_inter(b,n); acc=0; o=[]
    for v in r: acc+=v; o.append(acc)
    return o
strprops={}  # ref -> {prop:str}
parent={}
while p<len(data):
    name=data[p:p+4]; cl,ul=struct.unpack('<II',data[p+4:p+12]); p+=16
    if cl==0: body=data[p:p+ul]; p+=ul
    else:
        raw=data[p:p+cl]; p+=cl
        body=zstandard.ZstdDecompressor().decompress(raw,max_output_size=ul) if raw[:4]==b'\x28\xb5\x2f\xfd' else lz4.block.decompress(raw,uncompressed_size=ul)
    if name==b'INST':
        cid,ln=struct.unpack('<II',body[:8]); cn=body[8:8+ln].decode(); q=8+ln+1
        n,=struct.unpack('<I',body[q:q+4]); q+=4
        rs=refs(body[q:q+4*n],n); classes[cid]=(cn,rs)
    elif name==b'PROP':
        cid,ln=struct.unpack('<II',body[:8]); pn=body[8:8+ln].decode(); q=8+ln; t=body[q]; q+=1
        if t==1 and cid in classes:
            for r in classes[cid][1]:
                l,=struct.unpack('<I',body[q:q+4]); q+=4
                strprops.setdefault(r,{})[pn]=body[q:q+l]; q+=l
        elif pn in('Value',) : pass
    elif name==b'PRNT':
        n,=struct.unpack('<I',body[1:5]); c=refs(body[5:5+4*n],n); pa=refs(body[5+4*n:5+8*n],n)
        parent.update(zip(c,pa))
    elif name==b'END\x00': break
cls={}
for cid,(cn,rs) in classes.items():
    for r in rs: cls[r]=cn
def nm(r): return strprops.get(r,{}).get('Name',b'?').decode('utf8','replace')
def path(r):
    s=[]
    while r is not None and r!=-1 and r in cls:
        s.append(nm(r)); r=parent.get(r)
    return '/'.join(reversed(s))
tree=open(out+'/tree.txt','w')
for r in cls: tree.write(f"{path(r)}\t{cls[r]}\n")
n=0
for r,c in cls.items():
    if c in('Script','LocalScript','ModuleScript'):
        src=strprops.get(r,{}).get('Source',b'')
        fp=os.path.join(out,'src',re.sub(r'[^\w/.-]','_',path(r))+'.'+c+'.lua')
        os.makedirs(os.path.dirname(fp),exist_ok=True); open(fp,'wb').write(src); n+=1
print('scripts',n,'instances',len(cls))
