# Graph Report - tc-streaming  (2026-10-06)

## Corpus Check
- 12 files · ~8,887 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 3 file(s) not represented in the graph (top: .ini 2, .cfg 1)

## Summary
- 60 nodes · 98 edges · 7 communities (6 shown, 1 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `09999f2a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- server.py
- gateway.sh
- deploy.sh
- docker-entrypoint.py
- raw_source.py
- source-auth.sh
- ci-ssh-access.sh

## God Nodes (most connected - your core abstractions)
1. `deploy.sh script` - 7 edges
2. `gateway.sh script` - 7 edges
3. `start()` - 5 edges
4. `configure_source_auth()` - 5 edges
5. `main()` - 5 edges
6. `source-auth.sh script` - 5 edges
7. `Handler` - 4 edges
8. `ci-ssh-access.sh script` - 4 edges
9. `hc()` - 4 edges
10. `wait_actions()` - 4 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Import Cycles
- None detected.

## Communities (7 total, 1 thin omitted)

### Community 0 - "server.py"
Cohesion: 0.16
Nodes (3): allowed(), Handler, load_stations()

### Community 1 - "gateway.sh"
Cohesion: 0.38
Nodes (8): check(), compose(), free_port(), listen_bytes(), publish(), publish_chunked(), gateway.sh script, tone()

### Community 2 - "deploy.sh"
Cohesion: 0.53
Nodes (8): caddy_started_at(), compose(), install_bundle(), load_release(), log(), record(), deploy.sh script, start()

### Community 3 - "docker-entrypoint.py"
Cohesion: 0.42
Nodes (4): configure_source_auth(), main(), password(), required()

### Community 5 - "source-auth.sh"
Cohesion: 0.60
Nodes (5): check(), compose(), free_port(), publish(), source-auth.sh script

### Community 6 - "ci-ssh-access.sh"
Cohesion: 1.00
Nodes (4): hc(), remove_firewall(), ci-ssh-access.sh script, wait_actions()

## Knowledge Gaps
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Not enough signal to generate questions. This usually means the corpus has no AMBIGUOUS edges, no bridge nodes, no INFERRED relationships, and all communities are tightly cohesive. Add more files or run with --mode deep to extract richer edges._