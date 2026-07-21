#!/bin/bash
# dreamos-buildsystem MOTD
# Shown once per interactive shell (SSH login OR docker run/exec).
# The DREAMOS_MOTD_SHOWN env var guard prevents re-showing across
# nested shells within the same session.
[ -n "${DREAMOS_MOTD_SHOWN:-}" ] && return 0 2>/dev/null || [ -n "${DREAMOS_MOTD_SHOWN:-}" ] && exit 0
case $- in *i*) :;; *) return 0 2>/dev/null || exit 0;; esac
export DREAMOS_MOTD_SHOWN=1

# --- colors (skip if not a real tty) ---
if [ -t 1 ]; then
    b=$'\e[1m'; c=$'\e[36m'; g=$'\e[32m'; y=$'\e[33m'; d=$'\e[2m'; r=$'\e[0m'
else
    b=; c=; g=; y=; d=; r=
fi

V="${DREAMOS_IMAGE_VERSION:-dev}"

# --- header ---
printf '\n'
printf '%s' "$c$b"
cat <<'BANNER'
     _
  __| |_ __ ___  __ _ _ __ ___   ___  ___
 / _` | '__/ _ \/ _` | '_ ` _ \ / _ \/ __|
| (_| | | |  __/ (_| | | | | | | (_) \__ \
 \__,_|_|  \___|\__,_|_| |_| |_|\___/|___/
                                 buildsystem
BANNER
printf '%s' "$r"
printf '  %sopendreambox build environment%s   version %s%s%s\n' "$g" "$r" "$b" "$V" "$r"
printf '\n'

# --- sysinfo (compact, no external deps) ---
printf '%s%sSystem%s\n' "$b" "$c" "$r"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '  %sOS%s      %s\n' "$d" "$r" "${PRETTY_NAME:-unknown}"
fi
printf '  %sKernel%s  %s\n' "$d" "$r" "$(uname -r)"
if [ -r /proc/cpuinfo ]; then
    cpu=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')
    printf '  %sCPU%s     %s x %s\n' "$d" "$r" "$(nproc)" "${cpu:-unknown}"
fi
if command -v free >/dev/null 2>&1; then
    mem=$(free -h | awk '/^Mem:/{printf "%s used / %s total", $3, $2}')
    printf '  %sMemory%s  %s\n' "$d" "$r" "$mem"
fi
disk=$(df -h "$HOME" 2>/dev/null | awk 'NR==2{printf "%s used / %s total (%s free) on %s", $3, $2, $4, $6}')
[ -n "$disk" ] && printf '  %sDisk%s    %s\n' "$d" "$r" "$disk"
printf '\n'

# --- BuildEnv overview ---
printf '%s%sBuildEnvs%s   %s(at $HOME, bind-mounted from host ~/dreamos-builds)%s\n' "$b" "$c" "$r" "$d" "$r"
for be in opendreambox/krogoth opendreambox/pyro dreamlegacy/krogoth dreamlegacy/pyro; do
    if [ -d "$HOME/$be/.git" ]; then
        printf '  %s✓%s ~/%s\n' "$g" "$r" "$be"
    else
        fork="${be%%/*}"; branch="${be##*/}"
        printf '  %s·%s ~/%s  %s(bootstrap-buildenv %s %s)%s\n' "$d" "$r" "$be" "$d" "$fork" "$branch" "$r"
    fi
done
printf '\n'

# --- commands ---
printf '%s%sCommon commands%s\n' "$b" "$c" "$r"
printf '  cd ~/opendreambox/krogoth  &&  MACHINE=dm900 make image\n'
printf '  cd ~/opendreambox/krogoth  &&  MACHINE=dm900 make download   %s(pre-fetch only)%s\n' "$d" "$r"
printf '  cd build/dm900             &&  source bitbake.env && bitbake enigma2\n'
printf '  bootstrap-buildenv <fork> <branch>                   %s(re-clone/refresh)%s\n' "$d" "$r"
printf '  make help                                            %s(inside a BuildEnv)%s\n' "$d" "$r"
printf '\n'

# --- links ---
printf '%s%sDocs%s\n' "$b" "$c" "$r"
printf '  Repo:     https://github.com/WXbet-org/docker-images\n'
printf '  Readme:   https://github.com/WXbet-org/docker-images#4-build\n'
printf '  Package:  https://github.com/WXbet-org/docker-images/pkgs/container/dreamos-buildsystem-ubnt18\n'
printf '\n'
