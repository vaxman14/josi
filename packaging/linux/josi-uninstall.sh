#!/bin/bash
# Remove the Josi server from this computer.
#
#   sudo josi-uninstall                  stop Josi and remove the program; keep the data
#   sudo josi-uninstall --purge          also delete /var/lib/josi, /etc/josi and Josi's accounts
#   sudo josi-uninstall --with-ollama    also remove Ollama and its models (the AI model, about 6 GB)
#   sudo josi-uninstall --keep-ollama    never remove Ollama or the model, and do not ask
#
# Without --purge, running the install command again brings Josi back with its
# accounts, chats and settings. With --purge in a terminal it asks whether Ollama and the
# model should go too. Every step is shown with a bar, and the slow ones show that they are alive.
set -uo pipefail

purge=0 ollama=ask
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    --with-ollama) ollama=yes ;;
    --keep-ollama) ollama=no ;;
    *) echo 'usage: sudo josi-uninstall [--purge] [--with-ollama | --keep-ollama]' >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo 'josi-uninstall: run it as root (with sudo, or from a root shell)' >&2; exit 1; }

export PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8
root=/var/lib/josi
roles='database voice voice-control web worker proxy'
children=$(for role in $roles; do printf 'josi-ce-%s.service ' "$role"; done)

# ---- what is here, so the questions and the bar are exact
have_ollama=0
if command -v ollama >/dev/null 2>&1 || systemctl cat ollama >/dev/null 2>&1 || [ -d /var/lib/ollama ] || [ -d /usr/share/ollama ]; then have_ollama=1; fi
ollama_kb=0
if [ "$have_ollama" = 1 ]; then
  for d in /var/lib/ollama /usr/share/ollama /usr/local/lib/ollama /usr/lib/ollama; do
    [ -d "$d" ] && ollama_kb=$((ollama_kb + $(du -sk "$d" 2>/dev/null | awk '{ print $1 + 0 }')))
  done
fi
if [ "$ollama" = ask ]; then
  ollama=no
  if [ "$have_ollama" = 1 ] && [ "$purge" = 1 ] && [ -t 0 ] && [ -t 1 ]; then
    printf 'Ollama and the AI model are installed (%s GB). Remove them too? [y/N] ' "$((ollama_kb / 1048576))"
    read -r reply || reply=n
    case "${reply,,}" in y | yes) ollama=yes ;; esac
  elif [ "$have_ollama" = 1 ]; then
    echo "Ollama and the AI model ($((ollama_kb / 1048576)) GB) are left alone; add --with-ollama to remove them."
  fi
fi
[ "$have_ollama" = 1 ] || ollama=no

