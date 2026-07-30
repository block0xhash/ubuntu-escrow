# Escrow contract

Solidity smart contract for Ubuntu Escrow, built with [Foundry](https://book.getfoundry.sh/). See the [root README](../README.md) for the full project and [TECHNICAL_DESIGN.md](../TECHNICAL_DESIGN.md) for architecture and contract function reference.

- **Deployed at:** [`0xabBDDF83285daa096381E5E4b312afCACA36686a`](https://sepolia-explorer.giwa.io/address/0xabBDDF83285daa096381E5E4b312afCACA36686a) on GIWA Sepolia (chain `91342`), verified

## Build & test

```shell
$ forge build
$ forge test
```

## Deploy

Requires `TEST_PRIVATE_KEY` and `TREASURY_ADDRESS` set in `.env` (see `.env` — never committed).

```shell
$ forge script script/DeployEscrow.s.sol:DeployEscrow \
    --rpc-url https://sepolia-rpc.giwa.io \
    --chain-id 91342 \
    --broadcast \
    --legacy
```

## Verify

```shell
$ forge verify-contract \
    --chain 91342 \
    --verifier blockscout \
    --verifier-url https://sepolia-explorer.giwa.io/api/ \
    --constructor-args $(cast abi-encode "constructor(address)" <treasury address>) \
    <deployed address> \
    src/Escrow.sol:Escrow
```

## Other useful commands

```shell
$ forge fmt                # format
$ forge snapshot           # gas snapshots
$ anvil                    # local node
$ cast <subcommand>        # chain/contract interaction
```
