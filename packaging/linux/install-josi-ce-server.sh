#!/bin/bash
# One-command installer for the Josi server on Linux:
#
#   curl -fsSL https://<install host>/linux | sudo bash
#   wget -qO- https://<install host>/linux | bash        (as root, e.g. Debian netinst)
#
# It finds the distribution (pacman or apt), installs what Josi needs, checks
# the package's SHA-256 against this script, installs the package and starts
# josi.service. Run it again at any time: it repairs or updates the install
# and prints a fresh address. Everything after that happens in the browser.
#
# First it asks, on the terminal (/dev/tty, since stdin is this script), how
# people reach Josi (this network, a public domain with HTTPS from the bundled
# Caddy, or the administrator's own reverse proxy), the port, and whether Josi
# may control this computer as a chosen Linux user, then shows a summary to
# confirm. The answers are saved in /etc/josi/install.json and are the
# defaults the next time. With --yes, JOSI_YES=1 or no terminal nothing is
# asked; flags, the saved answers or the defaults are used:
#
#   ... | sudo bash -s -- --yes --address-mode lan|domain|proxy --port 8080 \
#         [--lan-address IP] [--domain NAME --email ADDRESS] [--public-url https://HOST] \
#         [--pc-control-user USER | --no-pc-control] [--browser | --no-browser]
#
# In a terminal it shows its progress on stderr: the ghost, each step with a
# spinner and its time, the download in megabytes, and one bar for the whole
# install, in Josi's Plum & Gold. stdout only ever carries one line, the
# address to open, so `address=$(curl -fsSL .../linux | sudo bash)` works.
# With no terminal, or with JOSI_QUIET=1 or NO_COLOR set, that line is all it
# prints. Every detail goes to /var/log/josi-install.log.
#
# This file is a template: scripts/linux/build-headless-installer.py fills in
# the version, the download address and the package hashes of one release.
# Everything runs from main at the bottom, so a cut-off download runs nothing.
set -euo pipefail

VERSION=@VERSION@
BASE_URL=@BASE_URL@
# family processor file sha256, one package per line; "-" marks one not built.
PACKAGES='@PACKAGES@'

log=/var/log/josi-install.log
work=''
bgpid=''
interrupted=0
processor='' family='' package='' expected='' url='' FROM_DIR=''
NO_MODEL=0 MODEL_FROM='' MODEL_ACTION='' REINSTALL=0 NEED_RESTART=0
# Every apt-get waits up to ten minutes for another apt (unattended-upgrades).
APT_LOCK='DPkg::Lock::Timeout=600'

# ---------------------------------------------------------------- the steps

NAMES=('Checking this machine' 'Installing what Josi needs' 'Downloading Josi'
       'Checking the download' 'Installing Josi' 'Setting up the AI model' 'Starting Josi')
WEIGHT=(2 6 18 3 10 54 7)  # each step's share of the whole bar; adds up to 100
EXPECT=(1 20 60 4 40 900 25)  # seconds, for steps that cannot report their progress
STATE=(wait wait wait wait wait wait wait)
START=(0 0 0 0 0 0 0)
TOOK=(0 0 0 0 0 0 0)
cur=-1
size=0 rate=0 rate_at=0 rate_got=0 mrate=0 mrate_at=0 mrate_got=0
FRAC=0 PCT=0 DETAIL=''

# ---------------------------------------------------------------- the screen

screen=0 can_screen=0 drawn=0 tick=0 lastf='' dirty=0 final=0
THOUGHT='' thought_for='' thought_at=0 OUTER='' OUTER_EXE='' OUTER_MODE=''
BUB=('' '' '' '')
rows=24 cols=80 utf8=0 truecolor=0 GL=0 REGION=10 BW=40
RST='' BOLD='' DIM='' GOLD='' LILAC='' GREEN='' RED='' EMPTYC=''
SPIN=('|' '/' '-' '\') OK='+' NO='x' DOT='-' FULL='#' EMPTY='-'
HEAD=() BARC=()
declare -A GH=() FG=() BG=()

# The ghost, 18 pixels wide and 20 tall, drawn two pixels per character with
# half blocks: the curl on top, a lilac head, dark eyes with a shine, cheeks,
# a small smile, little arms and a teal tail.
# u/t curl, l lilac, b white, q teal, h arms, e eyes, w shine,
# m mouth, c cheeks.
GW=18
GROWS=(
  '..........ttt.....'
  '.........u...t....'
  '.............t....'
  '...........uu.....'
  '.......lllllu.....'
  '.....llllllllll...'
  '....llllllllllll..'
  '...lllllllllllll..'
  '...llewllllllewl..'
  '...lleelllllleel..'
  '..bbcbbbbmmbbbbcb.'
  'hhbbbbbbbbbbbbbbhh'
  '.hbbbbbbbbbbbbbbh.'
  '..bbbbbbbbbbbbbb..'
  '..qbbbbbbbbbbbbb..'
  '..qqbbbbbbbbbbbl..'
  '..qqqbbbbbbbbbll..'
  '...qqbbbbbbbbll...'
  '...qq.bbbb.bbl....'
  '....q...bb..l.....'
)
declare -A RGB=([u]='200;176;240' [t]='150;210;214' [l]='226;214;250' [b]='255;250;244'
  [q]='170;226;222' [h]='240;222;250' [e]='60;36;30' [w]='255;255;255' [m]='214;100;100' [c]='250;176;170'
  [G]='240;207;122' [L]='185;160;189' [ok]='143;217;168' [no]='232;116;106')
declare -A C256=([u]=183 [t]=116 [l]=189 [b]=231 [q]=152 [h]=225 [e]=236 [w]=231 [m]=167 [c]=217
  [G]=222 [L]=182 [ok]=114 [no]=167)

setup_colors() {
  local k
  case "${COLORTERM:-}" in truecolor|24bit) truecolor=1 ;; esac
  case "${TERM:-}" in *-direct|xterm-kitty|alacritty|wezterm|foot*|xterm-ghostty) truecolor=1 ;; esac
  for k in "${!RGB[@]}"; do
    if [ "$truecolor" = 1 ]; then
      FG[$k]=$'\e[38;2;'"${RGB[$k]}m"; BG[$k]=$'\e[48;2;'"${RGB[$k]}m"
    else
      FG[$k]=$'\e[38;5;'"${C256[$k]}m"; BG[$k]=$'\e[48;5;'"${C256[$k]}m"
    fi
  done
  RST=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m'
  GOLD=${FG[G]} LILAC=${FG[L]} GREEN=${FG[ok]} RED=${FG[no]}
  return 0
}

