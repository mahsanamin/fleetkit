#!/usr/bin/env bash
#
# colours.sh — the shared colour palette. Sourced, never run.
#
#   . "$(dirname "$0")/../lib/colours.sh"
#   resolve_colour orange   ->  COLOUR_NAME=orange  COLOUR_HEX='#ff8700'  COLOUR_INDEX=208
#
# WHY A SHARED FILE
#
# Two scripts need the same names: guest-setup.sh writes a hex into starship.toml on Linux,
# mac-setup.sh writes a 256-colour index into a zsh PROMPT on macOS. Same word in, same colour
# out, or the point of naming them is lost. So each name is defined once, with both forms.
#
# WHY NAMES AT ALL
#
# Starship knows eight colour names and a bright- variant of each; zsh knows the same eight.
# Sixteen is not many once you have a dozen machines, and those eight are what every other tool
# uses too, so they read as "a terminal colour" rather than "this machine".
#
# HOW THEY WERE PICKED
#
# For a real terminal, not a colour wheel. Nothing dark enough to disappear on a dark
# background, nothing pale enough to disappear on a light one, and neighbours far apart in hue,
# because the job is telling two machines apart at a glance at a row of tmux panes.

# name -> hex, for starship
palette_hex() {
  case "$1" in
    orange)    echo '#ff8700' ;;
    amber)     echo '#ffc000' ;;
    gold)      echo '#e0b000' ;;
    lime)      echo '#a6e22e' ;;
    mint)      echo '#5fd7af' ;;
    teal)      echo '#00b3a4' ;;
    sky)       echo '#56b6f7' ;;
    azure)     echo '#0087ff' ;;
    indigo)    echo '#6c7ae0' ;;
    violet)    echo '#a970ff' ;;
    lavender)  echo '#c3a6ff' ;;
    magenta)   echo '#ff5fff' ;;   # starship's own name for this is 'purple'
    pink)      echo '#ff79c6' ;;
    coral)     echo '#ff7a5c' ;;
    salmon)    echo '#ff9e80' ;;
    crimson)   echo '#e0405e' ;;
    brown)     echo '#b5651d' ;;
    slate)     echo '#90a4ae' ;;
    grey|gray) echo '#b0b0b0' ;;
    *) return 1 ;;
  esac
}

# name -> 256-colour index, for a zsh prompt. zsh's %F{} takes a name or an index; #rrggbb
# needs zsh 5.7+ AND a truecolor terminal, and fails to a default silently when either is
# missing. An index works on every terminal that has ever run this, so indexes it is.
palette_index() {
  case "$1" in
    orange)    echo 208 ;;
    amber)     echo 214 ;;
    gold)      echo 178 ;;
    lime)      echo 154 ;;
    mint)      echo 79  ;;
    teal)      echo 37  ;;
    sky)       echo 75  ;;
    azure)     echo 33  ;;
    indigo)    echo 62  ;;
    violet)    echo 141 ;;
    lavender)  echo 183 ;;
    magenta)   echo 207 ;;
    pink)      echo 212 ;;
    coral)     echo 209 ;;
    salmon)    echo 216 ;;
    crimson)   echo 197 ;;
    brown)     echo 130 ;;
    slate)     echo 109 ;;
    grey|gray) echo 145 ;;
    # Starship's eight, and the bright- variants, for the macOS side. zsh has no bright-
    # names, so those become the standard 8-15 indexes. zsh calls purple 'magenta', which is
    # the mirror image of starship's trap, hence the palette entry above.
    black)     echo 0 ;;
    red)       echo 1 ;;
    green)     echo 2 ;;
    yellow)    echo 3 ;;
    blue)      echo 4 ;;
    purple)    echo 5 ;;
    cyan)      echo 6 ;;
    white)     echo 7 ;;
    bright-black)  echo 8  ;;
    bright-red)    echo 9  ;;
    bright-green)  echo 10 ;;
    bright-yellow) echo 11 ;;
    bright-blue)   echo 12 ;;
    bright-purple) echo 13 ;;
    bright-cyan)   echo 14 ;;
    bright-white)  echo 15 ;;
    *) return 1 ;;
  esac
}

PALETTE_NAMES="orange amber gold lime mint teal sky azure indigo violet lavender magenta pink coral salmon crimson brown slate grey"

# An unknown name is not an error to starship — it renders unstyled, which looks exactly like
# the colour flag did nothing. So check before writing, and refuse rather than guess.
valid_colour() {
  case "$1" in
    black|red|green|yellow|blue|purple|cyan|white) return 0 ;;
    bright-black|bright-red|bright-green|bright-yellow) return 0 ;;
    bright-blue|bright-purple|bright-cyan|bright-white) return 0 ;;
    '#'*) return 0 ;;
    [0-9]|[0-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) return 0 ;;
    *) palette_hex "$1" >/dev/null 2>&1 ;;
  esac
}

list_colours() {
  echo "Named shades, the same word on every platform:"
  for n in $PALETTE_NAMES; do
    printf '   %-10s %-9s zsh index %s\n' "$n" "$(palette_hex "$n")" "$(palette_index "$n")"
  done
  echo
  echo "Also accepted: black red green yellow blue purple cyan white, a bright- variant of"
  echo "each, a hex like '#ff8800' (QUOTE it, or the shell reads it as a comment), or a"
  echo "0-255 index like 208."
}

# Sets COLOUR_NAME (empty if the caller passed a raw hex/index), COLOUR_HEX and COLOUR_INDEX.
# A raw value passes through in whichever form it was given; the other stays empty, and the
# caller decides whether it can use it.
resolve_colour() {
  COLOUR_NAME=""; COLOUR_HEX=""; COLOUR_INDEX=""
  if palette_hex "$1" >/dev/null 2>&1; then
    COLOUR_NAME="$1"
    COLOUR_HEX="$(palette_hex "$1")"
    COLOUR_INDEX="$(palette_index "$1")"
  elif palette_index "$1" >/dev/null 2>&1; then     # one of starship's own names
    COLOUR_NAME="$1"
    COLOUR_HEX="$1"
    COLOUR_INDEX="$(palette_index "$1")"
  else
    case "$1" in
      '#'*) COLOUR_HEX="$1" ;;
      *)    COLOUR_HEX="$1"; COLOUR_INDEX="$1" ;;   # a 0-255 index works in both
    esac
  fi
}
