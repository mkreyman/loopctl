#!/usr/bin/env bash
# Installs (or removes) this user's crontab line that runs `chg outbox send` every 10
# minutes, so ledger rows and change events reach loopctl even on a machine with no push
# to start a send (docs/outbox.md). Idempotent: the line is found by its marker comment
# and replaced, never duplicated.
#
#   bin/chg-outbox-cron.sh --install [--chg /path/to/chg]
#   bin/chg-outbox-cron.sh --remove
#   bin/chg-outbox-cron.sh --show
#
# CRONTAB names the crontab binary (tests point it at a fake).
set -euo pipefail

MARK="# chg-outbox-send"
crontab_bin=${CRONTAB:-crontab}
action=""
chg_bin=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install|--remove|--show) action=${1#--} ;;
    --chg) chg_bin=${2:?--chg needs a path}; shift ;;
    *) echo "usage: $0 --install [--chg PATH] | --remove | --show" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$action" ] || { echo "usage: $0 --install [--chg PATH] | --remove | --show" >&2; exit 2; }

current=$("$crontab_bin" -l 2>/dev/null || true)
others=$(printf '%s\n' "$current" | grep -vF "$MARK" || true)

case "$action" in
  show)
    printf '%s\n' "$current" | grep -F "$MARK" || echo "not installed"
    ;;
  remove)
    printf '%s\n' "$others" | sed '/^$/d' | "$crontab_bin" -
    echo "removed"
    ;;
  install)
    if [ -z "$chg_bin" ]; then
      chg_bin=$(command -v chg || true)
    fi
    if [ -z "$chg_bin" ] || [ ! -x "$chg_bin" ]; then
      echo "chg not found; pass --chg PATH" >&2
      exit 1
    fi
    case "$chg_bin" in /*) ;; *) chg_bin="$PWD/$chg_bin" ;; esac
    home="${CHG_HOME:-$HOME/.chg}"
    # cron's sh opens the log before chg runs, so its directory must exist first.
    mkdir -p "$home/outbox"
    # The command gets the same CHG_HOME the log path was built from. Paths are quoted
    # for sh; one holding a single quote is refused rather than escaped.
    case "$chg_bin$home" in *\'*) echo "a path holds a single quote; not installing" >&2; exit 1 ;; esac
    line="*/10 * * * * CHG_HOME='$home' nice -n 10 '$chg_bin' outbox send --quiet >> '$home/outbox/send.log' 2>&1 $MARK"
    { printf '%s\n' "$others" | sed '/^$/d'; printf '%s\n' "$line"; } | "$crontab_bin" -
    echo "installed: $line"
    ;;
esac