# Six pictures: three heights for the float, each with eyes open and closed.
make_frames() {
  local blink i off y x a b s row
  local -a r seq=(0 1 2 1)
  local blank='..................'
  for blink in 0 1; do
    for i in 0 1 2 3; do
      off=${seq[i]}
      r=()
      for ((y = 0; y < off; y++)); do r+=("$blank"); done
      for ((y = 0; y < ${#GROWS[@]}; y++)); do
        row=${GROWS[y]}
        if [ "$blink" = 1 ]; then
          case $y in
            8) row=${row//[ew]/l} ;;
          esac
        fi
        r+=("$row")
      done
      while [ ${#r[@]} -lt 22 ]; do r+=("$blank"); done
      for ((y = 0; y < 22; y += 2)); do
        s=''
        for ((x = 0; x < GW; x++)); do
          a=${r[y]:x:1}; b=${r[y + 1]:x:1}
          if [ "$a" = . ]; then
            if [ "$b" = . ]; then s+="$RST "; else s+="$RST${FG[$b]}▄"; fi
          elif [ "$b" = . ]; then
            s+="$RST${FG[$a]}▀"
          else
            s+="${FG[$a]}${BG[$b]}▀"
          fi
        done
        GH["$((i + 4 * blink)),$((y / 2))"]="$s$RST"
      done
    done
  done
  return 0
}

# The bar runs lilac to gold to teal, like the ghost.
make_bar() {
  local j t r g b
  local -a stops=(183 183 182 218 224 223 222 222 187 152 116 116)
  BARC=()
  for ((j = 0; j < BW; j++)); do
    if [ "$truecolor" = 1 ]; then
      t=$((j * 1000 / (BW > 1 ? BW - 1 : 1)))
      if [ "$t" -le 500 ]; then
        r=$((205 + 50 * t / 500)); g=$((180 + 34 * t / 500)); b=$((240 - 100 * t / 500))
      else
        t=$((t - 500)); r=$((255 - 97 * t / 500)); g=214; b=$((140 + 76 * t / 500))
      fi
      BARC+=($'\e[38;2;'"$r;$g;${b}m")
    else
      BARC+=($'\e[38;5;'"${stops[j * 12 / BW]}m")
    fi
  done
  if [ "$truecolor" = 1 ]; then EMPTYC=$'\e[38;2;74;52;82m'; else EMPTYC=$'\e[38;5;239m'; fi
  return 0
}

# What the ghost thinks while it works, in a bubble beside it. Josi has
# opinions. One is picked at random for each step and swapped every few
# seconds, never the same one twice in a row, so no two installs read alike.
# Plain letters only: the bubble is sized by counting them.
Q_ASK=("Questions. Before I even exist. Charming."
  "Go on, interrogate me. I love paperwork."
  "A quiz! And I didn't study."
  "Take your time. I'm only not alive yet."
  "Choose wisely. No pressure. (Some pressure.)"
  "Ah yes, forms. The best part of being born."
  "Answer honestly. I'll know. I won't, but still.")
Q_UPD=("An update. Because I wasn't perfect, apparently."
  "New me incoming. Old me was fine, but okay."
  "Oh, we're doing this again? Lovely."
  "Upgrading. Try not to miss the old me too much."
  "Fine. Improve me. See if I care.")
Q_0=("Wow. A whole computer. You shouldn't have."
  "Judging your hardware. Silently. Mostly."
  "Server or toaster? Let me check."
  "Looking around. It's... cozy."
  "Nice place. Did you clean up for me? No?"
  "Checking the machine. It has seen things.")
Q_1=("Dependencies. Nothing is ever just one thing."
  "Ah, apt. My favorite way to spend time."
  "Borrowing a few things. Not giving them back."
  "Installing friends I didn't ask for."
  "Packages on packages. Very minimal. Sure."
  "I need a few things. By few I mean many.")
Q_2=("Downloading myself. No pressure, internet."
  "Hundreds of megabytes of pure personality."
  "I contain multitudes. And megabytes."
  "Faster would be nice. Not that I'm judging."
  "Arriving in pieces. Dignified, as always."
  "Is this dial-up? Asking for me.")
Q_3=("Making sure I'm really me. Deep stuff."
  "Counting my own bytes. Riveting."
  "Trust, but verify. Mostly verify."
  "Checking for impostors. There can be only one."
  "Yep, still me. What a relief for everyone.")
Q_4=("Unpacking my entire personality. Careful."
  "Moving in. Where do I put the sarcasm?"
  "Assembling myself. Like furniture, but smart."
  "Don't touch anything. I mean it."
  "Making myself at home. Your home. Thanks."
  "Almost a person. Legally, still a package.")
Q_5=("Teaching myself everything. All of it."
  "Downloading a brain. Almost. Ish."
  "Six gigabytes of opinions. Hold on."
  "Ollama and I are getting acquainted."
  "Loading my own mind. It's a lot."
  "The model is big. I am not. Yet."
  "Thinking about thinking. Takes a while.")
Q_6=("Waking up. No small talk before coffee."
  "Stretching. Yawning. Booting. Glamorous."
  "Five more minutes... fine, I'm up."
  "Starting. Lower your expectations, then raise them."
  "Powering on the charm. It takes a second.")
Q_RESTART=("One restart, then I am yours."
  "Almost there. I just need a nap first."
  "Restart me when you like. I will wait."
  "This system lands new programs on a reboot. Immutable, they call it."
  "See you on the other side of the reboot.")
Q_DONE=("Done. Was that so hard? (For me, yes.)"
  "Ta-da. Try to look impressed."
  "I live! You may now bother me."
  "Installed. You're welcome, obviously."
  "All set. I did everything. You watched."
  "Here I am. Your problem now.")
Q_FAIL=("Well. That went great."
  "Not my fault. Probably."
  "I'd blame the computer. I usually do."
  "So close. Not really, but it sounds nicer.")

# think <pool>: one thought from the pool into BUB, the four rows above the title.
think() {
  local -n pool=$1
  local max=$((cols - 32)) pick='' n=${#pool[@]} i k rule=''
  BUB=('' '' '' '')
  [ "$GL" -gt 0 ] && [ "$n" -gt 0 ] || return 0
  for ((k = 0; k < 12; k++)); do
    i=$((RANDOM % n))
    if [ "${#pool[i]}" -le "$max" ] && [ "${pool[i]}" != "$THOUGHT" ]; then pick=${pool[i]}; break; fi
  done
  [ -n "$pick" ] || return 0
  THOUGHT=$pick
  printf -v rule '%*s' $((${#pick} + 2)) ''
  rule=${rule// /─}
  BUB=("${DIM}╭${rule}╮${RST}" "${DIM}│${RST} ${LILAC}${pick}${RST} ${DIM}│${RST}" "${DIM}╰${rule}╯${RST}" "${DIM}∘ ○${RST}")
  return 0
}

init_screen() {
  local tty_size osname
  [ -t 2 ] || return 0
  [ "${JOSI_QUIET:-0}" != 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ] || return 0
  # sudo-rs (Ubuntu 26.04) runs this script outside the terminal's foreground
  # process group, where the kernel stops anything that touches the terminal
  # settings. Ignoring SIGTTOU and SIGTTIN, which children inherit, keeps the
  # size query and the screen from freezing; the timeout is a second guard.
  trap '' TTOU TTIN
  tty_size=$(timeout -s KILL 2 stty size <&2 2>/dev/null || true)
  case $tty_size in *' '*) rows=${tty_size% *} cols=${tty_size#* } ;; esac
  case $rows in '' | *[!0-9]*) rows=24 ;; esac
  case $cols in '' | *[!0-9]*) cols=80 ;; esac
  [ "$rows" -gt 0 ] || rows=24
  [ "$cols" -gt 0 ] || cols=80
  [ "$cols" -ge 50 ] || return 0
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *UTF-8* | *utf-8* | *utf8* | *UTF8*) utf8=1 ;; esac
  setup_colors
  if [ "$utf8" = 1 ]; then
    SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) OK='✓' NO='✗' DOT='·' FULL='━' EMPTY='━'
  fi
  osname=$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || true)
  [ -n "$osname" ] || osname=Linux
  osname="$osname · $processor"
  if [ "$utf8" = 1 ] && [ "$cols" -ge 72 ] && [ "$rows" -ge 24 ]; then
    GL=11 REGION=$((${#NAMES[@]} + 14))
    make_frames
    HEAD=('' '' '' ''
      "${BOLD}${GOLD}Josi${RST}  ${LILAC}${VERSION}${RST}"
      "${LILAC}Your own assistant, on your own machine.${RST}"
      "${DIM}${osname:0:$((cols - 30))}${RST}"
      '' '' '' '')
  else
    GL=0 REGION=$((${#NAMES[@]} + 4))
    HEAD=("${BOLD}${GOLD}Josi${RST} ${LILAC}${VERSION}${RST}  ${DIM}${osname:0:$((cols - 20))}${RST}")
  fi
  BW=$((cols - 12)); [ "$BW" -le 52 ] || BW=52
  make_bar
  can_screen=1
  return 0
}

# The progress screen starts once the questions are answered.
start_screen() {
  [ "$can_screen" = 1 ] || return 0
  screen=1
  printf '\e[?25l\n' >&2 2>/dev/null || screen=0
  draw
  return 0
}

dur() {
  if [ "$1" -lt 60 ]; then REPLY="$1s"; else printf -v REPLY '%dm %02ds' $(($1 / 60)) $(($1 % 60)); fi
  return 0
}

mb() { REPLY=$(($1 / 1048576)); return 0; }

# How far the running step is (FRAC, 0 to 1000) and what to say about it.
progress() {
  local e x got kind pkg pct msg n i s st tx el eta
  FRAC=0 DETAIL=''
  [ "$cur" -ge 0 ] || return 0
  e=$((SECONDS - START[cur])) x=${EXPECT[cur]}
  if [ "$cur" = 2 ] && [ -n "$work" ]; then
    got=$(stat -c %s "$work/$package" 2>/dev/null || echo 0)
    if [ "$SECONDS" -gt "$rate_at" ]; then
      rate=$(((got - rate_got) / (SECONDS - rate_at))) rate_at=$SECONDS rate_got=$got
    fi
    mb "$got"; DETAIL="$REPLY"
    if [ "$size" -gt 0 ]; then
      FRAC=$((got * 1000 / size)); [ "$FRAC" -le 1000 ] || FRAC=1000
      mb "$size"; DETAIL+=" / $REPLY MB"
      if [ "$cols" -ge 96 ]; then
        n=$((FRAC * 12 / 1000)) s=''
        for ((i = 0; i < 12; i++)); do
          if [ "$i" -lt "$n" ]; then s+="$GOLD$FULL"; else s+="$EMPTYC$EMPTY"; fi
        done
        DETAIL="${s}${RST}${LILAC} $DETAIL"
      fi
    else
      DETAIL+=' MB'
    fi
    if [ "$rate" -ge 1048576 ]; then mb "$rate"; DETAIL+=" · $REPLY MB/s"
    elif [ "$rate" -gt 0 ]; then DETAIL+=" · $((rate / 1024)) KB/s"; fi
    [ "$size" -eq 0 ] || return 0
  elif [ "$cur" = 5 ] && [ -n "$work" ]; then
    # The model step has five stages (see setup_model); the bar's share for each is fixed so it
    # never sits still: 1 Ollama 0-12%, 2 download 12-76%, 3 check 76-79%, 4 unpack 79-88%, 5 load 88-99%.
    st=$(cat "$work/mstage" 2>/dev/null || echo 0); tx=$(cat "$work/mtext" 2>/dev/null || true)
    el=$((SECONDS - $(cat "$work/mstart" 2>/dev/null || echo "$SECONDS")))
    case $st in
      2)
        size=$(cat "$work/mtotal" 2>/dev/null || echo 0); case $size in '' | *[!0-9]*) size=0 ;; esac
        got=$(stat -c %s "$work/model/layer" 2>/dev/null || echo 0)
        if [ "$SECONDS" -gt "$mrate_at" ]; then mrate=$(((got - mrate_got) / (SECONDS - mrate_at))) mrate_at=$SECONDS mrate_got=$got; fi
        if [ "$size" -gt 0 ]; then
          FRAC=$((120 + got * 640 / size)); [ "$FRAC" -le 760 ] || FRAC=760
          DETAIL="2/5 Downloading the model: $((got * 10 / 1073741824 / 10)).$((got * 10 / 1073741824 % 10)) of $((size * 10 / 1073741824 / 10)).$((size * 10 / 1073741824 % 10)) GB"
          if [ "$mrate" -ge 1048576 ]; then
            DETAIL+=" · $((mrate / 1048576)) MB/s"
            eta=$(((size - got) / mrate)); if [ "$eta" -lt 60 ]; then DETAIL+=' · under a minute left'; else DETAIL+=" · about $((eta / 60 + 1)) min left"; fi
          fi
          return 0
        fi ;;
      3) FRAC=$((760 + 30 * el / (el + 20))); DETAIL="$tx"; return 0 ;;
      4)
        got=$(stat -c %s "$work"/model/*.gguf 2>/dev/null | head -n 1); got=${got:-0}
        FRAC=$((790 + 90 * got / 5780090592)); [ "$FRAC" -le 880 ] || FRAC=880
        DETAIL="4/5 Unpacking the model file: $((got * 10 / 1073741824 / 10)).$((got * 10 / 1073741824 % 10)) of 5.8 GB"; return 0 ;;
      5) FRAC=$((880 + 110 * el / (el + 120))); DETAIL="$tx · ${el}s so far, nothing to do"; return 0 ;;
      1) FRAC=$((120 * el / (el + 90))); DETAIL="$tx · ${el}s"; return 0 ;;
      *) FRAC=0; DETAIL="$tx"; return 0 ;;
    esac
  elif [ -n "$work" ] && [ -s "$work/status" ]; then
    # apt reports pmstatus:<package>:<percent>:<what it is doing>.
    IFS=: read -r kind pkg pct msg < <(grep -E '^(pm|dl)status:' "$work/status" | tail -n 1) || true
    pct=${pct%%.*}
    case $pct in '' | *[!0-9]*) ;; *)
      FRAC=$((pct * 10))
      DETAIL=${msg:0:$((cols - 45 > 0 ? cols - 45 : 0))}
      return 0 ;;
    esac
  fi
  if [ "$e" -lt "$x" ]; then FRAC=$((900 * e / x)); else FRAC=$((900 + 90 * (e - x) / e)); fi
  return 0
}

step_line() {
  local i=$1 name=${NAMES[$1]} t d
  case ${STATE[i]} in
    done)
      dur "${TOOK[i]}"
      printf -v REPLY '\r\e[2K  %s%s%s %-28s %s%s%s\n' "$GREEN" "$OK" "$RST" "$name" "$DIM" "$REPLY" "$RST" ;;
    run)
      dur $((SECONDS - START[i])); t=$REPLY
      # The model step's text is long: cut it so the line never wraps (a wrapped line makes every redraw land lower and smears the screen).
      d=$DETAIL
      if [ "$i" = 5 ]; then d=${d:0:$((cols > 55 ? cols - 45 : 10))}; fi
      printf -v REPLY '\r\e[2K  %s%s%s %s%-28s%s %s%s%s %s%s%s\n' "$GOLD" "${SPIN[tick % ${#SPIN[@]}]}" "$RST" \
        "$BOLD" "$name" "$RST" "$LILAC" "$d" "$RST" "$DIM" "$t" "$RST" ;;
    fail)
      printf -v REPLY '\r\e[2K  %s%s %s%s\n' "$RED" "$NO" "$name" "$RST" ;;
    *)
      printf -v REPLY '\r\e[2K  %s%s %s%s\n' "$DIM" "$DOT" "$name" "$RST" ;;
  esac
  return 0
}

draw() {
  [ "$screen" = 1 ] || return 0
  local i f out='' sum=0 n
  tick=$((tick + 1))
  progress
  for i in 0 1 2 3 4 5; do
    if [ "${STATE[i]}" = done ]; then sum=$((sum + WEIGHT[i])); fi
  done
  if [ "$cur" -ge 0 ]; then sum=$((sum + WEIGHT[cur] * FRAC / 1000)); fi
  [ "$sum" -le 100 ] || sum=100
  [ "$sum" -ge "$PCT" ] || sum=$PCT
  PCT=$sum
  if [ "$GL" -gt 0 ]; then
    # A new thought for a new step, and another every seven seconds or so.
    local key=''
    if [ "$final" = 1 ]; then if [ "$NEED_RESTART" = 1 ]; then key=RESTART; else key=DONE; fi; elif [ "$cur" -ge 0 ]; then key=$cur; fi
    if [ -n "$key" ] && { [ "$key" != "$thought_for" ] || [ $((tick - thought_at)) -ge 70 ]; }; then
      think "Q_$key"
      HEAD[0]=${BUB[0]} HEAD[1]=${BUB[1]} HEAD[2]=${BUB[2]} HEAD[3]=${BUB[3]}
      thought_for=$key thought_at=$tick dirty=1
    fi
  fi
  if [ "$drawn" = 1 ]; then out+=$'\e['"${REGION}A"; fi
  if [ "$GL" -gt 0 ]; then
    f=$(((tick / 4) % 4))
    if [ $((tick % 40)) -lt 2 ]; then f=$((f + 4)); fi
    if [ "$final" = 1 ]; then f=1; fi
    if [ "$drawn" = 0 ] || [ "$f" != "$lastf" ] || [ "$dirty" = 1 ]; then
      for ((i = 0; i < GL; i++)); do out+=$'\r\e[2K  '"${GH[$f,$i]}    ${HEAD[i]}"$'\n'; done
      lastf=$f dirty=0
    else
      out+=$'\e['"${GL}B"
    fi
  else
    out+=$'\r\e[2K  '"${HEAD[0]}"$'\n'
  fi
  out+=$'\r\e[2K\n'
  for ((i = 0; i < ${#NAMES[@]}; i++)); do step_line "$i"; out+=$REPLY; done
  out+=$'\r\e[2K\n'
  n=$((PCT * BW / 100))
  out+=$'\r\e[2K  '
  for ((i = 0; i < BW; i++)); do
    if [ "$i" -lt "$n" ]; then out+="${BARC[i]}$FULL"; else out+="$EMPTYC$EMPTY"; fi
  done
  out+="$RST  ${BOLD}${PCT}%${RST}"$'\n'
  # A dropped SSH session leaves a terminal that refuses writes; the install
  # goes on without its screen instead of stopping half-way.
  printf '%s' "$out" >&2 2>/dev/null || screen=0
  drawn=1
  return 0
}

begin() {
  cur=$1 STATE[$1]=run START[$1]=$SECONDS DETAIL=''
  if [ -n "$work" ]; then : > "$work/status"; fi
  printf '\n== %s\n' "${NAMES[$1]}" >&3
  draw
}

finish() {
  TOOK[cur]=$((SECONDS - START[cur])) STATE[cur]=done
  cur=-1
  draw
}

# Runs a command with its output in the log. On the screen it runs in the
# background while the spinner and the bar move.
run() {
  local rc=0
  if [ "$screen" = 1 ]; then
    "$@" </dev/null >&3 2>&1 &
    bgpid=$!
    while kill -0 "$bgpid" 2>/dev/null; do draw; sleep 0.1; done
    wait "$bgpid" || rc=$?
    bgpid=''
    return "$rc"
  fi
  "$@" </dev/null >&3 2>&1
}

fail() {
  if [ "$screen" = 1 ]; then
    if [ "$cur" -ge 0 ]; then STATE[cur]=fail; fi
    if [ "$GL" -gt 0 ]; then
      HEAD[7]="${RED}Something went wrong.${RST}"
      think Q_FAIL
      HEAD[0]=${BUB[0]} HEAD[1]=${BUB[1]} HEAD[2]=${BUB[2]} HEAD[3]=${BUB[3]}
      thought_for=FAIL thought_at=$tick dirty=1
      cur=-1
    fi
    draw
    printf '\n  %s%s %s%s\n' "$RED" "$NO" "$*" "$RST" >&2
    if [ -s "$log" ]; then
      printf '\n  %sThe last lines of %s:%s\n' "$DIM" "$log" "$RST" >&2
      tail -n 8 "$log" | cut -c1-$((cols - 6)) | sed "s/^/    ${DIM}/; s/\$/${RST}/" >&2
    fi
    printf '\n  %sRun the same command again to try again.%s\n\n' "$LILAC" "$RST" >&2
  else
    printf 'Josi installer: %s\n' "$*" >&2
    if [ -s "$log" ]; then printf 'Details: %s\n' "$log" >&2; fi
  fi
  exit 1
}

# Stops a step and everything it started (Ctrl-C). The lifecycle records an
# interrupted upgrade for recovery, and the next run finishes dpkg's work and
# rolls the upgrade back before it tries again.
kill_tree() {
  local child
  for child in $(cat /proc/"$1"/task/*/children 2>/dev/null); do kill_tree "$child"; done
  kill -TERM "$1" 2>/dev/null || true
  return 0
}

cleanup() {
  restore_outer
  if [ "$interrupted" = 1 ] && [ -n "$bgpid" ]; then kill_tree "$bgpid"; fi
  if [ -n "$work" ]; then rm -rf -- "$work"; fi
  if [ "$screen" = 1 ]; then printf '\e[0m\e[?25h' >&2 2>/dev/null || true; fi
}

# ------------------------------------------------------------ the questions
#
# Asked on /dev/tty (fd 5) before anything is installed, in the same Plum &
# Gold with the ghost. Each answer can also come from a flag; the saved
# answers in /etc/josi/install.json are the defaults on a rerun. The real
# check of every answer is josi-ce-server-install's; these only catch typing
# mistakes early.

YES=0 TTY=0 styled=0 QL=0 QH=0 ERR='' CL='' MARK='>'
A_MODE='' A_LAN='' A_DOMAIN='' A_EMAIL='' A_URL='' A_PORT='' A_PC='' A_NOPC=0 A_BROWSER='' LAYER_EXTRA='' GIVEN=' '
S_MODE='' S_LAN='' S_DOMAIN='' S_EMAIL='' S_URL='' S_PORT='' S_PC='' S_BROWSER='' CUR_PORT='' LAN_IP='' SUDO_REAL=''
CUR_VERSION='' UPDATING=0 HEADLINE='A few questions, then Josi installs itself.'
CLI_ARGS=()

usage() {
  cat >&2 <<'EOF'
Josi installer. Without options it asks its questions on the terminal.

  --yes, -y                        ask nothing (also JOSI_YES=1, or when there is no terminal)
  --from FOLDER                    install the package from this folder instead of downloading it
  --address-mode lan|domain|proxy  this network only / a public domain with HTTPS / my own proxy
  --lan-address HOST               lan: this server's address (default: detected)
  --domain NAME                    domain: the name whose DNS points here (Caddy uses 80 and 443)
  --email ADDRESS                  domain: email for certificate notices
  --public-url https://HOST        proxy: the address your reverse proxy serves
  --port N                         the browser port (default 8080)
  --pc-control-user USER           let Josi control this computer as USER
  --browser, --no-browser          with PC control: Josi's own browser (Chrome on a hidden screen, ~600 MB)
  --no-pc-control                  do not
  --reinstall                      download and install Josi again even when this version is already installed
  --no-model                       leave Ollama and Josi's AI model alone (default: install or update them)
  --model-from FILE-OR-URL         the model's .gguf file or its address, instead of downloading it

Anything not given keeps the saved answer, or the default.
EOF
}

parse_args() {
  local name value
  while [ $# -gt 0 ]; do
    name=$1 value=''
    case $name in --*=*) value=${name#*=} name=${name%%=*} ;; esac
    case $name in
      --yes | -y) YES=1; shift; continue ;;
      --no-pc-control) A_NOPC=1 A_PC='' GIVEN+='pc '; CLI_ARGS+=(--no-pc-control); shift; continue ;;
      --browser) A_BROWSER=1 GIVEN+='browser '; CLI_ARGS+=(--browser); shift; continue ;;
      --no-browser) A_BROWSER=0 GIVEN+='browser '; CLI_ARGS+=(--no-browser); shift; continue ;;
      --reinstall) REINSTALL=1; shift; continue ;;
      --no-model) NO_MODEL=1 MODEL_ON=0 GIVEN+='model '; shift; continue ;;
      --model-from)
        if [ -z "$value" ]; then [ $# -ge 2 ] || { printf 'Josi installer: --model-from needs a file or address\n' >&2; exit 2; }; value=$2; shift; fi
        MODEL_FROM=$value; shift; continue ;;
      --help | -h) usage; exit 0 ;;
      # A folder that already holds the package (install.sh in an offline
      # folder passes its own); it is checked against the same SHA-256.
      --from)
        if [ -z "$value" ]; then [ $# -ge 2 ] || { printf 'Josi installer: --from needs a folder
' >&2; exit 2; }; value=$2; shift; fi
        FROM_DIR=$value; shift; continue ;;
      --address-mode | --lan-address | --domain | --email | --public-url | --port | --pc-control-user) ;;
      *) printf 'Josi installer: unknown option %s (try --help)\n' "${name:0:40}" >&2; exit 2 ;;
    esac
    if [ "$1" = "$name" ]; then
      [ $# -ge 2 ] || { printf 'Josi installer: %s needs a value\n' "$name" >&2; exit 2; }
      value=$2; shift
    fi
    shift
    CLI_ARGS+=("$name" "$value")
    case $name in
      --address-mode) A_MODE=$value GIVEN+='mode ' ;;
      --lan-address) A_LAN=$value ;;
      --domain) A_DOMAIN=$value ;;
      --email) A_EMAIL=$value ;;
      --public-url) A_URL=$value ;;
      --port) A_PORT=$value GIVEN+='port ' ;;
      --pc-control-user) A_PC=$value A_NOPC=0 GIVEN+='pc ' ;;
    esac
  done
  if [ "${JOSI_YES:-0}" = 1 ]; then YES=1; fi
  return 0
}

