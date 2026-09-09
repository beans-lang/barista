#!/usr/bin/env bash
# barista's gate. Every suite runs on BOTH backends and must print the golden
# file byte for byte; the native leg is diffed against the golden, never
# against the interpreter's fresh output.
#
#   ./test.sh            both legs, every suite
#   ./test.sh --interp   the interpreter only, for the edit loop
#   ./test.sh <name>     one suite, both legs
#   ./test.sh --wasm     the no-OS leg on its own
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

# A compiler built from a Beans checkout resolves the standard library and
# runtime relative to that checkout, so those runs happen from its root.
if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../../beans" && pwd)
fi
if [[ -z ${BEANSC:-} ]]; then
    if [[ -n ${BEANS_ROOT:-} && -x "$BEANS_ROOT/build/beansc" ]]; then
        BEANSC="$BEANS_ROOT/build/beansc"
    else
        BEANSC=$(command -v beansc || true)
    fi
fi
if [[ -z "$BEANSC" || ! -x "$BEANSC" ]]; then
    echo "beansc not found: set BEANSC, set BEANS_ROOT, or put beansc on PATH" >&2
    exit 1
fi
if [[ -n ${BEANS_ROOT:-} ]]; then
    [[ -z ${BEANS_RUNTIME:-}  && -f "$BEANS_ROOT/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$BEANS_ROOT/runtime/beans_rt.c"
    [[ -z ${BEANS_STDLIB:-}   && -d "$BEANS_ROOT/stdlib/std"        ]] && export BEANS_STDLIB="$BEANS_ROOT/stdlib/std"
    [[ -z ${BEANS_ENCODING:-} && -d "$BEANS_ROOT/runtime/encoding"  ]] && export BEANS_ENCODING="$BEANS_ROOT/runtime/encoding"
    [[ -z ${BEANS_NET:-}      && -d "$BEANS_ROOT/runtime/net"       ]] && export BEANS_NET="$BEANS_ROOT/runtime/net"
    [[ -z ${BEANS_LOG:-}      && -d "$BEANS_ROOT/runtime/log"       ]] && export BEANS_LOG="$BEANS_ROOT/runtime/log"
fi

# Which beansc produced this result. `--version` cannot tell you: two builds
# that differ by a real bug fix answer the same string.
compiler_line() {
    local id
    id=$(shasum -a 256 "$BEANSC" 2>/dev/null | cut -c1-12)
    [[ -n "$id" ]] || id="unhashable"
    printf '%s (%s)' "$BEANSC" "$id"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/barista-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

native=1
only=""
wasm_only=0
case "${1:-}" in
    --interp) native=0 ;;
    --wasm)   wasm_only=1 ;;
    "")       ;;
    *)        only="$1" ;;
esac

failed=0
skipped=0
suites=0
legs=0

# ---------------------------------------------------------------- the wasm leg
#
# barista must need no operating system. latte's core depends on it and is
# built for wasm32-unknown-unknown to hold exactly that line; without this leg
# a container that grew `import std.fs` would break latte's gate, in latte's
# repo, for a cause that lives here.
run_wasm_leg() {
    local probe="$ROOT/tests/_wasm_core.b"
    local negative="$ROOT/tests/_wasm_negative.b"
    if [[ ! -f "$probe" || ! -f "$negative" ]]; then
        echo "--- wasm FAILED: tests/_wasm_core.b or tests/_wasm_negative.b is missing ---" >&2
        echo "    this leg cannot be skipped into silence; write them back." >&2
        failed=1
        return 0
    fi

    if (cd "$ROOT" && "$BEANSC" check --target wasm32-unknown-unknown \
            --runtime freestanding "$probe") >"$tmp/wasm.log" 2>&1; then
        echo "ok wasm/check — barista needs no OS capability"
    else
        echo "--- wasm FAILED: barista no longer checks without an OS ---" >&2
        echo "    something in this package grew an OS-bound import." >&2
        cat "$tmp/wasm.log" >&2
        failed=1
        return 0
    fi

    # The control. Without it the check above goes green the day the refusal
    # stops working, and then it is green for ever.
    if (cd "$ROOT" && "$BEANSC" check --target wasm32-unknown-unknown \
            --runtime freestanding "$negative") >"$tmp/wasm_neg.log" 2>&1; then
        echo "--- wasm FAILED: the negative control was ACCEPTED ---" >&2
        echo "    tests/_wasm_negative.b imports std.fs and std.net and must be refused." >&2
        echo "    The whole leg proves nothing while that is true." >&2
        failed=1
        return 0
    fi
    echo "ok wasm/control — std.fs and std.net are still refused for wasm"
}

