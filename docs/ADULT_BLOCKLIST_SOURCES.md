# Adult Domain Blocklist Sources

This project's `data/adult-domains.txt` is generated from these pinned upstream datasets:

1. Bon-Appetit `porn-domains` (block list)
   - Repo: `https://github.com/Bon-Appetit/porn-domains`
   - Pinned raw URL:
     `https://raw.githubusercontent.com/Bon-Appetit/porn-domains/6113a623850e42df1643c1b6a322b61008f92f19/block.bf3755e532.hot0qe.txt`

2. 4skinSkywalker `Anti-Porn-HOSTS-File`
   - Repo: `https://github.com/4skinSkywalker/Anti-Porn-HOSTS-File`
   - Pinned raw URL:
     `https://raw.githubusercontent.com/4skinSkywalker/Anti-Porn-HOSTS-File/921fd38223f7e0a06d6d31fc233101a9f663b3cb/HOSTS.txt`

Generation command:

```bash
scripts/generate-adult-domains.sh
```

Runtime refresh behavior:
- Extension startup: load bundled `data/adult-domains.txt`, then fetch fresh upstream lists in background.
- Automatic refresh: every `15` minutes via background alarm (`adultListRefresh`).
- If remote refresh fails, the last loaded in-memory set remains active.

Latest generation in this workspace (2026-02-20):
- Unique normalized domains: `763990`
- File size: `15792394` bytes
