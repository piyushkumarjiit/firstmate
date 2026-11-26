import sys
pacing=int(sys.argv[2])
rows=[]
for line in open(sys.argv[1]):
    p=line.rstrip('\n').split('|',3)
    if len(p)<4: continue
    ts,kind,acct,args=p
    if args not in ('-p /usage','models'): continue
    rows.append((int(ts),kind,acct))
rows.sort()
ivs=[]; open_iv={}
for t,k,a in rows:
    if k=='start': open_iv.setdefault(a,[]).append(t)
    elif k=='end' and open_iv.get(a):
        s=open_iv[a].pop(0); ivs.append((s,t,a))
ivs.sort()
print("live query intervals (ms):", ivs)
overlap=[(x,y) for i,x in enumerate(ivs) for y in ivs[i+1:] if x[0] < y[1] and y[0] < x[1]]
print("overlapping live queries:", overlap)
bad=[]
for i in range(len(ivs)-1):
    gap=ivs[i+1][0]-ivs[i][1]
    if ivs[i][2]!=ivs[i+1][2] and gap < (pacing-1)*1000:
        bad.append((ivs[i][2],ivs[i+1][2],gap))
print("different-account gaps below pacing (allowing 1s clock granularity):", bad)
same=[ivs[i+1][0]-ivs[i][1] for i in range(len(ivs)-1) if ivs[i][2]==ivs[i+1][2]]
print("same-account back-to-back gaps (ms):", same)
ok = ivs and not overlap and not bad
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
