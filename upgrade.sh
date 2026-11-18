#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

GC=0
GC_DAYS=30
MACOS=1
RESTART=0

usage() {
  cat <<'EOM'
Usage: upgrade.sh [--gc [DAYS]] [--no-macos] [--restart]

Moves every pinned version forward, then activates the result:

  1. nix flake update  - repoints flake.lock at current upstream
  2. rebuild.sh        - builds and switches to the new inputs
  3. brew update       - refreshes Homebrew's formula index
  4. brew upgrade      - upgrades installed formulae and casks
  5. softwareupdate    - installs pending macOS updates

rebuild.sh alone deliberately does none of this: it rebuilds from the
pins already in flake.lock, so it is reproducible. This script is the
explicit "move the world forward" step, and it leaves the resulting
flake.lock diff uncommitted for review.

Options:
  --gc [DAYS]  After switching, delete generations and store paths older
               than DAYS (default 30).
  --no-macos   Skip the macOS software update step.
  --restart    Let softwareupdate restart the Mac when an update needs it.
               Without it, the script only reports that a restart is due.
  -h, --help   Show this help.
EOM
}

while [ $# -gt 0 ]; do
  case "$1" in
    --gc)
      GC=1
      shift
      if [ $# -gt 0 ] && printf '%s' "${1:-}" | grep -qE '^[0-9]+$'; then
        GC_DAYS="$1"
        shift
      fi
      ;;
    --no-macos)
      MACOS=0
      shift
      ;;
    --restart)
      RESTART=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$RESTART" -eq 1 ] && [ "$MACOS" -eq 0 ]; then
  echo "Error: --restart has no effect together with --no-macos" >&2
  exit 1
fi

echo "==> Updating flake inputs"

lock_hash() {
  shasum -a 256 "$DIR/flake.lock" | awk '{print $1}'
}

LOCK_BEFORE="$(lock_hash)"
nix flake update --flake "$DIR"
LOCK_AFTER="$(lock_hash)"

if [ "$LOCK_BEFORE" = "$LOCK_AFTER" ]; then
  echo "flake.lock is unchanged - every Nix input was already current"
fi

# The system build runs before Homebrew so that a broken nixpkgs bump fails
# while the machine is still entirely on its old versions. Only flake.lock has
# changed at this point, and that is one `git checkout` away from undone.
echo "==> Activating the updated system"
if ! "$DIR/rebuild.sh"; then
  if [ "$LOCK_BEFORE" != "$LOCK_AFTER" ]; then
    cat >&2 <<EOM

The system was not switched, but flake.lock was already updated.
Restore the previous pins with:

    git -C "$DIR" checkout -- flake.lock

EOM
  fi
  exit 1
fi

if command -v brew >/dev/null 2>&1; then
  echo "==> Updating Homebrew"
  brew update

  echo "==> Upgrading Homebrew packages"
  # `homebrew.onActivation.upgrade` is deliberately left off in
  # configuration.nix, so darwin-rebuild installs declared packages but never
  # bumps them. This is the only place Homebrew versions move.
  brew upgrade
else
  echo "==> Skipping Homebrew (brew is not on PATH)"
fi

if [ "$GC" -eq 1 ]; then
  echo "==> Collecting garbage older than ${GC_DAYS} days"
  # After the switch, so the generation that was just activated is current and
  # therefore never a collection candidate.
  sudo nix-collect-garbage --delete-older-than "${GC_DAYS}d"
  nix-collect-garbage --delete-older-than "${GC_DAYS}d"
fi

if [ "$LOCK_BEFORE" != "$LOCK_AFTER" ]; then
  cat <<EOM

==> flake.lock moved. Review and commit it to keep the machine reproducible:

    git -C "$DIR" diff flake.lock
    git -C "$DIR" commit -m "Update flake inputs" flake.lock

EOM
fi

# macOS runs last because its updates may need a restart, which would cut off
# anything scheduled after it. `--all` covers the updates softwareupdate deems
# appropriate for this release; major macOS upgrades are not among them.
if [ "$MACOS" -eq 1 ]; then
  echo "==> Installing macOS software updates"
  if [ "$RESTART" -eq 1 ]; then
    sudo softwareupdate --install --all --agree-to-license --restart
  else
    sudo softwareupdate --install --all --agree-to-license
  fi
else
  echo "==> Skipping macOS software updates (--no-macos)"
fi
