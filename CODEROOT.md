# Releasing, checking and revoking through CodeRoot

Our demo copy of EAS's contracts is released through CodeRoot. CI deploys `SchemaRegistry` and
`EAS` to Base Sepolia and attests each contract's runtime code hash on the EAS predeploy, through
the CodeRoot index. A consumer reads a contract's code from the chain and checks its hash is live in
the index before it calls it. A revoke makes the next check refuse that address.

This demo attests from a CI attester key. In the product, CI deploys and submits, a person approves
in the CodeRoot queue, and only CodeRoot attests.

## Adopting it

The release is two added files: [`demo/release.sh`](demo/release.sh) and
[`.github/workflows/release.yml`](.github/workflows/release.yml). Upstream's contracts and build are
unchanged. The workflow runs by hand or on a tag `v*`, in the `base-sepolia` environment:

| step | key in scope | does |
|---|---|---|
| deploy | `DEPLOYER_KEY` | builds upstream's sources with Foundry and deploys `SchemaRegistry`, then `EAS` pointing at it |
| attest | `ATTESTER_KEY` | one `multiAttest` on the EAS predeploy: each runtime code hash, read from the chain, with the chain id and commit, the contract as recipient, indexed by the CodeRoot index |
| confirm | none | reads each code hash back from the index as live for the attester |
| record | none | writes `release.json`: addresses, code hashes, EAS record UIDs |

A second job, holding no key, builds the CodeRoot submission from `release.json`.

To adopt it in another repository: copy both files, create the environment with a deployer and an
attester key, and set `CODEROOT_ATTESTER` to the attester's address.

## Checking it

[`demo/consumer.sh`](demo/consumer.sh), run by [`.github/workflows/consumer.yml`](.github/workflows/consumer.yml)
with a release run's ID, holds no key. For each contract in that run's `release.json` it:

1. reads the contract's code from the chain and hashes it
2. requires that hash to equal the release's
3. asks the CodeRoot index whether that hash is live for the attester

| verdict | meaning | exit |
|---|---|--:|
| `verified` | the code at the address is the released code, and its record is live | 0 |
| `revoked` | the record was revoked | 1 |
| `unregistered` | no live record, or the code differs from the release | 2 |

A chain that cannot be read stops the check with exit 3 and never counts as a verdict. The demo
consumer takes the attester from the release record. A real consumer pins the attester it trusts,
as CodeRoot verify does.

## Revoking it

[`.github/workflows/revoke.yml`](.github/workflows/revoke.yml) revokes one release run's records from
the attester key in one `multiRevoke`. The index clears each code hash, and the next consumer check
reads `revoked` and refuses those addresses.

## Gas

Measured on Base Sepolia for release run
[45181338767](https://github.com/coderoot-eth/eas-contracts-demo/actions/runs/45181338767):

| transaction | gas | fee on Base Sepolia |
|---|--:|--:|
| [deploy `SchemaRegistry`](https://sepolia.basescan.org/tx/0xd5209dba626cd388de530b3b03f1dc5d3d3ac58965b42044e25fccff7c62e38a) | 622,291 | 0.0000037 ETH |
| [deploy `EAS`](https://sepolia.basescan.org/tx/0x32a091ec016e85d2568633a1a5dc09ee099945efdcfa9703556fab3ff85e5ca5) | 4,078,182 | 0.0000245 ETH |
| [attest both code hashes](https://sepolia.basescan.org/tx/0xb3b9a6ec1fca085cdd84ea768ae19b61ec4ce3bb4c91394beedd14cba0109a14) (one `multiAttest`, two records) | 683,791 | 0.0000041 ETH |
| [revoke both](https://sepolia.basescan.org/tx/0xc972f53708c135a68d0291450eb8de4fc2edacacc56eba9c617612bd80ae6b02) (one `multiRevoke`) | 144,772 | 0.0000009 ETH |

The attest is about 342,000 gas per record. A consumer's check only reads, so it costs nothing.
Fees on Base mainnet depend on its gas price at the time.