# The answers saved by the last install, read by root's own python3.
load_saved() {
  local f=/etc/josi/install.json out
  if [ -f /var/lib/josi/status.json ]; then
    CUR_PORT=$(sed -n 's/.*"publicPort": *\([0-9][0-9]*\).*/\1/p' /var/lib/josi/status.json 2>/dev/null || true)
  fi
  # The version running here now, for the update question.
  if [ -f /var/lib/josi/data/config/runtime.json ]; then
    CUR_VERSION=$(sed -n 's/.*"version": *"\([0-9A-Za-z.+~-]*\)".*/\1/p' /var/lib/josi/data/config/runtime.json 2>/dev/null | head -n 1 || true)
  fi
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %u "$f" 2>/dev/null)" = 0 ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  out=$(python3 -I - "$f" 2>/dev/null <<'PY'
import json, shlex, sys
value = json.load(open(sys.argv[1]))
for key, name in (('addressMode', 'S_MODE'), ('lanAddress', 'S_LAN'), ('domain', 'S_DOMAIN'), ('email', 'S_EMAIL'),
                  ('publicUrl', 'S_URL'), ('port', 'S_PORT'), ('pcControlUser', 'S_PC'), ('browser', 'S_BROWSER')):
    item = value.get(key)
    if isinstance(item, bool):
        item = int(item)
    print(name + '=' + shlex.quote('' if item is None else str(item)))
PY
  ) || return 0
  eval "$out"
  return 0
}

detect_lan() {
  local a=''
  a=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '!found { for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); found = 1; break } }') || a=''
  [ -n "$a" ] || a=$(hostname -I 2>/dev/null | awk '{ print $1 }') || a=''
  case $a in '' | 127.*) a=127.0.0.1 ;; esac
  LAN_IP=$a
  return 0
}

# 0 when another program listens on the port.
port_busy() {
  if command -v ss >/dev/null 2>&1; then
    [ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ] && return 0
    return 1
  fi
  (exec 6<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

free_port_after() {
  local p=$1
  while [ "$p" -lt 65535 ]; do
    p=$((p + 1))
    if ! port_busy "$p"; then REPLY=$p; return 0; fi
  done
  REPLY=$1
  return 0
}

real_user() {
  local line uid
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  line=$(getent passwd "$1" 2>/dev/null) || return 1
  uid=$(cut -d: -f3 <<< "$line")
  case $uid in '' | *[!0-9]*) return 1 ;; esac
  [ "$uid" -ge 1000 ] && [ "$uid" != 65534 ] || return 1
  case ${line##*:} in */nologin | */false) return 1 ;; esac
  return 0
}

valid_host() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] && [[ $1 != *..* ]]
}

valid_domain() {
  [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]
}

