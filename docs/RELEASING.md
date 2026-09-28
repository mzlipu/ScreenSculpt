# Releasing a new version

One command builds the disk image and publishes it to the website. This page
is the surrounding procedure: what to do first, what each safety check means
when it stops you, and how to confirm afterwards that what people download is
what you built.

```bash
make release VERSION=0.1.3     # in ScreenSculpt
cd ../Apps_Portfolio_Site && git add -A && git commit -m "Release 0.1.3" && git push
```

That is the whole happy path. The rest of this page is why each part is there.

---

## Before you start

**1. Commit everything first.** The build number is `git rev-list --count HEAD`
— the commit count. Release from a dirty tree and that number describes code
that is not in the disk image. The script warns rather than refusing, because
sometimes you genuinely are testing, but on a real release treat the warning as
a stop sign.

```bash
git status --short        # expect no output
```

**2. Run the tests.**

```bash
make test                 # 267 tests, about 20 seconds, no window server needed
```

**3. Decide the version.** Three numbers, `MAJOR.MINOR.PATCH`:

| Change | Bump | Example |
|---|---|---|
| Bug fix, no new capability | patch | `0.1.2 → 0.1.3` |
| New feature, nothing removed or relearned | minor | `0.1.3 → 0.2.0` |
| Something works differently than users expect | major | `0.9.0 → 1.0.0` |

Two things to keep in mind. **Never reuse a version number** — the publish
script refuses, and the reason matters: anyone who already downloaded the old
build has a file that no longer matches the checksum on the site, with no way
to tell. And **each release costs every user a permissions re-grant**, because
the app is not notarised, so prefer fewer, larger releases to a stream of small
ones.

---

## Cutting the release

```bash
make release VERSION=0.1.3
```

In order, this:

1. writes `MARKETING_VERSION` into `Config/Version.xcconfig`
2. regenerates the Xcode project and builds Release, universal
3. asserts the binary really is universal — a single-arch build ships silently
   and only Intel users notice
4. signs with the local certificate, which gives a stable designated
   requirement so Screen Recording permission survives the update
5. builds `build/ScreenSculpt-0.1.3.dmg` and writes its `.sha256`
6. deletes the previous disk image from the website and copies this one in
7. writes `src/data/release.json` — version, build, date, size and checksum,
   all read from the bytes it just copied, never typed
8. runs the website's own check to confirm the two agree

Then commit and push the website:

```bash
cd ../Apps_Portfolio_Site
git add -A && git commit -m "Release 0.1.3" && git push
```

Cloudflare Pages rebuilds automatically. Also push the app repo:

```bash
cd ../ScreenSculpt && git push
```

---

## Testing the build you are about to ship

```bash
make install-release
```

This installs the **published** disk image into `/Applications` without
rebuilding. Use it rather than `make install`, which builds afresh: a rebuild
produces different bytes for the same version, so the copy you test would not
be the copy anyone downloads, and `make check-published` would start reporting
the site as out of date.

It also deletes other copies of the bundle from your Mac. macOS records a
permission grant against one *copy* of an app, and the Privacy list shows every
copy under the same name with no path — so a stray build in DerivedData is how
you end up granting Screen Recording to the wrong one and seeing black frames.

---

## When a check stops you

These exist because each one has already caught a real mistake.

### "Refusing to publish. Version X is already published, with different contents"

You changed the code but not the version. Bump it. `--force` exists only for
the case where the published build demonstrably never reached anyone.

### "Warning: the working tree has uncommitted changes"

The build number will not describe the disk image. Commit and cut again.

### "checksum mismatch" / "stale disk image" / "size mismatch"

The website's `release.json` disagrees with the file next to it. This runs as
`prebuild`, so it fails the Cloudflare deploy instead of publishing a wrong
checksum. It almost always means a file was copied in by hand. Re-run
`make release` and let it write both together.

### "OUT OF DATE — the site is serving different bytes from this build"

From `make check-published`. Either you have not published yet, or you rebuilt
after publishing. Rebuilding is the usual cause — see `make install-release`
above.

---

## Afterwards

```bash
make check-published
```

Expect `In sync`. It compares checksums, not version numbers — a version that
did not move while the contents did is the exact failure this is here to catch,
and it has happened once already: the site served a nine-day-old build under a
current-looking version number, and every visible signal agreed with every
other one while all of them described the wrong file.

Once Cloudflare has deployed, confirm what is actually being served:

```bash
curl -sI https://apps.lipu.bd/downloads/ScreenSculpt-0.1.3.dmg | grep -i 'content-type\|cache-control'
shasum -a 256 <(curl -sL https://apps.lipu.bd/downloads/ScreenSculpt-0.1.3.dmg)
```

The checksum must match the one on the download page. Because there is no
notarisation ticket, that checksum is the only integrity signal a visitor has.

Finally, run the install one-liner from the website verbatim — ideally on a
second Mac, which is the only way to find out what a new user actually sees.

---

## Things not to do

**Do not hand-edit `src/data/release.json`.** It is generated. A hand-copied
checksum is what caused the incident described above.

**Do not copy a `.dmg` into `public/downloads/` yourself.** The publish step
deletes the old one, copies the new one and writes the metadata as one action
precisely so they cannot disagree.

**Do not run `make install` after publishing.** It rebuilds. Use
`make install-release`.

**Do not reuse a version number.**

---

## Where things live

| | |
|---|---|
| `Config/Version.xcconfig` | the version, rewritten by `make release` |
| `scripts/release.sh` | the whole sequence |
| `scripts/make-dmg.sh` | build, sign, package |
| `scripts/publish-to-site.sh` | copy to the site, write metadata, refuse to overwrite |
| `scripts/check-published.sh` | compare built bytes against published bytes |
| `scripts/install-local.sh` | install without rebuilding |
| `../Apps_Portfolio_Site/scripts/check-release.mjs` | the deploy gate |

The website expects to be at `../Apps_Portfolio_Site`. Elsewhere, set
`SITE_DIR=/path/to/site`.
