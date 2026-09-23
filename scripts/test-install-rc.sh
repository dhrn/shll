#!/bin/sh
# Tests scripts/install.sh's rc-file persistence of brew's shellenv line
# (persist_brew_shellenv) — the fix for "zsh: command not found: shll" in every
# new shell after a fresh-Homebrew bootstrap on Linux.
#
# Portable POSIX sh, no GNU-only tools, so it runs unchanged on macOS (BSD
# userland, /bin/sh = bash 3.2) and Linux (dash). Needs a real brew somewhere
# (on PATH or at a standard prefix) for the "new shell resolves brew" checks.
#
#   sh scripts/test-install-rc.sh              # functions under sh
#   TEST_SH=dash sh scripts/test-install-rc.sh # functions under another shell
set -eu

here=$(cd "$(dirname "$0")" && pwd)
test_sh=${TEST_SH:-sh}
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

# The functions without the trailing `main "$@"` — the same cut the
# hexokit.com deploy makes before appending its composition tail.
if [ "$(tail -n 1 "$here/install.sh")" != 'main "$@"' ]; then
    echo "FAIL: install.sh no longer ends in 'main \"\$@\"'; update this test's cut" >&2
    exit 1
fi
sed '$d' "$here/install.sh" >"$work/fns.sh"

brew_bin=$(command -v brew 2>/dev/null || true)
if [ -z "$brew_bin" ]; then
    for c in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
        if [ -x "$c" ]; then brew_bin=$c; break; fi
    done
fi
if [ -z "$brew_bin" ]; then
    echo "FAIL: no brew found (needed for the new-shell checks)" >&2
    exit 1
fi

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# persist <home> <login-shell> [zdotdir] — run persist_brew_shellenv under
# $test_sh with set -eu (as the installer does); stdout+stderr → $work/out.
persist() {
    HOME=$1 SHELL=$2 ZDOTDIR=${3:-} "$test_sh" -c \
        'set -eu; [ -n "$ZDOTDIR" ] || unset ZDOTDIR; . "$0"; persist_brew_shellenv "$1"; echo __continued__' \
        "$work/fns.sh" "$brew_bin" >"$work/out" 2>&1
}
count() { grep -c "$1" "$2" 2>/dev/null || true; }
newhome() { rm -rf "${work:?}/$1"; mkdir -p "$work/$1"; printf '%s\n' "$work/$1"; }
shll_block='# >>> shll >>>
eval "$(shll shell-init zsh)"
# <<< shll <<<'
line="eval \"\$($brew_bin shellenv)\""

# 1. Fresh zsh rc without a trailing newline: appended on its own line.
h=$(newhome t1); printf 'alias ll=ls' >"$h/.zshrc"
persist "$h" /bin/zsh
if [ "$(sed -n 1p "$h/.zshrc")" = 'alias ll=ls' ] && [ "$(tail -n 1 "$h/.zshrc")" = "$line" ]; then
    pass "zsh: appends the shellenv line (fixes a missing trailing newline)"
else fail "zsh: append"; cat "$h/.zshrc" >&2; fi

# 2. Re-run: shll block already present → line lands ABOVE it, mode kept.
h=$(newhome t2); printf 'export A=1\n%s\n' "$shll_block" >"$h/.zshrc"; chmod 600 "$h/.zshrc"
persist "$h" /bin/zsh
brew_ln=$(grep -n 'brew shellenv' "$h/.zshrc" | cut -d: -f1)
shll_ln=$(grep -n '^# >>> shll >>>' "$h/.zshrc" | cut -d: -f1)
mode=$(ls -l "$h/.zshrc" | cut -c1-10)
if [ -n "$brew_ln" ] && [ "$brew_ln" -lt "$shll_ln" ] && [ "$mode" = "-rw-------" ]; then
    pass "zsh: inserts above an existing shll block, keeps file mode"
else fail "zsh: insert above shll block (mode $mode)"; cat "$h/.zshrc" >&2; fi

# 3. Idempotent: a second run adds nothing.
persist "$h" /bin/zsh
if [ "$(count 'brew shellenv' "$h/.zshrc")" = 1 ]; then pass "idempotent re-run"
else fail "idempotent re-run"; fi

