# flowlab — project memory

Auto-loaded index of flowlab-specific working memory (cross-cutting facts live in the
hub, `.claude/hub/memory/`, via `[[hub:name]]`). See `CLAUDE.md` for the architecture and
the hard-won learnings (pmacct/Akvorado, the netavark-UDP pivot to NixOS-native, the
enricher gates, macOS pcap direction, ASN/GeoIP enrichment).

## Active

- **Bootstrap** — repo created (`seedmatic/flowlab`), external-worktree layout, claude-hub
  subtree at `.claude/hub`. Next: `modules/akvorado.nix` (services.akvorado, 4 systemd units,
  inlet host-bound :2055), migrate the `netflow-probe` bundle from `ndh`, Incus NixOS image.
- **Open** — pcap capture completeness on macOS still to be validated on a reliable native
  endpoint (a clean 20 MB download must show ~20 MB captured).
