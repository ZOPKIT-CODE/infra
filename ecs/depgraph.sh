#!/usr/bin/env bash
# Render a focused Terraform dependency graph.
#
#   ./depgraph.sh staging                 # whole graph (dense; zoom in a viewer)
#   ./depgraph.sh staging valkey          # only nodes matching /valkey/ + neighbours
#   ./depgraph.sh staging 'rds|secret' 2  # regex, 2 hops out
#
# Needs graphviz (`brew install graphviz`). Writes ./depgraph-<env>.svg
set -euo pipefail

ENV="${1:?usage: depgraph.sh <staging|prod> [regex] [hops]}"
PATTERN="${2:-}"
HOPS="${3:-1}"
DIR="$(cd "$(dirname "$0")" && pwd)/terraform/environments/$ENV"
OUT="depgraph-${ENV}${PATTERN:+-$(echo "$PATTERN" | tr -cd '[:alnum:]')}.svg"

command -v dot >/dev/null || { echo "graphviz missing: brew install graphviz" >&2; exit 1; }

terraform -chdir="$DIR" graph > /tmp/_tf.dot

if [[ -z "$PATTERN" ]]; then
  dot -Tsvg /tmp/_tf.dot -o "$OUT"
else
  python3 - "$PATTERN" "$HOPS" <<'PY' > /tmp/_tf_sub.dot
import re, sys, collections
pat, hops = re.compile(sys.argv[1]), int(sys.argv[2])
edges = re.findall(r'"([^"]+)" -> "([^"]+)"', open('/tmp/_tf.dot').read())
adj = collections.defaultdict(set)
for a, b in edges:
    adj[a].add(b); adj[b].add(a)          # undirected for neighbourhood expansion
seed = {n for n in adj if pat.search(n)}
keep = set(seed)
for _ in range(hops):
    keep |= {m for n in list(keep) for m in adj[n]}
print('digraph g {\n  rankdir=RL;\n  node [shape=rect, style="rounded,filled", '
      'fontname="Helvetica", fontsize=10];')
for n in sorted(keep):
    hit = bool(pat.search(n))
    print(f'  "{n}" [fillcolor="{"#fdecc8" if hit else "#eef1f5"}", '
          f'color="{"#7a5b00" if hit else "#8a8f98"}"];')
for a, b in edges:
    if a in keep and b in keep:
        print(f'  "{a}" -> "{b}";')
print('}')
PY
  dot -Tsvg /tmp/_tf_sub.dot -o "$OUT"
fi
echo "wrote $OUT ($(grep -c '<g id="node' "$OUT" || echo 0) nodes)"
