# Packaging on the openSUSE Build Service (OBS)

The framework is packaged for **Proxmox VE 9** (Debian 13 "Trixie" base) on
[obs.opensuse.org](https://build.opensuse.org) under the project
**`home:ciriarte:pve-FCLUPlugin`**.

> **ALPHA software.** The built `.deb`s are for lab/test use only until the
> framework has been validated against a live array.

## Layout

| OBS object | Value |
|------------|-------|
| Project    | `home:ciriarte:pve-FCLUPlugin` |
| Package    | `pve-fclu` (one **native** source package → three binaries) |
| Binaries   | `pve-fclu-core`, `pve-fclu-hitachi`, `pve-fclu` (metapackage) |
| Repository | `PVE_9` (named after the PVE release, not the Debian base, to avoid confusion) |
| Build base | `Debian:13/standard` |
| Arch       | `x86_64` (Debian `amd64`) |

The repository is deliberately named `PVE_9` rather than `Debian_13`: users pick it
by the Proxmox release they run, even though the underlying base is Debian 13.

## Building the source package

OBS builds Debian packages from a `3.0 (native)` source package (a single source
tarball + `.dsc`). This repo generates those without needing `dpkg-dev`:

```sh
tools/make-obs-source.sh        # writes build/obs/pve-fclu_<version>.{tar.xz,dsc}
```

The version comes from `debian/changelog`. Always commit your changes first — the
script packages from `git HEAD` and refuses to run with a dirty `debian/` or
`version.mk`.

## Publishing to OBS

```sh
# one-time: create the project + repository (PVE_9 -> Debian:13/standard)
osc meta prj    home:ciriarte:pve-FCLUPlugin -F packaging/obs/_meta
osc meta prjconf home:ciriarte:pve-FCLUPlugin -F packaging/obs/_config

# per release: bump version.mk + debian/changelog, commit, then
git tag -a v<version> -m "<deb-version>"   # git refs use '-' not '~'
git push origin master --tags

tools/make-obs-source.sh
osc co home:ciriarte:pve-FCLUPlugin pve-fclu
cp build/obs/* home:ciriarte:pve-FCLUPlugin/pve-fclu/
cd home:ciriarte:pve-FCLUPlugin/pve-fclu/
osc addremove
osc commit -m "pve-fclu <version>"
```

> **Always tag the release commit.** Tags map the Debian version (`0.1.0~alpha1`) to
> a git commit; `~` is illegal in a git ref, so the tag uses `-`
> (e.g. `v0.1.0-alpha1`). The version is taken from `debian/changelog`.

OBS rebuilds on every commit. Watch progress with:

```sh
osc results  home:ciriarte:pve-FCLUPlugin
osc buildlog home:ciriarte:pve-FCLUPlugin PVE_9 x86_64
```

## Why it builds against plain Debian 13 (no Proxmox in the chroot)

The PVE Perl modules (`PVE::Storage::Plugin` — the `use base` parent of the plugin —
plus `PVE::Tools`) ship in Proxmox's repositories, **not** in the Debian 13 base OBS
builds against. They are therefore *runtime* dependencies (covered by
`Depends: proxmox-ve`), never build dependencies.

The build never evaluates them because it does not compile the plugin against PVE:
`dh_install`/`make install` only *copy* the `.pm` files, and `dh_auto_test` runs the
unit suite, which BEGIN-stubs the PVE framework and loads only the FCLU modules +
`Driver::Hitachi::RestClient` (which needs just `JSON` and `LWP`, declared in
`Build-Depends`). Do **not** add the `PVE::*` modules to `Build-Depends` — they are
unresolvable on Debian and would break the build.

## Installing the built packages (on a PVE 9 node)

Once the build succeeds and the repository publishes:

```sh
echo 'deb http://download.opensuse.org/repositories/home:/ciriarte:/pve-FCLUPlugin/PVE_9/ /' \
  > /etc/apt/sources.list.d/pve-fclu.list
curl -fsSL https://download.opensuse.org/repositories/home:/ciriarte:/pve-FCLUPlugin/PVE_9/Release.key \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/home_ciriarte_pve-fclu.gpg
apt update
# install the driver for your array; it pulls pve-fclu-core transitively:
apt install pve-fclu-hitachi
systemctl restart pvedaemon
```

`apt install pve-fclu-hitachi` supersedes the standalone `pve-storage-hitachiblock`
package; existing `type: hitachiblock` storage.cfg entries keep working. It re-ships
the web UI storage panel and the opt-in SCSI-3 PR systemd units (installed disabled);
only the `hitachiblock-repl` replication CLI remains deferred (it needs a rewrite
against the FCLU internals). Restart `pvedaemon`/`pveproxy` after install so the
plugin and its UI panel register.