# ---- the steps and the bar
steps=('Stopping Josi' 'Removing PC control and the browser' 'Stopping the services' 'Removing the system files' 'Removing the Josi package')
[ "$purge" = 1 ] && steps+=('Removing the data and the accounts')
[ "$ollama" = yes ] && steps+=('Removing Ollama and the AI model')
total=${#steps[@]} n=0 width=28 tty=0
[ -t 1 ] && tty=1
bar() { # $1 done count, $2 label, $3 extra text
  local filled=$(($1 * width / total)) i b=''
  for ((i = 0; i < width; i++)); do if [ "$i" -lt "$filled" ]; then b+='#'; else b+='-'; fi; done
  if [ "$tty" = 1 ]; then printf '\r\033[K  [%s] %d/%d  %s%s' "$b" "$1" "$total" "$2" "${3:+ ($3)}"; else printf '  [%s] %d/%d  %s%s\n' "$b" "$1" "$total" "$2" "${3:+ ($3)}"; fi
}
# Runs one step: shows it, and while a slow command works shows the seconds so it never looks stuck.
step() { # $1 label; the commands are the function named by $2
  n=$((n + 1))
  local start=$SECONDS pid
  bar $((n - 1)) "$1"
  "$2" >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.5
    [ "$tty" = 1 ] && bar $((n - 1)) "$1" "$((SECONDS - start)) s"
  done
  wait "$pid" 2>/dev/null
  bar "$n" "$1" "done in $((SECONDS - start)) s"
  [ "$tty" = 1 ] && printf '\n'
  return 0
}

version=$(python3 -I -c 'import json;print(json.load(open("/var/lib/josi/data/config/runtime.json"))["version"])' 2>/dev/null || true)
kept=0

s_stop() {
  systemctl disable --now josi-update.path josi-update.timer
  systemctl stop josi-update.service josi-update-check.service
  systemctl disable josi.service $children
}
s_pc() {
  # The executor runs as a person's own account, so it goes in either case; the install command sets it up again.
  systemctl disable --now josi-browser.service josi-pc.service
  rm -f /etc/systemd/system/josi-browser.service /etc/systemd/system/josi-pc.service
  if [ -f /etc/apparmor.d/josi-chrome ]; then apparmor_parser -R /etc/apparmor.d/josi-chrome || true; rm -f /etc/apparmor.d/josi-chrome; fi
  rmdir /etc/systemd/system/josi.service.wants 2>/dev/null
  rm -f /usr/lib/josi/josi-browser-host /etc/opt/chrome/native-messaging-hosts/com.heyjosi.browser.json \
    /etc/chromium/native-messaging-hosts/com.heyjosi.browser.json /etc/opt/edge/native-messaging-hosts/com.heyjosi.browser.json \
    /usr/lib/mozilla/native-messaging-hosts/com.heyjosi.browser.json
}
s_services() {
  # The lifecycle's own uninstall stops the services and moves their unit files aside with a record,
  # so the next install recognises them as Josi's.
  if [ -n "$version" ] && [ -x "$root/versions/$version/python/bin/python3.12" ]; then
    if "$root/versions/$version/python/bin/python3.12" -I -B "$root/versions/$version/app/native/maintenance.py" uninstall; then
      echo 1 > /run/josi-uninstall-kept
    fi
  fi
  systemctl stop josi.service $children
}
s_files() {
  rm -f /etc/systemd/system/josi.service /etc/systemd/system/josi-update.path /etc/systemd/system/josi-update.service \
    /etc/systemd/system/josi-update-check.service /etc/systemd/system/josi-update.timer
  if [ "$purge" = 1 ]; then for role in $roles; do rm -f "/etc/systemd/system/josi-ce-$role.service"; done; fi
  systemctl daemon-reload
  groupdel josi-pc
}
s_package() {
  if command -v pacman >/dev/null 2>&1; then
    pacman -Q josi && pacman -R --noconfirm josi
  elif command -v apt-get >/dev/null 2>&1; then
    dpkg -s josi && DEBIAN_FRONTEND=noninteractive apt-get remove -y -q josi
  elif command -v rpm >/dev/null 2>&1; then
    if [ -e /run/ostree-booted ] && command -v rpm-ostree >/dev/null 2>&1; then
      # Bazzite and the other image-based Fedoras: leaves the system image at the next restart.
      if rpm -q josi && rpm-ostree uninstall -y josi; then echo 1 > /run/josi-uninstall-restart; fi
    else
      rpm -q josi && { dnf remove -y josi || yum remove -y josi; }
    fi
    # The SELinux labels the installer set (the firewall port it opened is left for the administrator).
    if command -v semanage >/dev/null 2>&1 && [ "$purge" = 1 ]; then
      semanage fcontext -d '/var/lib/josi/versions(/.*)?'
      semanage fcontext -d '/var/lib/josi-pc(/.*)?'
    fi
  fi
}
s_data() {
  rm -rf -- "$root" /etc/josi
  for account in josi-ce-database josi-ce-voice josi-ce-control josi-ce-web josi-ce-worker josi-ce-proxy; do
    userdel "$account"
    groupdel "$account"
  done
  groupdel josi-ce-app
  groupdel josi-ce-voice-shared
  # The executor's own state (its key); systemd made it for StateDirectory=.
  rm -rf -- /var/lib/josi-pc /var/lib/private/josi-pc
}
s_ollama() {
  systemctl disable --now ollama
  rm -rf /etc/systemd/system/ollama.service /etc/systemd/system/ollama.service.d /etc/systemd/system/default.target.wants/ollama.service
  systemctl daemon-reload
  if command -v pacman >/dev/null 2>&1 && pacman -Q ollama; then pacman -R --noconfirm ollama $(pacman -Qq ollama-cuda ollama-rocm 2>/dev/null); fi
  rm -rf /usr/local/bin/ollama /usr/bin/ollama /usr/local/lib/ollama /usr/lib/ollama /var/lib/ollama /usr/share/ollama
  userdel ollama
  groupdel ollama
}

rm -f /run/josi-uninstall-kept /run/josi-uninstall-restart
step "${steps[0]}" s_stop
step "${steps[1]}" s_pc
step "${steps[2]}" s_services
step "${steps[3]}" s_files
step "${steps[4]}" s_package
[ "$purge" = 1 ] && step 'Removing the data and the accounts' s_data
[ "$ollama" = yes ] && step 'Removing Ollama and the AI model' s_ollama
[ -e /run/josi-uninstall-kept ] && kept=1
restart=0; [ -e /run/josi-uninstall-restart ] && restart=1
rm -f /run/josi-uninstall-kept /run/josi-uninstall-restart

echo
if [ "$purge" = 1 ]; then
  echo 'Josi was removed, with its data.'
elif [ "$kept" = 1 ]; then
  echo 'Josi was removed. Its data is kept in /var/lib/josi; run the install command again to bring it back.'
else
  echo 'Josi was removed. Its data folder /var/lib/josi was left as it was.'
fi
[ "$ollama" = yes ] && echo 'Ollama and the AI model were removed.'
[ "$restart" = 1 ] && echo 'The Josi package leaves the system image at the next restart.'
exit 0
