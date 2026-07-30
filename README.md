# Ubuntu Escrow

**A non-custodial peer-to-peer escrow marketplace on GIWA L2.**

Funds are locked in an audited smart contract and only released when both parties confirm a deal went through — no company holds the money, no seed-phrase expertise required to trust it. Built by the **Ubuntu Pay** team for the GASOK Open MVP Build Phase.

- 🌐 **Live demo:** https://ubuntupay.africa
- ✅ **Verified contract:** [`0xabBDDF83285daa096381E5E4b312afCACA36686a`](https://sepolia-explorer.giwa.io/address/0xabBDDF83285daa096381E5E4b312afCACA36686a) on GIWA Sepolia (chain `91342`)
- 📄 **Technical design one-pager:** [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md)
- 🎤 **Pitch deck:** [docs/Ubuntu-Pay-Pitch-Deck.pptx](docs/Ubuntu-Pay-Pitch-Deck.pptx)

## What it does

Two people agree on a deal. The buyer's funds go into [`Escrow.sol`](contracts/src/Escrow.sol) — not a bank account, not our database, not our servers. The seller marks it shipped, the buyer confirms receipt, and the contract releases the funds automatically: 99% to the seller, 1% platform fee to the treasury. If the buyer goes silent, anyone can trigger the same release after a 7-day timeout, so funds never get stuck.

Deals can be listed **public** (any buyer may fund it) or **private** (restricted on-chain to one specific buyer's wallet) — the same contract, no separate code path.

```
Created ──deposit()──▶ Funded ──markShipped()──▶ Shipped ──confirmReceipt()──▶ Released
```

## Repo structure

```
contracts/    Solidity contract (Foundry) — Escrow.sol, tests, deploy script
frontend/     Blazor Server web app (.NET) — the marketplace UI
docs/         Pitch deck and design references
```

## Running it locally

### Smart contract

```bash
cd contracts
forge build
forge test
```

7 tests cover the full deal lifecycle, the fee split, the timeout auto-release, dispute refunds, and both private-deal enforcement cases.

### Frontend

```bash
cd frontend/EscrowApp.Web
dotnet run
```

Requires the .NET 10 SDK. The app talks to the deployed contract on GIWA Sepolia — connect MetaMask and approve the network switch when prompted.

## Stack

Solidity 0.8 + OpenZeppelin (`ReentrancyGuard`, `Ownable`) + Foundry, on the contract side. Blazor Server (.NET 10) + MudBlazor + Nethereum + SQLite on the app side, talking to GIWA Sepolia L2 through MetaMask.

See [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md) for the full architecture, contract function reference, security notes, and roadmap.
