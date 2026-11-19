# Josi on Fedora and Bazzite

Built 2026-11-17 (Linux beta.38). The Fedora family is the third kind of package after Debian/Ubuntu and Arch: `josi-<version>.<arch>.rpm`, built from the same payload as the `.deb`.

## Who it is for

- **Fedora Workstation and Server** (and CentOS Stream, RHEL and clones that have `dnf`): the package goes in with `dnf`.
- **Image-based Fedoras: Bazzite, Silverblue, Kinoite, Aurora, Bluefin, CoreOS** (`/usr` is read-only, packages are part of the system image): the package is added to the image with `rpm-ostree`.

## Install

The same one command as everywhere (it finds the family itself):

```
curl -fsSL <install host>/linux | sudo bash
```

or, from a release folder with no download: `sudo ./install.sh` (add `--yes` and the flags of `--help` to skip the questions).

- **Fedora Workstation/Server:** what Josi needs (`python3 rsync acl iproute libstdc++ ca-certificates policycoreutils-python-utils`) is installed with `dnf` if missing, then the rpm, then Josi starts.
- **Bazzite and the other image-based systems:** anything missing and the Josi rpm go into the system image in one `rpm-ostree install --apply-live` change. On a first install that is applied to the running system, so **no restart** and Josi starts at once. After a restart the layered packages are still there and Josi starts by itself.
- **An update on an image-based system** replaces the package in the image, which only takes effect after a restart: the installer says so ("Restart this computer, then run the same command again to finish"). After the restart, run the same command again.
- Josi's own browser (`--browser`) and PC control work as elsewhere; on an image-based system the X11-only desktop helpers (xdotool, wmctrl, scrot) are not added to the image.

## What is different from Debian and Ubuntu (and what the installer does about it)

- **SELinux** is on and enforcing on all of these. Services may not run a program kept under `/var/lib` unless it is labelled as one, so the installer labels Josi's program folders (`/var/lib/josi/versions`, `/var/lib/josi-pc`) `bin_t` (a rule in the local policy with `semanage fcontext`, then `restorecon`), the way the policy treats a program an administrator installs. Josi's services then run as `unconfined_service_t`. Nothing is turned off: `getenforce` still says Enforcing and there were no denials in the tests.
- **firewalld** is on by default and closes the port. The installer opens the Josi port (and 80 and 443 in "public domain" mode) in the default zone, permanently. The uninstaller leaves that rule in place for the administrator to remove.
- **The web updater** is written to update a Fedora Workstation/Server install (it runs `dnf install` on the downloaded, checksummed package; **not tried**). On an image-based system it says to run the install command again (a restart is needed anyway).

## Remove

`sudo josi-uninstall` (keeps the data) or `sudo josi-uninstall --purge` (removes the data and the SELinux rules). On an image-based system the package leaves the image at the next restart.

## What was tried (and what was not)

Built on the build machine as `josi-1.2.8-beta.38.x86_64.rpm` (711 MB, unsigned; same ghost-asset check as the other packages). Tried in virtual machines on the build machine:

| Where | Result |
|---|---|
| Fedora 44 Cloud, SELinux Enforcing, firewalld on, `dnf` | Fresh install from the release folder with `--browser`: services active, program labelled `bin_t`, services in `unconfined_service_t`, no SELinux denials, port opened in firewalld and answering, `e2e-fake` passed (rc 0), `e2e-pc` 9/9, `e2e-signin` 5/5 (Josi's own Chrome, live view, terminal login). Running the installer again (repair) worked; `josi-uninstall` removed the rpm and stopped Josi. |
| Fedora CoreOS 44 (immutable `/usr`, rpm-ostree, SELinux Enforcing; stands in for Bazzite, which is built the same way) | First install: `python3` and `policycoreutils-python-utils` were layered with the Josi rpm in one change and applied live; Josi running, labelled, no denials, `e2e-fake` rc 0. After a restart Josi came back by itself. `josi-uninstall --purge` queued the package removal; it was gone after a restart. The update case was tried with two small test packages named `josi`: the first installs live; replacing it with a newer one is queued for the next boot, the running one stays until then, and running the install again after the restart changes nothing. |

**Not tried:** Bazzite itself (no machine and no image to run here; it is Fedora Atomic like CoreOS, with a desktop and, on gaming hardware, NVIDIA drivers); a Josi update with the real 700 MB package on an image-based system (the replacement was tried with small packages); RHEL, CentOS Stream, Rocky and Alma; Fedora 42, 43 and 45; the aarch64 rpm (built only for x86_64 in this build; `build-release.sh --arm64` makes it); Wayland: PC control's screenshots and clicks use X11 tools, so on a Wayland desktop (Bazzite's default) they do not work, while commands, files, terminals and Josi's own browser (on a hidden X screen) do; the model: Bazzite machines with a GPU usually run Ollama separately and Josi finds it on `127.0.0.1:11434`.

## Where things are

- The package: `scripts/linux/build-rpm.py` (the `%files`, the scriptlets, the dependencies), named in `package_common.package_names()` as `rpm-<processor>`.
- The installer: `packaging/linux/install-josi-ce-server.sh` (`atomic`, `rpm_tool`, `rpm_missing`, `rpm_browser_packages`, `open_firewall`).
- SELinux: `Lifecycle.label_for_services` in `packaging/linux/lifecycle.py` (runs on every install and upgrade; tests in `test_lifecycle.py`).
- The web updater: `family()` and `package_install()` in `packaging/linux/josi_update.py`. The update feed carries `rpm-x86_64`.