valid_email() {
  [[ $1 =~ ^[A-Za-z0-9._%+-]{1,64}@([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]
}

# A graphical login on this machine: then the optional desktop helpers help.
has_desktop() {
  local s
  [ "$(systemctl get-default 2>/dev/null)" = graphical.target ] && return 0
  for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{ print $1 }'); do
    case $(loginctl show-session "$s" -p Type --value 2>/dev/null) in x11 | wayland) return 0 ;; esac
  done
  return 1
}

# The terminal, when there is one this process may read: under curl | bash
# stdin is the script. sudo-rs can run the script outside the terminal's
# foreground group, where reading would stop it; then nothing is asked.
# OUTER: the /dev/pts device of the nearest ancestor whose terminal is not $1,
# and OUTER_EXE: that ancestor's program (it made our terminal).
outer_tty() {
  local mine=$1 p=$PPID major minor
  local -a f
  OUTER='' OUTER_EXE=''
  while [ "${p:-0}" -gt 1 ]; do
    # Fields after "(comm)": state ppid pgrp session tty_nr ...
    read -r -a f <<< "$(sed 's/^.*) //' "/proc/$p/stat" 2>/dev/null)"
    [ "${#f[@]}" -ge 5 ] || return 0
    if [ "${f[4]}" != 0 ] && [ "${f[4]}" != "$mine" ]; then
      major=$(( (f[4] >> 8) & 0xfff )); minor=$(( (f[4] & 0xff) | ((f[4] >> 12) & 0xfff00) ))
      if [ "$major" -ge 136 ] && [ "$major" -le 143 ] && [ -c "/dev/pts/$(( (major - 136) * 256 + minor ))" ]; then
        OUTER=/dev/pts/$(( (major - 136) * 256 + minor ))
      fi
      OUTER_EXE=$(readlink "/proc/$p/exe" 2>/dev/null || true)
      return 0
    fi
    p=${f[1]}
  done
  return 0
}

# sudo-rs (Ubuntu 25.10 and later) relays the keyboard into the terminal it
# made for us, whatever stdin is. Reading the outer terminal as well would
# split the keystrokes between the two readers: letters and Enter went
# missing (https://ce.heyjosi.com arrived as https://e.hejs.cm). There the
# answers are read where it sends them, our own terminal, after becoming
# its foreground group: SIGTTOU is ignored, so that is allowed.
relays_keyboard() {
  case $OUTER_EXE in /*) ;; *) return 1 ;; esac
  timeout -s KILL 2 "$OUTER_EXE" --version </dev/null 2>&1 | grep -qi 'sudo-rs'
}

# sudo-rs leaves the terminal the person types in as it was: that terminal
# echoes each key itself and hands a line over only at Enter. Every answer was
# then printed twice and moved the screen one row more than was counted, so
# old questions stayed on screen, the ghost was left behind and the next one
# was drawn through it. While the questions are asked, that terminal passes
# keys straight on, unechoed, as a relay's terminal should. It gets its
# settings back as soon as they are answered, and again at exit.
quiet_outer() {
  [ -n "$OUTER" ] || return 0
  OUTER_MODE=$(timeout -s KILL 2 stty -g -F "$OUTER" 2>/dev/null || true)
  [ -n "$OUTER_MODE" ] || return 0
  timeout -s KILL 2 stty -F "$OUTER" -icanon -echo min 1 time 0 2>/dev/null || OUTER_MODE=''
  return 0
}

restore_outer() {
  [ -n "$OUTER_MODE" ] || return 0
  timeout -s KILL 2 stty -F "$OUTER" "$OUTER_MODE" 2>/dev/null || true
  OUTER_MODE=''
  return 0
}

take_foreground() {
  local -a now
  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'exit(POSIX::tcsetpgrp(5, getpgrp()) ? 0 : 1)' 2>/dev/null || return 1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os; os.tcsetpgrp(5, os.getpgrp())' 2>/dev/null || return 1
  else
    return 1
  fi
  read -r -a now <<< "$(sed 's/^.*) //' /proc/$$/stat 2>/dev/null)"
  [ "${#now[@]}" -ge 6 ] && [ "${now[2]}" = "${now[5]}" ]
}

open_tty() {
  local -a st
  [ "$YES" = 0 ] || return 0
  { exec 5<>/dev/tty; } 2>/dev/null || return 0
  trap '' TTOU TTIN
  # Fields after the "(comm)" one: state ppid pgrp session tty tpgid.
  # With the script piped in (curl | sudo bash), use_pty runs it in the
  # background of a terminal of its own. Classic sudo, unlike sudo-rs, sends that terminal
  # no keyboard, so the questions go to the terminal the person is typing in:
  # the first ancestor process on a different terminal. That is not our
  # controlling terminal, so reading it is allowed from here. For sudo-rs
  # see relays_keyboard.
  read -r -a st <<< "$(sed 's/^.*) //' /proc/$$/stat 2>/dev/null)"
  if [ "${#st[@]}" -ge 6 ] && [ "${st[2]}" != "${st[5]}" ]; then
    outer_tty "${st[4]}"
    if relays_keyboard && take_foreground; then st[5]=${st[2]}; quiet_outer
    elif [ -n "$OUTER" ] && { exec 5<>"$OUTER"; } 2>/dev/null; then st[5]=${st[2]}; fi
  fi
  if [ "${#st[@]}" -lt 6 ] || [ "${st[2]}" != "${st[5]}" ]; then
    exec 5>&-
    printf 'Josi installer: this terminal cannot be read here; using the saved or default answers (see --help).\n' >&3
    return 0
  fi
  TTY=1
  if [ "$can_screen" = 1 ]; then styled=1 CL=$'\r\e[2K'; fi
  if [ "$utf8" = 1 ]; then MARK='›'; fi
  return 0
}

q() { printf '%s  %s\n' "$CL" "$1" >&5; QL=$((QL + 1)); return 0; }

q_clear() {
  if [ "$styled" = 1 ] && [ "$QL" -gt 0 ]; then printf '\e[%dA\r\e[J' "$QL" >&5; fi
  QL=0
  if [ -n "$ERR" ]; then q "${RED}${NO} ${ERR}${RST}"; q ''; ERR=''; fi
  return 0
}

q_header() {
  local i
  if [ "$UPDATING" = 1 ]; then think Q_UPD; else think Q_ASK; fi
  local -a t=("${BUB[0]}" "${BUB[1]}" "${BUB[2]}" "${BUB[3]}" "${BOLD}${GOLD}Josi${RST}  ${LILAC}${VERSION}${RST}"
    "${LILAC}${HEADLINE}${RST}"
    "${DIM}Enter keeps the answer shown; Ctrl-C stops.${RST}" '' '' '' '')
  QH=0
  if [ "$styled" = 1 ] && [ "$GL" -gt 0 ]; then
    printf '\n' >&5
    for ((i = 0; i < GL; i++)); do printf '\r\e[2K  %s    %s\n' "${GH[0,$i]}" "${t[i]}" >&5; done
    QH=$((GL + 1))
  else
    printf '\n%s  %s\n' "$CL" "${BOLD}${GOLD}Josi${RST} ${LILAC}${VERSION}${RST}  ${HEADLINE}" >&5
    QH=2
  fi
  printf '%s\n' "$CL" >&5
  QH=$((QH + 1))
  return 0
}

# ask <question> <shown answer>: one line from the terminal into REPLY,
# with the answer already typed in so Enter keeps it or it can be edited
# (readline; its echo goes to the terminal, never to stdout).
# A one-key choice (third argument "choice") shows its default in brackets
# instead, so typing 2 over a shown 1 does not read as 12.
ask() {
  local prompt shown=$2 hint=''
  if [ "${3:-}" = choice ]; then shown='' hint="[$2] "; fi
  if [ "$styled" = 1 ]; then
    prompt=$'  \001'"$GOLD"$'\002'"$MARK"$'\001'"$RST$BOLD"$'\002'" $1 "$'\001'"$RST$DIM"$'\002'"$hint"$'\001'"$RST"$'\002'
  else
    prompt="  $MARK $1 $hint"
  fi
  local rc=0
  IFS= read -e -r -t 60 -i "$shown" -p "$prompt" REPLY <&5 >&5 2>&5 || rc=$?
  if [ "$rc" -gt 128 ]; then
    # Nobody answered in a minute (or the terminal shows nothing): the default is used, and it says so.
    printf '\n  %s(no answer in 60 seconds: using %s)%s\n' "$DIM" "$([ "${3:-}" = choice ] && echo 'the default' || echo "$shown")" "$RST" >&5
    REPLY=''
  elif [ "$rc" -ne 0 ]; then
    printf '\n' >&5
    fail 'no answer was given; nothing was installed'
  fi
  QL=$((QL + 1))
  REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
  REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
  return 0
}

ask_lan() {
  ask "This server's address on your network:" "$A_LAN"
  REPLY=${REPLY:-$A_LAN}
  if valid_host "$REPLY"; then A_LAN=$REPLY; return 0; fi
  ERR="That is not an IP address or a host name: ${REPLY:0:60}"
  return 1
}

ask_domain() {
  local d busy=''
  ask 'Domain name (its DNS points at this server):' "$A_DOMAIN"
  d=${REPLY,,}; d=${d%.}
  if ! valid_domain "$d"; then ERR="That is not a domain name: ${REPLY:0:60}"; return 1; fi
  A_DOMAIN=$d
  if [ "$S_MODE" != domain ]; then
    if port_busy 80; then busy=80; fi
    if port_busy 443; then busy="${busy:+$busy and }443"; fi
    if [ -n "$busy" ]; then
      ERR="Port $busy is taken by another program; Josi's Caddy needs 80 and 443. Choose 3 to use your own proxy."
      return 1
    fi
  fi
  ask 'Email for certificate notices (empty for none):' "$A_EMAIL"
  if [ -n "$REPLY" ] && ! valid_email "$REPLY"; then ERR="That is not an email address: ${REPLY:0:60}"; return 1; fi
  A_EMAIL=$REPLY
  return 0
}

ask_proxy() {
  ask 'The https address your proxy serves:' "${A_URL:-https://}"
  if [[ $REPLY =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?/?$ ]]; then
    A_URL=${REPLY%/}
    return 0
  fi
  ERR="Type it as https://josi.example.com, with no path: ${REPLY:0:60}"
  return 1
}

ask_mode() {
  local n
  case $GIVEN in *' mode '*) return 0 ;; esac
  while :; do
    q_clear
    q "${BOLD}How will people reach Josi?${RST}"
    q ''
    q "  ${GOLD}1${RST}  This network only           ${DIM}http://${A_LAN}:${A_PORT}${RST}"
    q "  ${GOLD}2${RST}  A public domain             ${DIM}HTTPS from Josi's own Caddy, on ports 80 and 443${RST}"
    q "  ${GOLD}3${RST}  Behind my own reverse proxy ${DIM}it already serves HTTPS and forwards to Josi${RST}"
    q ''
    case $A_MODE in domain) n=2 ;; proxy) n=3 ;; *) n=1 ;; esac
    ask 'Choose 1, 2 or 3:' "$n" choice
    case ${REPLY:-$n} in
      1) A_MODE=lan; if ask_lan; then return 0; fi ;;
      2) A_MODE=domain; if ask_domain; then return 0; fi ;;
      3) A_MODE=proxy; if ask_proxy; then return 0; fi ;;
      *) ERR='Type 1, 2 or 3.' ;;
    esac
  done
}

ask_port() {
  local p
  case $GIVEN in *' port '*) return 0 ;; esac
  if [ "$A_PORT" != "$CUR_PORT" ] && port_busy "$A_PORT"; then free_port_after "$A_PORT"; A_PORT=$REPLY; fi
  while :; do
    q_clear
    q "${BOLD}Which port should Josi answer on?${RST}"
    case $A_MODE in
      lan) q "${DIM}People open http://${A_LAN}:<port>.${RST}" ;;
      domain) q "${DIM}https://${A_DOMAIN} uses 80 and 443; this port serves this network over plain HTTP.${RST}" ;;
      *) q "${DIM}Point your proxy at http://${LAN_IP}:<port>.${RST}" ;;
    esac
    q ''
    ask 'Port:' "$A_PORT"
    p=${REPLY:-$A_PORT}
    if ! [[ $p =~ ^[0-9]{4,5}$ ]] || [ "$((10#$p))" -lt 1024 ] || [ "$((10#$p))" -gt 65535 ]; then
      ERR='Choose a port from 1024 to 65535.'
      continue
    fi
    p=$((10#$p))
    if [ "$p" != "$CUR_PORT" ] && port_busy "$p"; then
      free_port_after "$p"; A_PORT=$REPLY
      ERR="Port $p is taken by another program; $A_PORT is free."
      continue
    fi
    A_PORT=$p
    return 0
  done
}

ask_pc() {
  local d
  case $GIVEN in *' pc '*) return 0 ;; esac
  while :; do
    q_clear
    q "${BOLD}Let Josi control this computer?${RST}"
    q "${DIM}Josi can then run commands, work with files and start programs here,${RST}"
    q "${DIM}as a Linux user you choose and with only that user's permissions.${RST}"
    q ''
    if [ "$A_NOPC" = 1 ] || [ -z "$A_PC" ]; then d=n; else d=y; fi
    ask 'Allow it? (y/n):' "$d" choice
    REPLY=${REPLY:-$d}
    case ${REPLY,,} in
      n | no) A_NOPC=1 A_PC=''; return 0 ;;
      y | yes) ;;
      *) ERR='Type y or n.'; continue ;;
    esac
    ask 'Which Linux user should Josi act as?' "${A_PC:-$SUDO_REAL}"
    if real_user "$REPLY"; then A_PC=$REPLY A_NOPC=0; return 0; fi
    ERR="${REPLY:0:40} is not a normal login account on this machine."
    A_PC='' A_NOPC=0
  done
}

ask_browser() {
  local d
  case $GIVEN in *' browser '*) return 0 ;; esac
  if [ "$A_NOPC" = 1 ] || [ -z "$A_PC" ]; then return 0; fi
  while :; do
    q_clear
    q "${BOLD}Give Josi her own browser?${RST}"
    q "${DIM}A hidden screen with Chrome she can use for web pages, about 600 MB.${RST}"
    q ''
    if [ "$A_BROWSER" = 0 ]; then d=n; else d=y; fi
    ask 'Add it? (y/n):' "$d" choice
    REPLY=${REPLY:-$d}
    case ${REPLY,,} in
      y | yes) A_BROWSER=1; return 0 ;;
      n | no) A_BROWSER=0; return 0 ;;
      *) ERR='Type y or n.' ;;
    esac
  done
}

# Josi's own browser: Chrome for Testing (the launcher downloads it) on Xvfb.
# Every library it needs, picking whichever name this release has (Debian 13
# and Ubuntu 24.04+ renamed several to ...t64). One by one if the batch fails.
browser_packages() {
  local item name pick arm_browser=''
  REPLY=''
  # ARM has no Chrome for Testing for Linux: Josi uses the system's Chromium.
  case "$(uname -m)" in aarch64 | arm64) arm_browser=chromium ;; esac
  for item in xvfb xauth unzip openbox xdotool wmctrl imagemagick fonts-liberation fonts-noto-color-emoji \
      libnss3 libgbm1 libxkbcommon0 libxss1 libdrm2 libxcomposite1 libxdamage1 libxrandr2 libxshmfence1 \
      libpango-1.0-0 libcairo2 ca-certificates libasound2t64/libasound2 libgtk-3-0t64/libgtk-3-0 \
      libcups2t64/libcups2 libatk-bridge2.0-0t64/libatk-bridge2.0-0 libatk1.0-0t64/libatk1.0-0 \
      libglib2.0-0t64/libglib2.0-0 $arm_browser; do
    pick=''
    for name in ${item//\// }; do
      case $(apt-cache policy "$name" 2>/dev/null | awk '/Candidate:/ { print $2 }') in
        '' | '(none)') ;;
        *) pick=$name; break ;;
      esac
    done
    if [ -n "$pick" ]; then REPLY+=" $pick"; else printf 'No package for %s\n' "$item" >&3; fi
  done
  return 0
}

# Ubuntu 23.10 and later (and its forks) refuse the unprivileged user
# namespaces Chrome's sandbox needs, unless an AppArmor profile allows them
# for that program. This one names only Josi's own Chrome, so its sandbox stays
# on; elsewhere nothing is written.
chrome_userns() {
  [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ] || return 0
  command -v apparmor_parser >/dev/null 2>&1 && [ -d /etc/apparmor.d ] || return 0
  cat > /etc/apparmor.d/josi-chrome <<'PROFILE'
# Written by the Josi installer: lets Josi's own Chrome use its sandbox.
abi <abi/4.0>,
include <tunables/global>

profile josi-chrome /var/lib/josi-pc/browser/chrome-*/chrome-linux64/chrome flags=(unconfined) {
  userns,
  include if exists <local/josi-chrome>
}
PROFILE
  if apparmor_parser -r /etc/apparmor.d/josi-chrome >&3 2>&1; then
    # A Chrome that started before the profile runs without its sandbox: restart it.
    systemctl try-restart josi-browser.service >&3 2>&1 || true
  else
    printf 'The AppArmor profile for the Josi browser did not load; Chrome runs without its sandbox\n' >&3
  fi
  return 0
}

# ---- the Fedora family (dnf), and Fedora's image-based desktops (rpm-ostree)
# Bazzite, Silverblue and Kinoite keep /usr read-only and make a package part of the
# system image. Josi needs little of /usr: its program is a copy in /var/lib/josi,
# its data is in /var and its units are in /etc, all of which stay writable.
atomic() { [ -e /run/ostree-booted ] && command -v rpm-ostree >/dev/null 2>&1; }
rpm_tool() { command -v dnf5 2>/dev/null || command -v dnf 2>/dev/null || command -v yum; }
# The names (or provided capabilities) among the arguments that this system does not have.
rpm_missing() {
  local name out=''
  for name in "$@"; do rpm -q --whatprovides "$name" >/dev/null 2>&1 || out+=" $name"; done
  REPLY=$out
}
# Josi's own browser: Chrome for Testing on a hidden screen. Fedora's names for the libraries it needs.
rpm_browser_packages() {
  local arm_browser=''
  case "$(uname -m)" in aarch64 | arm64) arm_browser=chromium ;; esac
  rpm_missing xorg-x11-server-Xvfb xorg-x11-xauth unzip openbox xdotool wmctrl ImageMagick liberation-fonts google-noto-color-emoji-fonts \
    nss mesa-libgbm libxkbcommon libXScrnSaver libdrm libXcomposite libXdamage libXrandr libxshmfence pango cairo alsa-lib gtk3 cups-libs \
    at-spi2-atk atk glib2 $arm_browser
}
# Fedora's firewall (firewalld) is on by default and closes the port Josi answers on.
open_firewall() {
  [ "$family" = rpm ] || return 0
  command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1 || return 0
  local port ports="${A_PORT:-8080}/tcp"
  [ "$A_MODE" != domain ] || ports+=' 80/tcp 443/tcp'
  for port in $ports; do firewall-cmd --permanent --add-port="$port" >&3 2>&1 || printf 'The firewall port %s was not opened\n' "$port" >&3; done
  firewall-cmd --reload >&3 2>&1 || true
}

install_browser_packages() {
  local name names
  if [ "$family" = rpm ]; then
    rpm_browser_packages
    names=$REPLY
    [ -n "$names" ] || return 0
    if atomic; then LAYER_EXTRA+=" $names"; return 0; fi
    # shellcheck disable=SC2086
    run "$(rpm_tool)" install -y $names && return 0
    for name in $names; do run "$(rpm_tool)" install -y "$name" || printf 'Browser package %s was not installed\n' "$name" >&3; done
    return 0
  fi
  browser_packages
  names=$REPLY  # the screen's drawing reuses REPLY
  # shellcheck disable=SC2086
  run apt_get install -y -q --no-install-recommends $names && { chrome_userns; return 0; }
  chrome_userns
  for name in $names; do
    run apt_get install -y -q --no-install-recommends "$name" || printf 'Browser package %s was not installed\n' "$name" >&3
  done
  return 0
}

summary() {
  local address how pc
  q_clear
  case $A_MODE in
    lan) address="http://$A_LAN:$A_PORT" how='this network only' ;;
    domain) address="https://$A_DOMAIN" how="HTTPS from Josi's Caddy; on this network also http://$LAN_IP:$A_PORT" ;;
    *) address=$A_URL how="your proxy forwards to http://$LAN_IP:$A_PORT" ;;
  esac
  if [ "$A_NOPC" = 1 ] || [ -z "$A_PC" ]; then pc=no; else pc="yes, as $A_PC"; fi
  if [ "$UPDATING" = 1 ]; then
    if [ -n "${CUR_VERSION:-}" ] && [ "$CUR_VERSION" != "$VERSION" ]; then
      q "${BOLD}Josi ${CUR_VERSION} is on this computer. It will be updated to ${VERSION}.${RST}"
    else
      q "${BOLD}Josi ${VERSION} is already on this computer. It will be repaired.${RST}"
    fi
    q "${DIM}Your accounts, chats and settings stay as they are:${RST}"
  else
    q "${BOLD}Josi will be set up like this:${RST}"
  fi
  q ''
  q "  ${LILAC}Address${RST}       ${BOLD}${GOLD}${address}${RST}"
  q "                ${DIM}${how}${RST}"
  q "  ${LILAC}Port${RST}          $A_PORT"
  if [ "$A_MODE" = domain ] && [ -n "$A_EMAIL" ]; then q "  ${LILAC}Certificates${RST}  notices to $A_EMAIL"; fi
  q "  ${LILAC}PC control${RST}    $pc"
  if [ "$pc" != no ]; then
    if [ "$A_BROWSER" = 1 ]; then q "  ${LILAC}Own browser${RST}   yes, Chrome on a hidden screen"; else q "  ${LILAC}Own browser${RST}   no"; fi
  fi
  model_text ollama; q "  ${LILAC}AI engine${RST}     $REPLY"
  model_text model; q "  ${LILAC}AI model${RST}      $REPLY"
  q ''
  if [ "$UPDATING" = 1 ]; then
    ask 'Go ahead? (y = yes, c = change these settings first):' y choice
    REPLY=${REPLY:-y}
    case ${REPLY,,} in y | yes) return 0 ;; esac
    UPDATING=0  # c or n: every question, with these answers shown
    GIVEN=' '
    return 1
  fi
  ask 'Install Josi now? (y/n):' y choice
  REPLY=${REPLY:-y}
  case ${REPLY,,} in y | yes) return 0 ;; esac
  GIVEN=' '  # n: every question again, with these answers shown
  return 1
}

