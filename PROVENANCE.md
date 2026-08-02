# Provenance — and why this is SEEDED, not a gitea fork

## Lineage

This repo's visual language comes from **The House of Piranesi** homepage:

| | |
|---|---|
| upstream repo | `piranesi/homepage` on gitea `100.72.144.19:18792` |
| upstream commit at seeding | `771480f5f0a0c8dcb742f5cc3b8550470d69f188` (2026-07-29) |
| files the design was taken from | `index.html` (the `:root` token block, `.desk`, `.amen*`, `footer`) |
| shared canon | `amenities.json` — the homepage repo owns it and the image bakes it verbatim; **this repo carries the public mirror**: canon minus every mesh-private row (see the file's own `provenance` field, and "the mirror is a subset" below) |

Inherited verbatim: the `:root` custom properties (`--ink`, `--muted`, `--glass`,
`--glass-edge`, `--bronze` `#E0B278`, the SF font stack), the layered
radial-gradient over `linear-gradient(157deg,…)` background, the `body::before`
vignette, the `.desk` container, the glass-card idiom, the `halo` keyframe
animation, and the amenity-row layout.

Deliberately not carried across: the clock, the live search box, the folder
tiles and their popovers, and `catalog.js` in its entirety. Those are
JS-driven and were not ported. Since 2026-07-31 the template carries one
deliberate inline script — the dependency-free sun-engine (realtime solar
arc + solar-noon glyph alignment), byte-shared with the homepage; with
scripts blocked the page degrades to the static night view.

## The decision: a new repo seeded from the homepage, NOT `gitea fork`

The brief asked for a fork. It is the wrong instrument here, for three reasons
that all point the same way.

**1. A fork would publish the fleet's topology.** `catalog.js` in the homepage
repo contains **16 distinct internal identifiers** — 10 CGNAT `100.x` tailnet
addresses and 6 `*.ts.net` MagicDNS names, each paired with a service and a
port. That is a map of the household's internals. The dashboard's whole reason
for existing is to be readable by strangers on foreign networks, and its
off-mesh update path (see `README.md`) requires a **public** mirror. Forking
would drag that map into the public mirror — not only in `HEAD`, where it could
be deleted, but through the entire commit history, where it cannot be. Removing
it afterwards would need a history rewrite and a force-push, which is
Layer-2-gated and in any case never reaches clones that already exist. The
cheapest moment to not publish something is before it is published.

**2. Upstream merges would be a permanent leak-review tax.** The homepage
evolves by *adding tiles that point at new internal services*. Every
`git merge upstream/main` would therefore import new topology into a
guest-facing repo, and each one would need a human to notice. A control that
must be exercised correctly on every future merge, forever, is not a control.

**3. There is very little code to inherit.** The homepage is a ~15 KB
single-page app plus an 18 KB tile catalogue. The dashboard is a set of
templates a Python stdlib HTTP server fills in on a 2 GB SD-only board. The
genuinely shared surface — design tokens, the glass-card idiom, the glyph set,
`amenities.json` — is a couple of hundred lines. Inheriting 40-odd commits of
unrelated history to share that is cost without benefit.

(A gitea fork is also mechanically awkward: gitea will not fork a repo into the
org that already owns the parent without a rename, so it would have needed a
second org to exist for filing reasons alone.)

## What replaces the fork relationship

Seeding loses the automatic `git merge upstream/main` path, so the lineage is
recorded instead of implied:

* the upstream repo and the exact commit are pinned at the top of this file;
* `amenities.json` is guarded on BOTH of its relations by
  `armbian-seed/tests/smoke.sh` — see "the mirror is a subset" below;
* `dashboard/dashboard.css` names its origin in its header comment.

### The mirror is a subset, not a copy

This file used to say `amenities.json` was "byte-identical here, in the homepage
repo, and baked into every lighthouse image". That was never true and was never
meant to be — and because nothing tested this repo's copy, nothing said so. On
2026-08-01 the three files had three distinct md5s. The real relation is a
ladder of two links, and `armbian-seed/tests/smoke.sh` now asserts both:

| link | assertion |
|---|---|
| homepage canon → baked image copy | byte-identical (`amenities canon identical`) |
| homepage canon → **this repo** | canon minus exactly the mesh-private rows (`amenities mirror == canon minus exactly the mesh-private entries`), plus a leak gate (`amenities mirror carries no tailnet/onion address`) |

The second link is deliberately anchored to canon rather than to the image, so a
lagging re-bake cannot move the mirror's contract. What the mirror may withhold
is bounded: a row or a whole block may be dropped only if every URL under it is
mesh-private (`.onion`, `*.ts.net`, RFC1918, or CGNAT/tailnet `100.64/10`). It
may not drop anything public, may not carry a row canon lacks, may not let a
shared row drift, and may not invent fields. Only `provenance` is free to
differ, because each copy has to explain what *it* is. Withholding the
`services` block in full (House Cinema, Audiobooks, the standing invitation —
every URL mesh-private) is exactly the case this permits.

When the House's visual language changes, the port across is still a
deliberate, reviewed act by hand -- which, given point 2, is the property worth
having. What is no longer by hand is *noticing that it did not happen*. Four
blocks are shared with the homepage, and `armbian-seed/tests/smoke.sh` asserts
all four against canon on BOTH sides -- never the baked image, so a lagging
re-bake cannot satisfy them:

| block | check | contract |
|---|---|---|
| sun-engine v11 CSS | `shared block: sun-css` | byte-identical inside its fences |
| sun-engine v11 script | `shared block: sun-js` | byte-identical inside its fences |
| `:root` design tokens | `shared block: root-tokens` | every token the homepage defines exists here with the same value; extra tokens here are allowed (`--faint`) |
| body background + `body::before` vignette | `shared block: body-background` | same declared values |

The last two are compared as parsed CSS rather than as bytes, because these
copies are deliberately reformatted -- the `--sf` font stack is split over two
lines here -- so whitespace between tokens is normalised while whitespace inside
quoted font names is not. A vanished fence FAILS rather than matching nothing:
an extractor that quietly finds zero bytes is a drift guard that has stopped
guarding.

The sentence this paragraph replaced asked a human to run that diff. Nobody was
scheduled to.

## Trust root

`allowed_signers` holds the **public** half of the dashboard release key
(`SHA256:t2U1BDwHcyZf27Aohz6k8HSAi6ds1gNhgSbPojUdY0M`). The same bytes are baked
into every image at `/etc/piranesi/dashboard/allowed_signers`. The private half
never enters this repo, any image, or any device — a lighthouse can *verify*
releases and can never *make* one.

Rotation does **not** ride this channel: a trust root delivered over the channel
it secures secures nothing. New key material reaches devices by reflash or by
configuration management, and `dashboard-sync.sh`'s leak gate refuses any bundle
containing the string `allowed_signers` precisely so nobody can quietly try.
