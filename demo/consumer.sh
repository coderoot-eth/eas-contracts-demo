#!/usr/bin/env bash
# A consumer's check before it calls a contract from a release: each contract's code hash, read from
# the chain now, must be live in the CodeRoot index for the release's attester. Holds no key.
#   consumer.sh <release.json>
# Verdicts as CodeRoot verify: verified (exit 0), revoked (exit 1), unregistered or a code hash that
# differs from the release (exit 2). RPC_URL is required; the report goes to $OUT/consumer.json.
set -euo pipefail

: "${RPC_URL:?RPC_URL is required}"
: "${OUT:?OUT is required}"
rel=${1:?usage: consumer.sh <release.json>}
mkdir -p "$OUT"

die() { echo "error: $*" >&2; exit 3; }
# Every chain read fails with exit 3: an unreadable chain must never read as a verdict.
rpc() { cast "$@" --rpc-url "$RPC_URL" 2>/dev/null || die "could not read the chain: cast $1"; }
[ "$(rpc chain-id)" = "$(jq -r .chainId "$rel")" ] || [ "${ALLOW_LOCAL_FORK:-}" = 1 ] || die "RPC is not chain $(jq -r .chainId "$rel")"
index=$(jq -r .index "$rel"); eas=$(jq -r .eas "$rel"); attester=$(jq -r .attester "$rel")
[ -n "$attester" ] && [ "$attester" != null ] || die "the release names no attester"

results='[]'; worst=0
n=$(jq '.contracts | length' "$rel")
for ((i = 0; i < n; i++)); do
  role=$(jq -r ".contracts[$i].role" "$rel"); addr=$(jq -r ".contracts[$i].address" "$rel")
  want=$(jq -r ".contracts[$i].codeHash" "$rel"); uid=$(jq -r ".contracts[$i].uid" "$rel")
  bytecode=$(rpc code "$addr")
  # No code is never a verdict: the address is wrong or the read failed.
  [ "$bytecode" != 0x ] || die "$addr has no code"
  now=$(cast keccak "$bytecode")
  live=$(rpc call "$index" 'attested(address,address,bytes32)(bool)' "$attester" "$addr" "$now")
  if [ "$now" != "$want" ]; then
    verdict=unregistered; reason="code hash $now differs from the release's $want"; code=2
  elif [ "$live" = true ]; then
    verdict=verified; reason="live in the index for $attester"; code=0
  else
    revoked_at=$(rpc call "$eas" 'getAttestation(bytes32)((bytes32,bytes32,uint64,uint64,uint64,bytes32,address,address,bool,bytes))' "$uid" \
      | tr -d '()' | cut -d, -f5 | awk '{print $1}')
    if [ "${revoked_at:-0}" != 0 ]; then verdict=revoked; reason="attestation $uid revoked at $revoked_at"; code=1
    else verdict=unregistered; reason="not live in the index for $attester"; code=2; fi
  fi
  printf '%-15s %s  %s  (%s)\n' "$role" "$addr" "$verdict" "$reason"
  results=$(jq --arg role "$role" --arg addr "$addr" --arg hash "$now" --arg uid "$uid" --arg v "$verdict" --arg r "$reason" \
    '. + [{role:$role, address:$addr, codeHash:$hash, uid:$uid, verdict:$v, reason:$r}]' <<<"$results")
  # Revoked outranks the rest: exit 1 if any contract is revoked, else 2 if any is not verified.
  if [ "$code" = 1 ] || { [ "$code" = 2 ] && [ "$worst" = 0 ]; }; then worst=$code; fi
done

jq -n --argjson contracts "$results" --argjson exitCode "$worst" --arg attester "$attester" --arg index "$index" \
  '{schema:"coderoot.contract-consumer-check/v1", attester:$attester, index:$index, contracts:$contracts, exitCode:$exitCode}' > "$OUT/consumer.json"
case "$worst" in 0) echo "verified: safe to call" ;; 1) echo "refused: revoked" ;; *) echo "refused: not verified" ;; esac
exit "$worst"
