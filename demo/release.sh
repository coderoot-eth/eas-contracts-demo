#!/usr/bin/env bash
# Release steps for this demo copy, one step per call, so each key is in scope only for its own step.
#   deploy   DEPLOYER_KEY: deploys SchemaRegistry, then EAS pointing at it
#   attest   ATTESTER_KEY, COMMIT: attests both runtime code hashes, read from the chain, through the
#            CodeRoot index on the chain's EAS predeploy, in one transaction
#   confirm  read-only: both code hashes are live in the index for the attester
#   record   COMMIT: writes release.json with the UIDs from the mined receipt
# Always: RPC_URL, OUT (a directory). attest and confirm also take CODEROOT_ATTESTER.
# The demo copy's own contracts are never used for CodeRoot's records: those go to the predeploy.
set -euo pipefail

: "${RPC_URL:?RPC_URL is required}"
: "${OUT:?OUT is required}"
mkdir -p "$OUT"

CHAIN_ID=84532
PREDEPLOY_EAS=0x4200000000000000000000000000000000000021
INDEX=${CODEROOT_INDEX:-0x71CA0854D49e15E3bd18fA9022Ed701b59A72377}
ATTESTED_TOPIC=0x8bf46bf4cfd674fa735a3d63ec1c9ad4153f033c290341f3a588b75685141b35

die() { echo "error: $*" >&2; exit 1; }
chain=$(cast chain-id --rpc-url "$RPC_URL")
[ "$chain" = "$CHAIN_ID" ] || [ "${ALLOW_LOCAL_FORK:-}" = 1 ] || die "RPC answers chain $chain, not $CHAIN_ID"
lc() { tr 'A-F' 'a-f'; }
field() { jq -r "$1" "$OUT/deployment.json"; }
codehash() { local h; h=$(cast codehash "$1" --rpc-url "$RPC_URL"); [ "$h" != 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 ] || die "$1 has no code"; echo "$h"; }

case "${1:-}" in
  deploy)
    : "${DEPLOYER_KEY:?DEPLOYER_KEY is required}"
    deployer=$(cast wallet address --private-key "$DEPLOYER_KEY")
    reg=$(forge create contracts/SchemaRegistry.sol:SchemaRegistry --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" --broadcast --json)
    reg_addr=$(jq -r .deployedTo <<<"$reg")
    eas=$(forge create contracts/EAS.sol:EAS --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" --broadcast --json --constructor-args "$reg_addr")
    eas_addr=$(jq -r .deployedTo <<<"$eas")
    [ "$(cast call "$eas_addr" 'getSchemaRegistry()(address)' --rpc-url "$RPC_URL" | lc)" = "$(echo "$reg_addr" | lc)" ] || die "EAS does not point at the registry"
    jq -n --argjson chainId "$chain" --arg deployer "$deployer" \
      --arg ra "$reg_addr" --arg rh "$(codehash "$reg_addr")" --arg rt "$(jq -r .transactionHash <<<"$reg")" \
      --arg ea "$eas_addr" --arg eh "$(codehash "$eas_addr")" --arg et "$(jq -r .transactionHash <<<"$eas")" \
      '{chainId:$chainId, deployer:$deployer, contracts:[
         {role:"SchemaRegistry", address:$ra, codeHash:$rh, deployTx:$rt},
         {role:"EAS", address:$ea, codeHash:$eh, deployTx:$et}]}' > "$OUT/deployment.json"
    echo "deployed SchemaRegistry $reg_addr, EAS $eas_addr"
    ;;

  attest)
    : "${ATTESTER_KEY:?ATTESTER_KEY is required}"
    : "${COMMIT:?COMMIT is required}"
    : "${CODEROOT_ATTESTER:?CODEROOT_ATTESTER is required}"
    [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be 40 lowercase hex"
    signer=$(cast wallet address --private-key "$ATTESTER_KEY")
    [ "$(echo "$signer" | lc)" = "$(echo "$CODEROOT_ATTESTER" | lc)" ] || die "the attest key is not CODEROOT_ATTESTER"
    schema=$(cast call "$INDEX" 'SCHEMA()(bytes32)' --rpc-url "$RPC_URL")
    reqs=()
    for i in 0 1; do
      addr=$(field ".contracts[$i].address"); want=$(field ".contracts[$i].codeHash")
      [ "$(codehash "$addr")" = "$want" ] || die "$addr code hash differs from deployment.json"
      data=$(cast abi-encode 'f(bytes32,uint256,string,uint64)' "$want" "$chain" "$COMMIT" 0)
      reqs+=("($addr,0,true,0x0000000000000000000000000000000000000000000000000000000000000000,$data,0)")
    done
    arg="[($schema,[$(IFS=,; echo "${reqs[*]}")])]"
    cast send "$PREDEPLOY_EAS" 'multiAttest((bytes32,(address,uint64,bool,bytes32,bytes,uint256)[])[])' "$arg" \
      --rpc-url "$RPC_URL" --private-key "$ATTESTER_KEY" --json | jq '.data // .' > "$OUT/attest-receipt.json"
    [ "$(jq -r .status "$OUT/attest-receipt.json")" = 0x1 ] || die "attest transaction failed: $(jq -c . "$OUT/attest-receipt.json")"
    echo "attested in $(jq -r .transactionHash "$OUT/attest-receipt.json")"
    ;;

  confirm)
    : "${CODEROOT_ATTESTER:?CODEROOT_ATTESTER is required}"
    for i in 0 1; do
      addr=$(field ".contracts[$i].address"); want=$(field ".contracts[$i].codeHash")
      [ "$(codehash "$addr")" = "$want" ] || die "$addr code hash changed"
      live=$(cast call "$INDEX" 'claimsOf(address,address,bytes32)(bool,uint64)' "$CODEROOT_ATTESTER" "$addr" "$want" --rpc-url "$RPC_URL" | head -1)
      [ "$live" = true ] || die "$(field ".contracts[$i].role") is not live in the index"
    done
    echo "both code hashes live in the index"
    ;;

  record)
    : "${COMMIT:?COMMIT is required}"
    r="$OUT/attest-receipt.json"
    uids=$(jq -c --arg t "$ATTESTED_TOPIC" '[.logs[] | select(.topics[0]==$t) | {recipient:("0x"+(.topics[1][26:])), uid:.data[0:66]}]' "$r")
    jq --argjson uids "$uids" --arg commit "$COMMIT" --arg tx "$(jq -r .transactionHash "$r")" \
       --argjson block "$(printf '%d' "$(jq -r .blockNumber "$r")")" \
       --arg index "$INDEX" --arg eas "$PREDEPLOY_EAS" --arg attester "${CODEROOT_ATTESTER:-}" \
       --arg easSchema "$(cast call "$INDEX" 'SCHEMA()(bytes32)' --rpc-url "$RPC_URL")" \
      '. + {schema:"coderoot.contract-release/v1", commit:$commit, index:$index, eas:$eas, easSchema:$easSchema, attester:$attester}
       | .contracts |= map(. as $c | . + {attestTx:$tx, attestBlock:$block,
           uid:(($uids[] | select((.recipient|ascii_downcase) == ($c.address|ascii_downcase)) | .uid) // error("no record for \($c.role)"))})' \
      "$OUT/deployment.json" > "$OUT/release.json"
    echo "wrote $OUT/release.json"
    ;;

  *) die "usage: release.sh deploy|attest|confirm|record" ;;
esac