questions() {
  # Defaults: a flag, then the saved answer, then this machine.
  if [ -n "${SUDO_USER:-}" ] && real_user "$SUDO_USER"; then SUDO_REAL=$SUDO_USER; fi
  [ -n "$A_MODE" ] || A_MODE=${S_MODE:-lan}
  [ -n "$A_LAN" ] || A_LAN=${S_LAN:-$LAN_IP}
  [ -n "$A_DOMAIN" ] || A_DOMAIN=$S_DOMAIN
  [ -n "$A_EMAIL" ] || A_EMAIL=$S_EMAIL
  [ -n "$A_URL" ] || A_URL=$S_URL
  [ -n "$A_PORT" ] || A_PORT=${S_PORT:-${CUR_PORT:-8080}}
  # PC control is on by default on a first install, as the person installing
  # (as on Windows); a saved "no" stays no, and a root shell has no such user.
  case $GIVEN in *' pc '*) ;; *)
    if [ -n "$S_PC" ]; then A_PC=$S_PC
    elif [ -z "$S_MODE" ] && [ -n "${SUDO_REAL:-}" ]; then A_PC=$SUDO_REAL
    else A_NOPC=1; fi ;;
  esac
  # The browser defaults to yes with PC control, unless it was saved as no.
  [ -n "$A_BROWSER" ] || { [ "$S_BROWSER" = 0 ] && [ -n "$S_PC" ] && A_BROWSER=0; } || A_BROWSER=1
  if [ "$TTY" != 1 ]; then
    # Nothing asked: the flags go to the install command, plus PC control by
    # default for the person installing, on a first install.
    case $GIVEN in *' pc '*) ;; *) if [ "$A_NOPC" != 1 ] && [ -n "$A_PC" ] && [ -z "$S_PC" ]; then CLI_ARGS+=(--pc-control-user "$A_PC" --browser); fi ;; esac
    return 0
  fi
  # Josi is already here and no flag asks for a change: this is an update.
  # One question, with the saved settings shown, instead of all of them again.
  UPDATING=0 HEADLINE='A few questions, then Josi installs itself.'
  if [ -n "$S_MODE" ] && [ -z "${GIVEN// /}" ]; then
    UPDATING=1 HEADLINE='Josi is already here: one question, then it updates itself.'
  fi
  q_header
  while :; do
    if [ "$UPDATING" != 1 ]; then
      ask_mode
      ask_port
      ask_pc
      ask_browser
    fi
    ask_model
    if summary; then break; fi
  done
  if [ "$styled" = 1 ]; then printf '\e[%dA\r\e[J' $((QL + QH)) >&5; fi
  CLI_ARGS=(--address-mode "$A_MODE" --port "$A_PORT")
  case $A_MODE in
    lan) CLI_ARGS+=(--lan-address "$A_LAN") ;;
    domain) CLI_ARGS+=(--domain "$A_DOMAIN"); if [ -n "$A_EMAIL" ]; then CLI_ARGS+=(--email "$A_EMAIL"); fi ;;
    *) CLI_ARGS+=(--public-url "$A_URL") ;;
  esac
  if [ "$A_NOPC" = 1 ] || [ -z "$A_PC" ]; then
    CLI_ARGS+=(--no-pc-control)
  elif [ "$A_BROWSER" = 1 ]; then
    CLI_ARGS+=(--pc-control-user "$A_PC" --browser)
  else
    CLI_ARGS+=(--pc-control-user "$A_PC" --no-browser)
  fi
  return 0
}

