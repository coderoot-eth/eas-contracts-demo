# Notice

This repository is our demo copy of EAS's contracts:
[ethereum-attestation-service/eas-contracts](https://github.com/ethereum-attestation-service/eas-contracts)
at commit `3683c3ec9383091eebd6f183e67b485e09a53dd7` (the commit of the published 1.9.0), used under
its MIT license. The first commit on `main` is that commit's tree, unchanged. `LICENSE` is upstream's,
unchanged.

It is an unofficial demo, released through CodeRoot to show contract release attestation. It is not
published, reviewed or endorsed by the Ethereum Attestation Service. The official contracts are
EAS's own deployments.

## Changes from upstream

Every upstream file is unchanged except `README.md`, which has a disclaimer added at the top.

Added files:

| file | what it does |
|---|---|
| `NOTICE.md` | this file |
| `demo/release.sh` | the release steps: deploy `SchemaRegistry` and `EAS`, attest both runtime code hashes through the CodeRoot index, confirm, record |
| `.github/workflows/release.yml` | runs those steps on Base Sepolia from CI and builds the CodeRoot submission |

## The demo deployment

- Base Sepolia only, deployed from this repository's CI with a throwaway key.
- Its addresses appear only in this repository and the demo. Only the schemas the demo needs are
  registered on it, and nobody else attests on it.
- Its source is not verified on Basescan or Sourcify. The attested code hash and this repository are
  the proof of what runs at each address.
- CodeRoot's own records are attestations on the EAS predeploy on Base Sepolia
  (`0x4200000000000000000000000000000000000021`), never on this copy.
