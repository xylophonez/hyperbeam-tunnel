#!/usr/bin/env bash
#
# Launch the tunnel broker against a HyperBEAM runtime.
#
# The broker is a HyperBEAM node, so it needs the HyperBEAM BEAM runtime on its
# code path. Two ways to provide it, in order of preference:
#
#   1. HB_RUNTIME points at an extracted runtime directory that contains
#      erlang/<abi>/... and lib/hb/ebin (e.g. the runtime unpacked from an
#      AndEE APK's assets/andee-runtime.zip, or any HyperBEAM release).
#   2. Otherwise we fall back to a locally built rebar3 profile in ./_build,
#      built from this repo's rebar.config (see README "Build from source").
#
# Usage:
#   ./run.sh                      # uses config/broker.json
#   BROKER_CONFIG=my.json ./run.sh
#   HB_RUNTIME=/path/to/runtime ./run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

CONFIG="${BROKER_CONFIG:-config/broker.json}"
ABI="${HB_ABI:-x86_64}"

find_erl() {
    if [ -n "${HB_RUNTIME:-}" ]; then
        local cand="$HB_RUNTIME/erlang/$ABI/erts-"*/bin/erl
        for e in $cand; do [ -x "$e" ] && { echo "$e"; return 0; }; done
        cand="$HB_RUNTIME/erlang/$ABI/bin/erl"
        [ -x "$cand" ] && { echo "$cand"; return 0; }
    fi
    command -v erl 2>/dev/null && return 0
    return 1
}

collect_paths() {
    local paths=()
    if [ -n "${HB_RUNTIME:-}" ]; then
        for d in "$HB_RUNTIME/erlang/$ABI/lib/"*/ebin; do
            [ -d "$d" ] && paths+=("-pa" "$d")
        done
    fi
    if [ -d "$HERE/_build/default/lib" ]; then
        for d in "$HERE/_build/default/lib/"*/ebin; do
            [ -d "$d" ] && paths+=("-pa" "$d")
        done
    fi
    # Broker's own compiled modules (dev_tunnel, dev_tunnel_server, tunnel_broker)
    paths+=("-pa" "$HERE/ebin")
    printf '%s\n' "${paths[@]}"
}

ERL="$(find_erl || true)"
if [ -z "$ERL" ]; then
    echo "error: no erl found. Set HB_RUNTIME to a HyperBEAM runtime dir," >&2
    echo "       or build from source (see README) so ./_build exists." >&2
    exit 1
fi

# Compile the broker's own sources against the runtime's hb includes.
mkdir -p "$HERE/ebin"
ERLC="$(dirname "$ERL")/erlc"
HB_EBIN=""
if [ -n "${HB_RUNTIME:-}" ]; then
    HB_EBIN="$HB_RUNTIME/erlang/$ABI/lib/hb/ebin"
fi
INCLUDES=()
[ -n "$HB_EBIN" ] && INCLUDES+=("-I" "$(dirname "$HB_EBIN")/include")
for f in "$HERE"/src/*.erl; do
    "$ERLC" "${INCLUDES[@]}" $(printf '%s\n' $(collect_paths)) -o "$HERE/ebin" "$f" \
        2>/dev/null || "$ERLC" $(printf '%s ' $(collect_paths)) -o "$HERE/ebin" "$f"
done

mapfile -t PA < <(collect_paths)

export BROKER_CONFIG="$CONFIG"
exec "$ERL" -noshell -name "tunnel-broker@127.0.0.1" \
    "${PA[@]}" \
    -run tunnel_broker main "$CONFIG"