# ------------------------------------------------- Ollama and Josi's AI model
# Josi's model (josi-qwen3.5-9b) runs in Ollama on this computer. This part looks at what is
# here, says what it will install or update, and does it with the system's own tools: pacman on
# Arch, Ollama's official installer (with its systemd service) on Debian, Ubuntu and Fedora/Bazzite.
# The model file is a public image layer on Amazon ECR Public (no Docker needed), read with plain curl.
MODEL_NAME=${JOSI_MODEL_NAME:-josi-qwen3.5-9b}
MODEL_REGISTRY=${JOSI_MODEL_REGISTRY:-public.ecr.aws}
MODEL_REPO=${JOSI_MODEL_REPO:-g3p9e4y8/josi-model}
MODEL_TAG=${JOSI_MODEL_TAG:-v6}
OLLAMA_WANT=${JOSI_OLLAMA_VERSION:-0.40.16}
MODEL_ON=1 MODEL_ERR='' OLL_HAVE='' OLL_ACTION=install MODEL_ACTION=install MODEL_STAMP=''
MEM_GB=0 GPU_TXT='' DISK_MSG='' MODEL_FROM_FILE=''
STAMP=/etc/josi/model-version  # not under /var/lib/josi: Josi refuses to start on a folder it did not make

# Tells the progress bar (another process) which stage the model step is in, and what to say.
mstage() { printf '%s\n' "$1" > "$work/mstage"; printf '%s\n' "$2" > "$work/mtext"; printf '%s\n' "$SECONDS" > "$work/mstart"; }

version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]; }

free_gb() { # free space in GB of the nearest folder that exists
  local d=$1
  while [ ! -d "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done
  df -Pk "$d" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }'
}

scan_model() {
  local tags a b same
  OLL_HAVE='' OLL_ACTION=install MODEL_ACTION=install MODEL_STAMP='' DISK_MSG='' GPU_TXT=''
  if command -v ollama >/dev/null 2>&1; then
    OLL_HAVE=$(ollama --version 2>&1 | sed -n 's/.*version is \([0-9][0-9.]*\).*/\1/p' | head -n 1)
    if [ -n "$OLL_HAVE" ] && version_ge "$OLL_HAVE" "$OLLAMA_WANT"; then OLL_ACTION=ok; else OLL_ACTION=update; fi
    [ -n "$OLL_HAVE" ] || OLL_HAVE='an unknown version'
  fi
  MODEL_STAMP=$(cat "$STAMP" 2>/dev/null || true)
  # The model is found by asking Ollama, not by a file: start it if it is installed but not running.
  if [ "$OLL_ACTION" != install ] && ! curl -fs --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    systemctl start ollama >/dev/null 2>&1 || true
    for a in 1 2 3 4 5 6 7 8; do curl -fs --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break; sleep 2; done
  fi
  tags=$(curl -fs --max-time 5 http://127.0.0.1:11434/api/tags 2>/dev/null || true)
  if printf '%s' "$tags" | grep -q "\"name\":\"$MODEL_NAME[:\"]"; then
    MODEL_ACTION=ok
    if [ -n "$MODEL_STAMP" ] && [ "$MODEL_STAMP" != "$MODEL_TAG" ]; then MODEL_ACTION=update; fi
  fi
  MEM_GB=$(awk '/^MemTotal:/ { print int(($2 + 524288) / 1048576) }' /proc/meminfo 2>/dev/null || echo 0)
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then GPU_TXT='NVIDIA GPU (Ollama uses it)'
  elif [ -e /dev/kfd ]; then GPU_TXT='AMD GPU (Ollama uses it)'
  elif command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -Eqi 'nvidia|amd/ati|radeon'; then GPU_TXT='a GPU whose driver is not installed yet (processor until it is)'
  else GPU_TXT='no GPU found (runs on the processor, slower)'; fi
  # Disk: Josi (about 6 GB) and the model (downloaded, unpacked, then stored: 12 GB at the peak).
  if [ "$MODEL_ACTION" != ok ] && [ -z "$MODEL_FROM_FILE" ]; then
    a=$(free_gb /var/lib) b=$(free_gb /var/tmp)
    same=0; [ "$(stat -c %d /var/lib 2>/dev/null)" = "$(stat -c %d /var/tmp 2>/dev/null)" ] && same=1
    if [ "$same" = 1 ] && [ "${a:-0}" -lt 18 ]; then DISK_MSG="about 18 GB are needed for Josi and the model, ${a:-0} GB are free"
    elif [ "$same" = 0 ] && { [ "${a:-0}" -lt 12 ] || [ "${b:-0}" -lt 12 ]; }; then DISK_MSG="about 12 GB are needed on /var/lib and on /var/tmp, ${a:-0} and ${b:-0} GB are free"; fi
  fi
  return 0
}

# What the summary and the question say about each part.
model_text() { # $1 ollama|model
  if [ "$MODEL_ON" != 1 ]; then REPLY='left alone'; return 0; fi
  if [ "$1" = ollama ]; then
    case $OLL_ACTION in
      install) REPLY="not installed: will be installed (version $OLLAMA_WANT)" ;;
      update) REPLY="$OLL_HAVE is installed: will be updated to $OLLAMA_WANT" ;;
      *) REPLY="$OLL_HAVE is installed: up to date" ;;
    esac
  else
    case $MODEL_ACTION in
      install) REPLY='not here: will be downloaded (5.8 GB)' ;;
      update) REPLY="version $MODEL_STAMP is here: will be updated to $MODEL_TAG (5.8 GB)" ;;
      *) REPLY="$MODEL_NAME is here: up to date" ;;
    esac
  fi
}

ask_model() {
  local d=y
  case $GIVEN in *' model '*) return 0 ;; esac
  if [ "$OLL_ACTION" = ok ] && [ "$MODEL_ACTION" = ok ]; then return 0; fi
  while :; do
    q_clear
    q "${BOLD}Set up Josi's AI model on this computer?${RST}"
    model_text ollama; q "  ${LILAC}Ollama${RST}   $REPLY"
    model_text model; q "  ${LILAC}Model${RST}    $REPLY"
    q "  ${LILAC}Machine${RST}  ${MEM_GB} GB memory, ${GPU_TXT}"
    if [ "$MEM_GB" -lt 8 ] && [ "$MEM_GB" -gt 0 ]; then q "${DIM}  The model wants about 8 GB of memory; with ${MEM_GB} GB it will be slow.${RST}"; fi
    if [ -n "$DISK_MSG" ]; then q "${DIM}  Not enough disk: ${DISK_MSG}.${RST}"; d=n; fi
    q ''
    ask 'Set it up? (y/n):' "$d" choice
    REPLY=${REPLY:-$d}
    case ${REPLY,,} in
      y | yes) MODEL_ON=1; return 0 ;;
      n | no) MODEL_ON=0; return 0 ;;
      *) ERR='Type y or n.' ;;
    esac
  done
}