if [[ $wasm_only -eq 1 ]]; then
    run_wasm_leg
    [[ $failed -eq 0 ]] || { echo "barista: FAILED" >&2; exit 1; }
    echo "ok barista — the wasm leg only"
    exit 0
fi

# ------------------------------------------------------------- the module root
#
# The package must CHECK even with no suites. A suite-only gate says nothing
# about a package nothing imports yet, which is the state a new package is in
# for its whole first day.
if (cd "$ROOT" && "$BEANSC" check tests/_wasm_core.b) >"$tmp/root.log" 2>&1; then
    echo "ok module-root — barista.b checks"
else
    echo "--- module-root FAILED ---" >&2
    cat "$tmp/root.log" >&2
    failed=1
fi

# ------------------------------------------------------------------ the suites
shopt -s nullglob
for case_file in "$ROOT"/tests/*.b; do
    name=$(basename "$case_file" .b)
    case "$name" in _*) continue ;; esac
    if [[ -n "$only" && "$name" != "$only" ]]; then continue; fi
    want="$ROOT/tests/$name.out"
    if [[ ! -f "$want" ]]; then
        echo "--- no golden file for $name ---" >&2
        failed=1
        continue
    fi
    suites=$((suites + 1))

    if ! (cd "$ROOT" && "$BEANSC" run "$case_file") >"$tmp/$name.interp" 2>"$tmp/$name.err"; then
        echo "--- $name failed to run under the interpreter ---" >&2
        cat "$tmp/$name.err" >&2
        failed=1
        continue
    fi
    if diff -u "$want" "$tmp/$name.interp"; then
        legs=$((legs + 1))
    else
        echo "--- $name: interpreter output differs from the golden ---" >&2
        failed=1
    fi

    [[ $native -eq 1 ]] || continue

    if ! (cd "$ROOT" && "$BEANSC" build "$case_file" -o "$tmp/$name.bin") >"$tmp/$name.build" 2>&1; then
        echo "--- $name failed to build natively ---" >&2
        cat "$tmp/$name.build" >&2
        failed=1
        continue
    fi
    if ! (cd "$ROOT" && "$tmp/$name.bin") >"$tmp/$name.native" 2>"$tmp/$name.nerr"; then
        echo "--- $name failed to run natively ---" >&2
        cat "$tmp/$name.nerr" >&2
        failed=1
        continue
    fi
    if diff -u "$want" "$tmp/$name.native"; then
        legs=$((legs + 1))
    else
        echo "--- $name: NATIVE output differs from the golden ---" >&2
        echo "    the two backends disagree; that is a compiler fault until" >&2
        echo "    proven otherwise." >&2
        failed=1
    fi
done

[[ -n "$only" ]] || run_wasm_leg

[[ $failed -eq 0 ]] || { echo "barista: FAILED" >&2; exit 1; }
if [[ $skipped -gt 0 ]]; then
    echo "ok barista — $suites suites, $legs legs, all byte-identical to the goldens — $skipped SKIPPED, read the SKIP lines above"
else
    echo "ok barista — $suites suites, $legs legs (interpreter + native), all byte-identical to the goldens"
fi
echo "   beansc: $(compiler_line)"
