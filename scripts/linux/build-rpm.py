"""Build the unsigned Fedora package `josi` (an .rpm) without installing it.

The same payload as the .deb and the Arch package: the program in /usr/lib/josi,
the installer and uninstaller in /usr/bin. For Fedora Workstation and Server
(dnf install ./josi-....rpm) and for the atomic desktops built on Fedora,
Bazzite among them (rpm-ostree install ./josi-....rpm, then a restart).
Josi itself keeps nothing in /usr but this payload: the running program is a
copy in /var/lib/josi and its data and units live in /var and /etc, which an
atomic system lets a program write.
"""
import json
import shutil
import subprocess
import os

from package_common import (BASE, OUT, PACKAGE, SOURCE_DATE_EPOCH, package_names, populate_root, record_checksum,
    rpm_version_release, staged_architecture)

BUILD_IMAGE = 'local/josi-ce-linux-package-build:debian12'

UNITS = ('josi.service josi-update.path josi-update.timer josi-pc.service josi-browser.service '
    + ' '.join(f'josi-ce-{role}.service' for role in ('database', 'voice', 'voice-control', 'web', 'worker', 'proxy')))


def spec_text(processor: str, version: str, release: str, root: str) -> str:
    return f'''%global debug_package %{{nil}}
%global __os_install_post %{{nil}}
%global _build_id_links none
%global __strip /bin/true
%global _unpackaged_files_terminate_build 0
Name: {PACKAGE}
Version: {version}
Release: {release}
Summary: Josi server, headless, run by systemd as josi.service
License: AGPL-3.0-or-later
URL: https://github.com/vaxman14/josi-ce
BuildArch: {processor}
AutoReqProv: no
Requires: python3 >= 3.10, systemd, rsync, acl, iproute, libstdc++, ca-certificates
Recommends: policycoreutils-python-utils
Conflicts: josi-ce-server-setup
Obsoletes: josi-ce-server-setup

%description
Josi's private PostgreSQL, Node, Python, Caddy and CPU speech runtime. Setup,
sign-in, chat, settings and updates all happen in the browser.

%install
mkdir -p %{{buildroot}}
# Hard links: the payload is about 2 GB and the build folder is one filesystem.
cp -al {root}/. %{{buildroot}}/

%files
%defattr(-,root,root,-)
/usr/bin/josi-ce-server-install
/usr/bin/josi-ce-native-status
/usr/bin/josi-uninstall
/usr/lib/{PACKAGE}
/usr/share/doc/{PACKAGE}

# A removal stops and disables Josi first: its units live in /etc/systemd/system
# and run the program kept in /var/lib/josi, so left enabled they would start
# again at the next boot. Its data stays unless josi-uninstall --purge is used.
# An upgrade leaves them alone ($1 is 1 then). On an image-based system the
# scriptlets also run while the image is made, with no systemd: they do nothing.
%post
find /usr/lib/{PACKAGE}/runtime -type d -name __pycache__ -prune -exec rm -rf {{}} + 2>/dev/null || true

%preun
if [ "$1" = 0 ] && [ -d /run/systemd/system ]; then
  systemctl disable --now {UNITS} >/dev/null 2>&1 || true
fi

%postun
if [ "$1" = 0 ] && [ -d /run/systemd/system ]; then
  systemctl disable {UNITS} >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
'''


def main() -> None:
    processor = staged_architecture()
    root = BASE / 'rpm-root'
    populate_root(root, root / f'usr/share/doc/{PACKAGE}/copyright')
    top = BASE / 'rpmbuild'
    shutil.rmtree(top, ignore_errors=True)
    for name in ('BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS'):
        (top / name).mkdir(parents=True)
    version, release = rpm_version_release()
    spec = top / 'SPECS' / f'{PACKAGE}.spec'
    spec.write_text(spec_text(processor, version, release, str(root)))
    command = ['docker', 'run', '--rm', '--pull=never', '--user', f'{os.getuid()}:{os.getgid()}',
        '-e', f'SOURCE_DATE_EPOCH={SOURCE_DATE_EPOCH}', '-e', f'HOME={BASE}/rpm-home',
        '-v', f'{BASE}:{BASE}', BUILD_IMAGE, 'rpmbuild', '-bb', '--target', f'{processor}-linux',
        '--define', f'_topdir {top}', '--define', '_binary_payload w19T0.zstdio', '--define', '_buildhost josi-build',
        '--define', 'use_source_date_epoch_as_buildtime 1', '--define', 'clamp_mtime_to_source_date_epoch 1', str(spec)]
    subprocess.run(command, check=True)
    built = next((top / 'RPMS' / processor).glob(f'{PACKAGE}-*.rpm'))
    package = OUT / package_names()['rpm-' + processor]
    package.unlink(missing_ok=True)
    shutil.copy2(built, package)
    shutil.rmtree(top, ignore_errors=True)
    shutil.rmtree(root, ignore_errors=True)
    digest = record_checksum(package)
    print(json.dumps({'package': str(package), 'bytes': package.stat().st_size,
        'sha256': digest, 'signed': False, 'target': 'Fedora ' + processor}))


if __name__ == '__main__':
    main()
