import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("  (no result json:", e, ")"); sys.exit()
r = d.get('result', '') or ''
rc = re.search(r'ROOT CAUSE:\s*(.+)', r)
cf = re.search(r'CONFIDENCE:\s*(\w+)', r)
print(f"  turns={d.get('num_turns')} cost=${d.get('total_cost_usd',0):.3f} conf={cf.group(1) if cf else '?'}")
print("  cause:", (rc.group(1).strip()[:150] if rc else r[:150].replace('\n',' ')))
