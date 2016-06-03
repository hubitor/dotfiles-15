#!/usr/bin/env bash
. gettext.sh
export TEXTDOMAIN=downgrade
export TEXTDOMAINDIR=/usr/share/locale

present_packages() {
  local i=1

  (($#)) || return 1

  gettext 'Available packages:'
  printf "\n\n"

  for entry; do
    output_package "$((i++))" "$entry"
  done

  printf "\n"
  gettext 'select a package by number: '
}

read_selection() {
  local ans

  ans=2
  #read -r ans

  ((ans > 0 && ans <= $#)) && printf "%s" "${!ans}"
}

download_when_remote() {
  local pkg="$1" url

  if [[ "$pkg" == 'http://'* ]]; then
    url="$pkg"
    pkg="${url##*/}"

    if ! curl --silent "$url" > "$pkg"; then
      rm "$pkg"
      return 1
    fi
  fi

  [[ -f "$pkg" ]] && printf "%s" "$pkg"
}

prompt_to_ignore() {
  local pkg ans ln

  for pkg; do
    grep -Eq '^IgnorePkg.*( |=)'"$pkg"'( |$)' "$PACMAN_CONF" && return 0

    eval_gettext "add \$pkg to IgnorePkg? [y/n] "
    ans=n

    if [[ "${ans,,}" == $(gettext 'y')* ]]; then
      ln="$(grep -n -m 1 '^ *IgnorePkg' "$PACMAN_CONF" | cut -d : -f 1)"
      if [ -n "$ln" ]; then
        sudo sed -i "$ln s/.*/& $pkg/" "$PACMAN_CONF"
        continue
      fi

      ln="$(grep -n '^# *IgnorePkg' "$PACMAN_CONF" | tail -n 1 | cut -d : -f 1)"
      if [ -n "$ln" ]; then
        sudo sed -i "$ln s/.*/&\nIgnorePkg = $pkg/" "$PACMAN_CONF"
        continue
      fi

      sudo printf "IgnorePkg = %s\n" "$pkg" >> "$PACMAN_CONF"
    fi
  done
}

search_packages() {
  ((NOARM)) || \
    curl --fail --silent --data "arch=$ARCH" \
         --data-urlencode "pkgname=$1" "$ARM_URL/exact" | cut -d '|' -f 5

  ((NOCACHE)) || \
    find $( sed '/^#\?CacheDir *= *\(.*\)$/!d;s//\1/' "$PACMAN_CONF" ) \
      -name "$1-[0-9R]*.pkg.tar.[gx]z"
}

sort_packages() {
  grep -Fv 'testing/' \
    | awk 'BEGIN { FS="/"; OFS="|" } { print $NF, $0 }' \
    | sort -rV -t '|' -k 1 | cut -d '|' -f 2-
}

output_package() {
  printf "%4.4s) %s\n" "$1" "$(
    sed 's|http://.*/\([^/]\+\)$|\1 ('"$(gettext 'remote')"')|;
         s|^/.*/\([^/]\+\)$|\1 ('"$(gettext 'local')"')|;' <<< "$2")"
}

main() {
  local term candidates choice pkg exit_code=0

  (($#)) || return 1

  for term; do
    candidates=( $(search_packages "$term" | sort_packages) )

    if present_packages "${candidates[@]}"; then
      if choice="$(read_selection "${candidates[@]}")"; then
        if pkg="$(download_when_remote "$choice")"; then
          to_ignore+=( "$term" )
          to_install+=( "$pkg" )
          continue
        fi
      fi
    fi

    exit_code=1
  done

  return $exit_code
}

ARCH=${ARCH:-$(uname -m)}
PACMAN="${PACMAN:-pacman}"
PACMAN_CONF="${PACMAN_CONF:-/etc/pacman.conf}"
ARM_URL="${ARM_URL:-http://repo-arm.archlinuxcn.org}"
NOARM=${NOARM:-0}
NOCACHE=${NOCACHE:-0}
NOSUDO=${NOSUDO:-0}

declare -a terms
declare -a to_ignore
declare -a to_install
declare -a pacman_args

while [[ -n "$1" ]]; do
  case "$1" in
    --) shift; pacman_args=( "$@" ); break ;;
    *)  terms+=( "$1" ); shift ;;
  esac
done

if (( ! "${#terms[@]}" )) && ((!LIB)); then
  ( gettext 'usage: downgrade <pkg>, ... [-- <pacman options>]'; echo
    gettext 'see downgrade(8) for details.'; echo
  ) >&2
  exit 1
fi

if ((NOSUDO)) || ! type -p sudo &>/dev/null; then
  sudo() {
    printf -v cmd "%q " "$@"
    su root -c "$cmd"
  }
fi

if main "${terms[@]}"; then
  if sudo pacman --noconfirm -U "${pacman_args[@]}" "${to_install[@]}"; then
    prompt_to_ignore "${to_ignore[@]}"
  fi
fi