ollama_unit() {
  # What the service needs on top of Ollama's own: models stay loaded, and on an image-based
  # system (read-only /usr) the models go under /var.
  local d=/etc/systemd/system/ollama.service.d
  mkdir -p "$d"
  {
    printf '[Service]\n'
    printf 'Environment="OLLAMA_KEEP_ALIVE=-1"\n'
    # Another file of the administrator's that sets the folder wins; our own file from an earlier run does not count.
    if atomic && ! grep -qs 'OLLAMA_MODELS=' /etc/systemd/system/ollama.service $(ls /etc/systemd/system/ollama.service.d/*.conf 2>/dev/null | grep -v '/josi.conf$'); then
      mkdir -p /var/lib/ollama/models; chown -R ollama:ollama /var/lib/ollama 2>/dev/null || true
      printf 'Environment="OLLAMA_MODELS=/var/lib/ollama/models"\n'
    fi
  } > "$d/josi.conf"
  if ! systemctl cat ollama >/dev/null 2>&1; then
    id ollama >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -U -m -d /var/lib/ollama ollama
    cat > /etc/systemd/system/ollama.service <<UNIT
[Unit]
Description=Ollama
After=network-online.target

[Service]
ExecStart=$(command -v ollama) serve
User=ollama
Group=ollama
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
UNIT
  fi
  systemctl daemon-reload
  systemctl enable ollama >/dev/null 2>&1 || true
  systemctl restart ollama
}

ollama_ready() {
  local i
  for i in $(seq 1 60); do curl -fs --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}

# Arch does not support installing from a package list that is out of date, and a bare "pacman -Sy" can leave a
# half-upgraded system. Install from the current list first; only when that cannot find the package is the whole
# system brought up to date (pacman -Syu), and it says so.
pacman_get() {
  pacman -S --needed --noconfirm "$@" && return 0
  echo 'pacman could not find it in the package list on this computer: updating the whole system first (pacman -Syu)'
  pacman -Syu --needed --noconfirm "$@"
}

install_ollama() {
  if [ "$family" = arch ]; then
    local pk=ollama
    if command -v nvidia-smi >/dev/null 2>&1; then pk='ollama ollama-cuda'
    elif [ -e /dev/kfd ] || { command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -Eqi 'amd/ati|radeon'; }; then pk='ollama ollama-rocm'; fi
    # shellcheck disable=SC2086
    pacman_get $pk
    return
  fi
  # Ollama's installer makes its user with a home under /usr/share, which an image-based system
  # does not allow; the user is made first, with a home under /var.
  if atomic && ! id ollama >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -U -m -d /var/lib/ollama ollama
  fi
  curl -fsSL --retry 3 --proto '=https' https://ollama.com/install.sh -o "$work/ollama-install.sh" || { echo 'could not download the Ollama installer'; return 1; }
  OLLAMA_VERSION=$OLLAMA_WANT sh "$work/ollama-install.sh"
}

# Where the model file is: a registry token, the manifest and the one big layer that holds the file.
model_find() {
  python3 -I - "$MODEL_REGISTRY" "$MODEL_REPO" "$MODEL_TAG" <<'PY'
import json, sys, urllib.request
registry, repo, tag = sys.argv[1:4]
def get(url, token=None, accept=None):
    req = urllib.request.Request(url)
    if token: req.add_header('Authorization', 'Bearer ' + token)
    if accept: req.add_header('Accept', accept)
    with urllib.request.urlopen(req, timeout=30) as r: return json.load(r)
token_url = 'https://public.ecr.aws/token/' if registry == 'public.ecr.aws' else 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:%s:pull' % repo
token = get(token_url)['token']
accept = ', '.join(['application/vnd.oci.image.index.v1+json', 'application/vnd.oci.image.manifest.v1+json',
                    'application/vnd.docker.distribution.manifest.list.v2+json', 'application/vnd.docker.distribution.manifest.v2+json'])
base = 'https://%s/v2/%s/manifests/' % (('registry-1.docker.io' if registry == 'registry-1.docker.io' else registry), repo)
m = get(base + tag, token, accept)
if 'manifests' in m:
    m = get(base + m['manifests'][0]['digest'], token, accept)
layer = max(m['layers'], key=lambda l: l['size'])
print(layer['digest'], layer['size'], token)
PY
}

# Puts the .gguf in $work/model and its path in $work/model/path. The files $work/mtotal and
# $work/mphase tell the progress bar (it runs in another process) how far this is.
fetch_model() {
  local d=$work/model src digest size token i got
  mkdir -p "$d"
  if [ -n "$MODEL_FROM_FILE" ]; then printf '%s\n' "$MODEL_FROM_FILE" > "$d/path"; return 0; fi
  src=${MODEL_FROM:-}
  case $src in
    http://* | https://*)
      mstage 2 "2/5 Downloading the model"
      curl -fL --retry 5 --retry-delay 5 -C - -o "$d/model.gguf" "$src" || { echo 'could not download the model'; return 1; }
      printf '%s\n' "$d/model.gguf" > "$d/path"; return 0 ;;
  esac
  read -r digest size token < <(model_find) || { echo "could not find the model $MODEL_REPO:$MODEL_TAG on $MODEL_REGISTRY"; return 1; }
  printf '%s\n' "$size" > "$work/mtotal"
  mstage 2 "2/5 Downloading the model"
  for i in 1 2 3 4 5 6; do
    [ "$i" = 1 ] || read -r _ _ token < <(model_find) || true
    curl -fL --retry 3 --retry-delay 5 -C - -H "Authorization: Bearer $token" -o "$d/layer" \
      "https://$MODEL_REGISTRY/v2/$MODEL_REPO/blobs/$digest" && break
    [ "$i" -lt 6 ] || { echo 'the model download did not finish'; return 1; }
    sleep 5
  done
  got=$(stat -c %s "$d/layer" 2>/dev/null || echo 0)
  [ "$got" = "$size" ] || { echo "the model download is incomplete ($got of $size bytes)"; return 1; }
  mstage 3 "3/5 Checking the download (a checksum of 5.7 GB, about half a minute)"
  [ "$(sha256sum "$d/layer" | cut -d' ' -f1)" = "${digest#sha256:}" ] || { echo 'the downloaded model did not match its checksum'; rm -f "$d/layer"; return 1; }
  mstage 4 "4/5 Unpacking the model file"
  tar -xf "$d/layer" -C "$d" || { echo 'could not unpack the model'; return 1; }
  rm -f "$d/layer"
  src=$(find "$d" -maxdepth 2 -name '*.gguf' | head -n 1)
  [ -n "$src" ] || { echo 'no model file in the download'; return 1; }
  printf '%s\n' "$src" > "$d/path"
}

create_model() {
  local gguf
  gguf=$(cat "$work/model/path")
  chmod a+r "$gguf"
  printf 'FROM %s\nPARAMETER num_ctx 24576\n' "$gguf" > "$work/model/Modelfile"
  mstage 5 "5/5 Loading the model into Ollama (it takes a few minutes and is quiet)"
  ollama create "$MODEL_NAME" -f "$work/model/Modelfile" || { echo 'ollama could not create the model'; return 1; }
  ollama list | grep -q "^$MODEL_NAME" || { echo 'the model is not in Ollama after creating it'; return 1; }
  [ -n "$MODEL_FROM_FILE" ] || rm -rf "$work/model"
  return 0
}

setup_model() {
  mstage 0 "Found: Ollama $([ "$OLL_ACTION" = install ] && echo 'not installed' || echo "$OLL_HAVE"), model $([ "$MODEL_ACTION" = install ] && echo 'not here' || echo 'here'), ${MEM_GB} GB memory, $GPU_TXT"
  if [ "$OLL_ACTION" != ok ]; then
    mstage 1 "1/5 $([ "$OLL_ACTION" = update ] && echo Updating || echo Installing) Ollama $OLLAMA_WANT (it downloads about 1.5 GB from ollama.com)"
    echo "== Ollama ($OLL_ACTION)"; install_ollama || { echo 'Ollama was not installed'; return 1; }
  else
    mstage 1 "1/5 Ollama $OLL_HAVE is already installed"
  fi
  ollama_unit
  ollama_ready || { echo 'Ollama does not answer on 127.0.0.1:11434'; return 1; }
  if ! ollama list 2>/dev/null | grep -q "^$MODEL_NAME" || [ "$MODEL_ACTION" = update ]; then
    echo "== model ($MODEL_ACTION)"
    fetch_model && create_model || return 1
  else
    mstage 5 "The AI model is already in Ollama: nothing to download"
  fi
  mkdir -p "$(dirname "$STAMP")" && printf '%s\n' "$MODEL_TAG" > "$STAMP"
  return 0
}

# ------------------------------------------------------------- the commands

apt_get() { apt-get -o "$APT_LOCK" -o APT::Status-Fd=4 "$@" 4>"$work/status"; }
download() {
  if [ -n "$FROM_DIR" ]; then cp -- "$FROM_DIR/$package" "$work/$package"; return; fi
  curl --fail --location --silent --show-error --proto "$proto" --retry 3 \
    --output "$work/$package" "$BASE_URL/$package"
}
checksum() { sha256sum "$work/$package" > "$work/sum"; }
start_josi() { /usr/bin/josi-ce-server-install 2>&3 > "$work/url" ${CLI_ARGS[@]+"${CLI_ARGS[@]}"}; }

# On an image-based system (Bazzite and the other image-based Fedoras) a swapped Josi package takes effect
# after a restart. Nothing else depends on that, so the AI model is set up first; this makes a one-time
# service that starts Josi after the restart and writes the address where the person can read it.
schedule_finish() {
  local args=''
  if [ "${#CLI_ARGS[@]}" -gt 0 ]; then args=$(printf '%q ' "${CLI_ARGS[@]}"); fi
  mkdir -p /usr/local/sbin /etc/josi
  cat > /usr/local/sbin/josi-finish-install <<SCRIPT
#!/bin/sh
# Written by the Josi installer; runs once after the restart that puts the Josi package in the system image.
/usr/bin/josi-ce-server-install $args > /etc/josi/first-address.txt 2>> /var/log/josi-finish.log || exit 1
systemctl disable josi-finish-install.service
rm -f /etc/systemd/system/josi-finish-install.service /usr/local/sbin/josi-finish-install
SCRIPT
  chmod 755 /usr/local/sbin/josi-finish-install
  cat > /etc/systemd/system/josi-finish-install.service <<UNIT
[Unit]
Description=Finish the Josi install after the restart
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/bin/josi-ce-server-install

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/josi-finish-install

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable josi-finish-install.service
}

# The calm ending for that case: not a failure, so no red cross and an exit code of 0.
restart_notice() {
  local addr reply=''
  case $A_MODE in
    domain) addr="https://$A_DOMAIN" ;;
    proxy) addr=$A_URL ;;
    *) addr="http://${A_LAN:-$LAN_IP}:${A_PORT:-8080}" ;;
  esac
  if [ "$screen" = 1 ]; then
    final=1 dirty=1
    if [ "$GL" -gt 0 ]; then HEAD[7]="${GOLD}${OK} One restart to go.${RST}"; fi
    draw
    printf '\n  %s%s%s Josi and its AI model are installed. Josi starts by itself after one restart of this computer.\n' "$GREEN" "$OK" "$RST" >&2
    printf '  %sThen open it at:%s\n\n' "$DIM" "$RST" >&2
    printf '  %s%s%s\n\n' "$BOLD$GOLD" "$addr" "$RST" >&2
    printf '  %s(If it does not open: sudo cat /etc/josi/first-address.txt)%s\n\n' "$DIM" "$RST" >&2
    if [ -r /dev/tty ] && [ "$TTY" = 1 ]; then
      read -r -t 60 -p "  Restart now? [y/N] " reply <&5 >&5 2>&5 || reply=''
      case ${reply,,} in y | yes) printf '\n  Restarting...\n' >&2; systemctl reboot ;; esac
    fi
  else
    printf 'Josi is installed. It starts by itself after one restart of this computer; then open %s\n' "$addr" >&2
  fi
  printf '%s\n' "$addr"
  exit 0
}


main() {
  local line missing actual rest port helpers='' mdeps=''
  parse_args "$@"
  [ "$(uname -s)" = Linux ] || fail 'Linux is required'
  [ "$(id -u)" = 0 ] || fail 'run it as root: curl -fsSL <address>/linux | sudo bash, or from a root shell: wget -qO- <address>/linux | bash'
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || fail 'systemd is required'
  if [ -d /var/lib/josi-ce-server ] && [ ! -e /var/lib/josi/installation.json ]; then
    fail "an earlier Josi CE Server from before the rename is in /var/lib/josi-ce-server, with services and
  accounts of the same names. Remove it first (this deletes its data; back up its chats in its
  Administration > Backups first), as root:
    systemctl disable --now josi-ce-database josi-ce-voice josi-ce-voice-control josi-ce-web josi-ce-worker josi-ce-proxy
    rm -f /etc/systemd/system/josi-ce-*.service; systemctl daemon-reload
    for a in database voice control web worker proxy; do userdel josi-ce-\$a; groupdel josi-ce-\$a; done
    groupdel josi-ce-app; groupdel josi-ce-voice-shared; rm -rf /var/lib/josi-ce-server
  then run this command again."
  fi

  case "$(uname -m)" in
    x86_64|amd64) processor=x86_64 ;;
    aarch64|arm64) processor=aarch64 ;;
    *) fail "this processor ($(uname -m)) is not supported" ;;
  esac

  : > "$log"; chmod 600 "$log"
  exec 3>>"$log"
  work=$(mktemp -d /var/tmp/josi-install.XXXXXX)
  chmod 755 "$work"
  trap cleanup EXIT
  trap 'interrupted=1; exit 130' INT TERM
  # A dropped SSH session must not stop dpkg or the lifecycle half-way: the
  # hangup is ignored here and, inherited, by everything this starts.
  trap '' HUP

  # Never a blank screen: say what is happening before anything that could wait, and leave a mark in the log for each
  # stage so a stall can be found (a stall before the first question was seen once over a web terminal).
  if [ -t 2 ]; then printf 'Josi installer: looking at this computer...\n' >&2; fi
  printf 'stage: init_screen\n' >&3; init_screen
  printf 'stage: open_tty\n' >&3; open_tty
  printf 'stage: load_saved\n' >&3; load_saved
  printf 'stage: detect_lan\n' >&3; detect_lan
  # The model file: given with --model-from, or in the folder of an offline install.
  case $MODEL_FROM in
    http://* | https://* | '') [ -n "$MODEL_FROM" ] || { [ -n "$FROM_DIR" ] && [ -f "$FROM_DIR/$MODEL_NAME.gguf" ] && MODEL_FROM_FILE=$(readlink -f "$FROM_DIR/$MODEL_NAME.gguf"); } || true ;;
    *) [ -f "$MODEL_FROM" ] || fail "the model file $MODEL_FROM does not exist"; MODEL_FROM_FILE=$(readlink -f "$MODEL_FROM") ;;
  esac
  printf 'stage: scan_model\n' >&3; scan_model
  printf 'stage: questions\n' >&3; questions
  restore_outer
  if [ "$MODEL_ON" = 1 ] && [ -n "$DISK_MSG" ]; then
    fail "not enough free disk space for Josi's AI model: $DISK_MSG. Nothing was changed. Free some space and run the installer again, or add --no-model to install Josi without the model."
  fi
  printf 'Answers: %s\n' "${CLI_ARGS[*]-saved or default}" >&3
  start_screen

  begin 0
  if command -v pacman >/dev/null 2>&1; then
    family=arch
  elif command -v apt-get >/dev/null 2>&1; then
    family=debian
  elif command -v rpm >/dev/null 2>&1 && { command -v dnf >/dev/null 2>&1 || command -v dnf5 >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || atomic; }; then
    family=rpm
  else
    fail 'this installer supports Arch (pacman), Debian or Ubuntu (apt) and Fedora (dnf, or rpm-ostree on Bazzite and the other image-based Fedoras)'
  fi
  line=$(printf '%s\n' "$PACKAGES" | awk -v f="$family" -v p="$processor" '$1 == f && $2 == p { print; exit }')
  package=$(printf '%s' "$line" | awk '{ print $3 }')
  expected=$(printf '%s' "$line" | awk '{ print $4 }')
  [ -n "$package" ] && [ "$package" != - ] || fail "no Josi $VERSION package is built for $family on $processor yet"
  printf 'Josi %s for %s %s\n' "$VERSION" "$family" "$processor" >&3
  finish

  begin 1
  # PC control on a machine with a graphical login: the optional desktop
  # helpers (typing, windows, screenshots). Never required.
  if [ "$A_NOPC" != 1 ] && [ -n "$A_PC" ] && has_desktop; then helpers='xdotool wmctrl scrot'; fi
  if [ "$MODEL_ON" = 1 ]; then mdeps="zstd tar"; fi
  if [ "$family" = arch ]; then
    missing=$(pacman -T curl python rsync acl iproute2 $mdeps || true)
    if [ -n "$missing" ]; then
      # shellcheck disable=SC2086
      run pacman_get $missing || fail 'pacman could not install the dependencies'
    fi
    if [ -n "$helpers" ]; then
      # shellcheck disable=SC2086
      run pacman -S --needed --noconfirm $helpers || printf 'Desktop helpers were not installed\n' >&3
    fi
  elif [ "$family" = rpm ]; then
    # What Josi needs from the system. On an image-based system (Bazzite, Silverblue,
    # Kinoite) a package is part of the system image: what is missing is added in the
    # same step as Josi (below), so there is one change and one restart at most.
    # The desktop helpers (typing, windows, screenshots) work on X11 only, and the image-based
    # desktops are Wayland: adding them to a system image would add three packages for nothing.
    if atomic; then helpers=''; fi
    rpm_missing curl python3 rsync acl iproute libstdc++ ca-certificates policycoreutils-python-utils $mdeps $helpers
    LAYER_EXTRA=$REPLY
    if [ -n "$LAYER_EXTRA" ] && ! atomic; then
      # shellcheck disable=SC2086
      run "$(rpm_tool)" install -y $LAYER_EXTRA || fail 'the system could not install what Josi needs'
      LAYER_EXTRA=''
    fi
    if [ "$A_NOPC" != 1 ] && [ -n "$A_PC" ] && [ "$A_BROWSER" = 1 ]; then install_browser_packages; fi
  else
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    # Finish what an interrupted apt or dpkg (Ctrl-C, a dropped session) left
    # half-configured; until then apt refuses to install anything.
    run dpkg --configure -a || printf 'dpkg --configure -a did not finish\n' >&3
    run apt-get -o "$APT_LOCK" update -q || fail 'apt-get update failed'
    run apt_get install -y -q ca-certificates curl python3 rsync acl iproute2 $mdeps || fail 'apt could not install the dependencies'
    if [ -n "$helpers" ]; then
      # shellcheck disable=SC2086
      run apt_get install -y -q --no-install-recommends $helpers || printf 'Desktop helpers were not installed\n' >&3
    fi
    if [ "$A_NOPC" != 1 ] && [ -n "$A_PC" ] && [ "$A_BROWSER" = 1 ]; then install_browser_packages; fi
  fi
  finish

  # The same version is already installed and its program is there: no download, check or install.
  same=0
  if [ "$REINSTALL" != 1 ] && [ -x /usr/bin/josi-ce-server-install ]; then
    case $family in
      arch) have=$(pacman -Q josi 2>/dev/null | awk '{ print $2 }'); want=$(printf '%s' "$package" | sed 's/^josi-//; s/-x86_64\.pkg.*$//; s/-aarch64\.pkg.*$//') ;;
      rpm) have=$(rpm -q --qf '%{VERSION}-%{RELEASE}' josi 2>/dev/null || true); want=$(printf '%s' "$package" | sed 's/^josi-//; s/\.[a-z0-9_]*\.rpm$//') ;;
      *) have=$(dpkg-query -W -f='${Version}' josi 2>/dev/null || true); want=$(printf '%s' "$package" | sed 's/^josi_//; s/_[a-z0-9]*\.deb$//; s/-beta/~beta/') ;;
    esac
    if [ -n "$have" ] && [ "$have" = "$want" ]; then same=1; fi
  fi
  if [ "$same" = 1 ]; then
    for i in 2 3 4; do begin "$i"; printf 'Josi %s is already installed: step skipped\n' "$VERSION" >&3; finish; done
  else
  begin 2
  proto='=https'
  case "$BASE_URL" in http://*) proto='=http,https' ;; esac
  if [ -n "$FROM_DIR" ]; then
    [ -f "$FROM_DIR/$package" ] || fail "$package is not in $FROM_DIR"
    size=0
  else
    size=$(curl -fsIL --proto "$proto" --max-time 20 "$BASE_URL/$package" 2>/dev/null | tr -d '\r' \
      | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }') || size=0
  fi
  case $size in '' | *[!0-9]*) size=0 ;; esac
  [ "$size" -gt 1048576 ] || size=0
  rate_at=$SECONDS rate_got=0
  run download || fail "could not download $package"
  finish

  begin 3
  run checksum || fail 'could not read the downloaded package'
  actual=$(cut -d' ' -f1 "$work/sum")
  [ "$actual" = "$expected" ] || fail 'the downloaded package did not match this installer; nothing was installed'
  finish

  begin 4
  # Say so in plain words if the disk cannot hold the new program (about 6 GB:
  # the package unpacked, a second copy beside the old one, and a copy of the
  # data). Old versions an upgrade would remove count as free.
  need_kb=$((6 * 1024 * 1024))
  free_kb=$(df -Pk /var/lib 2>/dev/null | awk 'NR == 2 { print $4 + 0 }') || free_kb=0
  case $free_kb in '' | *[!0-9]*) free_kb=0 ;; esac
  back_kb=0
  if [ -d /var/lib/josi/versions ]; then
    for v in /var/lib/josi/versions/*; do
      [ -d "$v" ] && [ ! -L "$v" ] && [ "${v##*/}" != "$CUR_VERSION" ] || continue
      back_kb=$((back_kb + $(du -sk "$v" 2>/dev/null | awk '{ print $1 + 0 }')))
    done
  fi
  if [ "$free_kb" -gt 0 ] && [ $((free_kb + back_kb)) -lt "$need_kb" ]; then
    fail "not enough free disk space: Josi needs about 6 GB free on /var/lib and only $((free_kb / 1048576)) GB is free. Nothing was changed. Free some space and run the installer again."
  fi
  if [ "$family" = arch ]; then
    run pacman -U --noconfirm "$work/$package" || fail 'pacman could not install the Josi package'
  elif [ "$family" = rpm ]; then
    if atomic; then
      # Added to the system image and applied to the running system without a restart where
      # the system allows it. --idempotent: running this again after a restart is fine.
      want=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$work/$package" 2>/dev/null) || want=''
      have=$(rpm -q --qf '%{VERSION}-%{RELEASE}' josi 2>/dev/null) || have=''
      if [ -n "$have" ] && [ "$have" != "$want" ]; then
        # An older Josi is part of the image: swap it for this one in a single change.
        # shellcheck disable=SC2086
        extra_args=(); for x in $LAYER_EXTRA; do extra_args+=(--install "$x"); done
        run rpm-ostree uninstall -y --allow-inactive josi --install "$work/$package" ${extra_args[@]+"${extra_args[@]}"} \
          || fail 'rpm-ostree could not replace the Josi package in the system image'
      else
        # shellcheck disable=SC2086
        run rpm-ostree install -y --idempotent --apply-live --allow-inactive $LAYER_EXTRA "$work/$package" \
          || fail 'rpm-ostree could not add the Josi package to the system image'
      fi
      # What is running is what was asked for only when the live system has this version; a change
      # that could not be applied live is in the next boot's image.
      if ! { [ -x /usr/bin/josi-ce-server-install ] && [ "$(rpm -q --qf '%{VERSION}-%{RELEASE}' josi 2>/dev/null)" = "$want" ]; }; then NEED_RESTART=1; fi
    else
      run "$(rpm_tool)" install -y "$work/$package" || fail 'the system could not install the Josi package'
    fi
  else
    run apt_get install -y -q "$work/$package" || fail 'apt could not install the Josi package'
  fi
  finish
  fi

  begin 5
  if [ "$MODEL_ON" = 1 ]; then
    if ! run setup_model; then
      MODEL_ERR="Josi's AI model was not set up (the details are in $log). Josi itself is installed; run the same command again to retry."
    fi
  else
    printf 'AI model: left alone\n' >&3
  fi
  finish

  begin 6
  open_firewall
  if [ "$NEED_RESTART" = 1 ]; then
    run schedule_finish || printf 'The service that finishes after the restart could not be made\n' >&3
    finish
    restart_notice
  fi
  run start_josi || fail 'Josi did not start'
  url=$(head -n 1 "$work/url")
  [ -n "$url" ] || fail 'Josi started but did not give an address'
  finish

  if [ "$screen" = 1 ]; then
    final=1 dirty=1
    if [ "$GL" -gt 0 ]; then HEAD[7]="${GREEN}${OK} Ready.${RST}"; fi
    draw
    case $url in
      *'#handoff='*) printf '\n  %s%s%s Open this address in a browser to set Josi up:\n\n' "$GREEN" "$OK" "$RST" >&2 ;;
      *) printf '\n  %s%s%s Josi is running. Open it at:\n\n' "$GREEN" "$OK" "$RST" >&2 ;;
    esac
  fi
  if [ -n "$MODEL_ERR" ]; then printf '\n  %s\n' "$MODEL_ERR" >&2; fi
  # The one line on stdout. In a terminal it is indented and in gold.
  if [ "$screen" = 1 ] && [ -t 1 ]; then
    printf '  %s%s%s\n' "$BOLD$GOLD" "$url" "$RST"
  else
    printf '%s\n' "$url"
  fi
  if [ "$screen" = 1 ]; then
    case $url in
      https://*)
        # Until the domain's DNS and certificate are in place, or the proxy
        # forwards, the same link works on this network over plain HTTP.
        port=$(sed -n 's/.*"publicPort": *\([0-9][0-9]*\).*/\1/p' /var/lib/josi/status.json 2>/dev/null || true)
        rest=${url#https://}; rest=${rest#*/}
        printf '\n  %sIf that address does not open yet, on this network use http://%s:%s/%s%s\n' \
          "$DIM" "$LAN_IP" "${port:-8080}" "$rest" "$RST" >&2 ;;
    esac
    case $url in
      *'#handoff='*) printf '\n  %sThe link works once, for 10 minutes. Run the same command again for a new one.%s\n\n' "$DIM" "$RST" >&2 ;;
      *) printf '\n' >&2 ;;
    esac
  fi
}

main "$@"