# 4. Legacy `# >>> shll shell-init >>>` block is also recognized.
h=$(newhome t4); printf '# >>> shll shell-init >>>\neval "$(shll shell-init zsh)"\n# <<< shll shell-init <<<\n' >"$h/.zshrc"
persist "$h" /bin/zsh
if [ "$(sed -n 2p "$h/.zshrc")" = "$line" ]; then pass "zsh: inserts above a legacy shll block"
else fail "zsh: legacy block"; cat "$h/.zshrc" >&2; fi

# 5. Missing rc file is created (shll setup shell refuses to create one).
h=$(newhome t5)
persist "$h" /bin/zsh
if [ "$(tail -n 1 "$h/.zshrc" 2>/dev/null)" = "$line" ]; then pass "zsh: creates a missing .zshrc"
else fail "zsh: missing rc"; fi

# 6. ZDOTDIR is honored, $HOME/.zshrc untouched.
h=$(newhome t6); mkdir -p "$h/z"; : >"$h/z/.zshrc"
persist "$h" /bin/zsh "$h/z"
if grep -q 'brew shellenv' "$h/z/.zshrc" && [ ! -e "$h/.zshrc" ]; then pass "zsh: honors ZDOTDIR"
else fail "zsh: ZDOTDIR"; fi

# 7. Symlinked rc (dotfile manager): link survives, target is edited.
h=$(newhome t7); mkdir -p "$h/dot"; printf '%s\n' "$shll_block" >"$h/dot/zshrc"; ln -s dot/zshrc "$h/.zshrc"
persist "$h" /bin/zsh
if [ -L "$h/.zshrc" ] && grep -q 'brew shellenv' "$h/dot/zshrc"; then pass "zsh: keeps a symlinked rc a symlink"
else fail "zsh: symlinked rc"; fi

# 8. bash → ~/.bash_profile on macOS, ~/.bashrc elsewhere (shll's resolveRcFile).
h=$(newhome t8)
if [ "$(uname -s)" = Darwin ]; then brc=.bash_profile; else brc=.bashrc; fi
printf 'x\n' >"$h/$brc"
persist "$h" /bin/bash
if grep -q 'brew shellenv' "$h/$brc"; then pass "bash: writes ~/$brc"
else fail "bash: ~/$brc"; fi

# 9. Unsupported shell: nothing written, the line is printed instead.
h=$(newhome t9)
persist "$h" /usr/bin/fish
if [ -z "$(ls -A "$h")" ] && grep -q 'add this line to your shell rc file' "$work/out"; then
    pass "other shell: prints the line, writes nothing"
else fail "other shell"; fi

# 10. Unwritable rc: never fatal under set -eu, prints the line, no raw shell noise.
for variant in plain block; do
    h=$(newhome "t10$variant")
    if [ "$variant" = block ]; then printf '%s\n' "$shll_block" >"$h/.zshrc"; else printf 'x\n' >"$h/.zshrc"; fi
    chmod 400 "$h/.zshrc"
    persist "$h" /bin/zsh
    if grep -q __continued__ "$work/out" && grep -q 'could not be updated' "$work/out" &&
        ! grep -qi 'permission denied' "$work/out"; then
        pass "unwritable rc ($variant): falls back to printing, installer continues"
    else fail "unwritable rc ($variant)"; cat "$work/out" >&2; fi
done

# 11. The real point: a brand-new interactive shell with a bare PATH (a fresh
# terminal) resolves brew — and so every brew-installed tool, shll included —
# after the rc file was written.
bare=/usr/bin:/bin
for sh_name in zsh bash; do
    sh_bin=$(command -v "$sh_name" 2>/dev/null || true)
    [ -n "$sh_bin" ] || { echo "skip - $sh_name not installed"; continue; }
    h=$(newhome "t11$sh_name")
    if [ "$sh_name" = zsh ]; then rcf=.zshrc; else rcf=$brc; fi
    : >"$h/$rcf"
    persist "$h" "$sh_bin"
    # bash only reads ~/.bash_profile for login shells (macOS terminals).
    if [ "$rcf" = .bash_profile ]; then flags=-il; else flags=-i; fi
    got=$(cd "$h" && env -i HOME="$h" TERM=dumb PATH="$bare" "$sh_bin" $flags -c 'command -v brew' 2>/dev/null </dev/null | tail -n 1)
    if [ "$got" = "$brew_bin" ]; then pass "new $sh_name terminal resolves brew"
    else fail "new $sh_name terminal resolves brew (got '$got')"; fi
done

echo
if [ "$fails" -ne 0 ]; then
    echo "$fails failure(s)" >&2
    exit 1
fi
echo "all passed"
