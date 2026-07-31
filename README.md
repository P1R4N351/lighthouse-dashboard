# lighthouse-dashboard

What a visitor sees at `http://piranesi.local` on any network hosting a Piranesi
lighthouse. Seeded from The House of Piranesi homepage — see `PROVENANCE.md` for
the lineage and for why this is a seeded repo rather than a gitea fork.

The lighthouse is a guest on somebody else's network. This is the thank-you
note: a page listing what the device offers back to the people whose power and
port it is using. It is the **only** surface exposed to that untrusted LAN.

```
dashboard/     the bundle: templates + stylesheet + glyphs + version
dist/          the built, signed release the devices actually fetch
tools/         build-dashboard-bundle.sh — packs and signs a release
amenities.json shared canon (byte-identical to homepage + every image)
allowed_signers the PUBLIC verify key baked into every lighthouse
```

## How a device gets a new dashboard

`/opt/outpost/dashboard-sync.sh` on the device, daily, on a randomised timer.
It fetches three files — `MANIFEST.json`, `MANIFEST.json.sig`,
`dashboard.tar.gz` — from the first channel that answers.

### The problem this had to solve

This repo lives on gitea at `100.72.144.19:18792`, a **tailnet address**. A
lighthouse dropped on a stranger's network has no tailnet, so a `git pull` from
gitea would update nothing, forever, and say nothing about it. (There is also no
`git` binary on the base Armbian image — verified on the live board — so a git
transport was never available in the first place.) That exact shape of failure
kept the identity-anchor witness dead-by-construction for two months.

So: **the transport is never trusted, and never singular.**

| rung | reachable from | notes |
|---|---|---|
| `mesh` | the tailnet only | gitea raw. Skipped entirely when the device has no `tailscale0` |
| `public` | **any network** | a plain HTTPS mirror. This is the rung that works where the devices actually are |
| `onion` | any network permitting tor | via the tor SOCKS proxy the device already runs. Transport implemented; endpoint optional |

Every rung serves the same bytes and is verified identically: a detached
`ssh-keygen -Y` signature over a manifest naming the bundle's sha256, checked
against the trust root **baked into the image**. That is what makes it safe to
fetch over a hostile LAN, and it is why the public rung may fall back to plain
HTTP if a network forces it. It also sidesteps the no-RTC problem — signature
verification needs no correct clock, TLS chain validation does, and these boards
have no battery-backed clock.

A device that has no rung it can use **says so**: `offmesh_capable` and
`updatable_here` in `/run/outpost/dashboard.json`, and in plain words on the
page itself — *"no update channel reachable from here"*. It does not display a
version and let the reader assume it is fresh.

### What a bundle may contain

Data only: a flat set of `.tmpl` / `.css` / `.json` files. No directories, no
symlinks, nothing executable, nothing sourced or run. The device enforces this
before extracting, so the blast radius of a stolen release key is "the courtesy
page looks wrong", not code execution on the board.

The device additionally **refuses** any bundle containing an `.onion` address, a
tailnet or private IP, key material, or the word `allowed_signers` — an
authentic signature does not make a payload fit to put in front of a stranger.

### Failure semantics

Every failure is a no-op on the serving surface. Fetch, verify, gate and extract
all happen in a staging directory; the last step is a single `rename(2)` of the
`live` symlink. A partial download, a bad signature, a truncated tarball, a full
disk, a killed process — `live` still points at what was working before, and at
worst that is the bundle baked into the image, which is complete and styled. No
code path removes or rewrites a serving release in place.

Version is a monotonic integer and the device refuses anything not strictly
greater than what it is serving, so a signed-but-stale artifact replayed by
whoever controls the LAN cannot roll a lighthouse backwards.

## Cutting a release

```sh
# 1. edit dashboard/*, bump dashboard/bundle.json's version
# 2. build + sign (the private key never leaves the release host)
tools/build-dashboard-bundle.sh \
  --src dashboard --out dist --version <N> \
  --key ~/.ssh/lighthouse-dashboard-release
# 3. commit dist/ and push. Devices fetch dist/ by raw URL; there is no
#    release API in the path, so a plain push publishes it.
# 4. mirror to the public remote — WITHOUT it, only patriated devices update.
git push origin main && git push public main
```

Then confirm a device actually took it, rather than assuming:

```sh
curl -s http://<lighthouse>/dashboard.json          # guest view: version + serving
ssh <lighthouse> cat /run/outpost/dashboard.json    # full view: channel + detail
```

## Testing

The mechanism is proven hermetically by
`armbian-seed/tests/dashboard-update.sh` (62 assertions, no network): the
mesh-only trap, the off-mesh install, every refusal path leaving the previous
dashboard serving, the leak gate, and the redaction of update detail from the
guest surface.
