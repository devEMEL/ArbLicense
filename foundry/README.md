# ArbLicense

A Uniswap v4 hook that turns MEV that would normally leak to searchers into
LP yield. Instead of trying to detect and confiscate arbitrage after the
fact, it **auctions the right to arb each pool for a fixed time window
(an epoch)**, and taxes anyone who arbs without holding that epoch's license.

No price oracle. Arb-shaped activity is detected the same way Uniswap Labs'
own MEV-tax hook does it: via **priority fee** as a proxy, not price-pattern
analysis.

## The idea in one sentence

Every epoch, one address buys the right to arb a pool cheaply; everyone else
who tries anyway pays a steep tax; both the auction proceeds and the tax
flow straight to LPs.

## How it works

1. **Auction (before the epoch starts).** Searchers bid ETH for the license
   to epoch *N* on a given pool. Bidding is open while
   `block.number < startBlock(N) - BIDDING_BUFFER_BLOCKS`, and closes
   exactly at that boundary block — the same block settlement becomes
   available, so there's no gap where neither bidding nor settling is
   possible.
2. **Settlement.** The winning bid is minted as an **ERC-1155 license token**
   (`id = pack(poolId, epoch)`) to the winner, and the bid amount is
   `donate()`'d straight into the pool as LP fees.
3. **Epoch begins.** Normal trading happens as usual — this system only
   touches swaps that look arb-shaped.
4. **An arb-shaped swap comes in.** The hook checks the swap's priority fee.
   Above a threshold, it's treated as arb-shaped and the tax logic engages:
   - **Holds the current epoch's license** (proven via a signed EIP-712
     permit passed in `hookData`, not `msg.sender`/`tx.origin` — so it
     survives routing through aggregators or smart-contract wallets) →
     charged a flat **1%** LP fee (`licensedTaxBps`), regardless of how much
     priority fee they paid. The auction bid already paid for this discount,
     so their per-swap cost stays predictable.
   - **Doesn't hold it** → charged a tax that **scales with priority fee**:
     starts at a floor of **5%** (`minUnlicensedTaxBps`) the moment a swap
     crosses the arb-shaped threshold, climbs **+2% per extra gwei** of
     priority fee paid (`taxBpsPerExtraGwei`), capped at **30%**
     (`maxUnlicensedTaxBps`). Applied via v4's dynamic-fee override on
     `beforeSwap`. The scaling means a barely-arb-shaped swap pays close to
     the floor, while an aggressively-tipping bot pays close to the cap —
     not a single flat rate regardless of urgency.
5. **Everything lands as LP fees.** Because the tax is applied as a
   dynamic-fee override on the swap itself, it flows through v4's normal
   fee-accrual mechanics — no separate distribution step needed. Auction
   proceeds are donated the same way.
6. **Next epoch, repeat.**

## Why priority fee instead of an oracle

An oracle-based "is this swap correcting the price toward fair value"
detector is circular for this design — the auction winner (or anyone else)
can influence the pool's own price, which would be the very reference used
to judge them. Priority fee sidesteps that: bots that spot an arb tend to
pay for fast inclusion regardless of which direction they're trading, so it
doesn't depend on knowing "true" price at all. It's simpler, has no oracle
attack surface, and matches the precedent set by Uniswap Labs' MEV-tax hook.

**Trade-off to be aware of:** priority fee is a proxy, not a certainty. A
whale doing a large organic trade with high urgency could get taxed like an
arbitrageur. Tune `arbPriorityFeeThreshold` with this in mind.

## Contracts

```
src/
  ArbLicenseHook.sol       Uniswap v4 hook — priority-fee check, license
                            verification, tax via dynamic-fee override
  LicenseNFT.sol            ERC-1155 license tokens, mint-gated to EpochAuction
  EpochAuction.sol          Bidding, settlement, mints license, donates
                            winning bid to LPs
  DemoSwapRouter.sol        Minimal router for testing/demoing swaps against
                            the pool (passes hookData through for permits)
  libraries/
    LicenseId.sol            Packs (poolId, epoch) -> ERC-1155 token id
    LicensePermit.sol         EIP-712 signature verification for hookData permits
    Epoch.sol                  Block-based epoch math shared by hook + auction
```

| Contract | Role |
|---|---|
| `ArbLicenseHook` | Runs on every swap. Decides tax rate. |
| `LicenseNFT` | Source of truth for "who's licensed this epoch." |
| `EpochAuction` | Sells the license, funds LPs from the proceeds. |
| `DemoSwapRouter` | Lets you actually call `swap()` for testing. |

## Setup

```bash
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std
```

`remappings.txt`:
```
v4-core/=lib/v4-core/
v4-periphery/=lib/v4-periphery/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
forge-std/=lib/forge-std/src/
solmate/=lib/v4-core/lib/solmate/
```
> `solmate` is only needed for the tests (`MockERC20`) and typically already
> sits inside v4-core's own `lib/` as a transitive dependency — adjust the
> path if your pinned v4-core vendors it elsewhere, or add
> `forge install transmissions11/solmate` directly if it's missing.

## Running tests

```bash
forge test -vvv
```

Test layout:
```
test/
  ArbLicenseHook.t.sol      Full pool integration: threshold gating, scaling
                             unlicensed tax, flat licensed tax, permit edge cases
  EpochAuction.t.sol         Bidding, outbidding, refunds, settlement, LP donation
  LicenseNFT.t.sol           Mint gating, transferability
  libraries/
    Epoch.t.sol               Block-math correctness
    LicenseId.t.sol            Packing/collision checks
    LicensePermit.t.sol        EIP-712 signature verification, expiry, wrong signer
```

`ArbLicenseHook.t.sol` and `EpochAuction.t.sol` spin up a real `PoolManager`
and pool via v4-core's `Deployers` test base and mine the hook's deploy
address via `HookMiner` — these are the most version-sensitive files in the
suite (see the version-sensitivity note at the top of each file).

> **Version sensitivity:** v4's hook and callback APIs changed several times
> during development. Before deploying, verify against your pinned commit:
> - `Hooks.Permissions` struct fields in `ArbLicenseHook.getHookPermissions()`
> - The dynamic-fee override flag (`0x400000`) used in `_beforeSwap`
> - The `donate`/`settle`/`sync` call sequence in `EpochAuction.unlockCallback`
>   and `DemoSwapRouter._settle`
> - `BaseHook`'s import path and constructor in `v4-periphery`

## Deploy & wire up

1. Deploy `LicenseNFT`.
2. Deploy `EpochAuction(poolManager, licenseNFT)`.
3. `LicenseNFT.setAuction(address(epochAuction))`.
4. Deploy `ArbLicenseHook(poolManager, licenseNFT)` — must be mined to an
   address encoding the correct hook-permission flags (v4's standard
   `HookMiner` / `CREATE2` flow).
5. Initialize your pool with `ArbLicenseHook` set in `PoolKey.hooks`.
   **Must use `LPFeeLibrary.DYNAMIC_FEE_FLAG` as the pool's fee, not a static
   fee value.** Without it, `PoolManager` silently ignores the override fee
   the hook returns from `beforeSwap` — swaps will emit the correct
   `TaxApplied` event but pay whatever static fee you set instead of the
   actual tax. This bit us in testing; see `ArbLicenseHook.t.sol`'s
   `initPool(...)` call for the fix.
6. Deploy `DemoSwapRouter(poolManager)` for testing.

## Demoing the tax difference

Priority fee only varies meaningfully with real mempool dynamics, so in a
local/Foundry demo you'll want to simulate it directly:

```solidity
vm.fee(1 gwei);          // sets block.basefee
vm.txGasPrice(5 gwei);   // sets tx.gasprice -> priority fee = 4 gwei
```

Then:
- **Unlicensed swap:** call `DemoSwapRouter.swap(key, params, "")` with empty
  `hookData` → charged the scaled rate from `_scaledUnlicensedTaxBps`
  (floor `minUnlicensedTaxBps`, capped at `maxUnlicensedTaxBps`).
- **Licensed swap:** build a `LicensePermit.Permit`, sign it off-chain (or
  with `vm.sign` in a test), ABI-encode `(licensee, nonce, deadline,
  signature)` as `hookData`, then call `swap()` with it → charged the flat
  `licensedTaxBps`.

To show the *scaling* behavior specifically (not just licensed-vs-unlicensed),
run several unlicensed swaps with increasing `vm.txGasPrice(...)` values and
compare the `taxBps` value emitted in each `TaxApplied` event — it should
step up by `taxBpsPerExtraGwei` per extra gwei until it hits the cap.

Compare the resulting `BalanceDelta` and the pool's accrued LP fees across
swaps to show the tax spread live.

## Known limitations (by design, worth stating out loud)

- **License doesn't guarantee execution priority.** A rival can see the
  licensee's public-mempool tx, copy it, and outbid them on priority fee to
  land first. They still get taxed, but the licensee gets nothing that
  round. Mitigate by having the licensee submit via a private relay
  (Flashbots Protect / MEV-Blocker) rather than the public mempool — this is
  an operational recommendation, not something the contracts enforce.
- **`donate()` is atomic, not retroactive.** LPs are credited based on who's
  in-range *at the moment* a tax/auction donation happens, not a
  time-weighted history of who provided liquidity earlier in the epoch.
- **Priority fee is a proxy for "arb-shaped," not a certainty.** High-urgency
  organic trades can get taxed like arbitrage. Tune the threshold accordingly.
- **Tax is expressed as a % of the swap's input token, not an absolute ETH
  amount.** The more direct approach (see Angstrom L2's arbitrage auction)
  taxes `gasUsed × multiplier × priorityFee` as an absolute amount of the
  gas-token currency, since priority fee is itself ETH-denominated. This repo
  uses a tuned bps-per-gwei scale instead, which works uniformly across
  arbitrary token pairs without needing an ETH↔token price. Since this pool
  uses **native ETH** as one of its two currencies, the absolute-ETH-amount
  approach is actually implementable here without an oracle (tax the ETH leg
  directly via `BeforeSwapDelta`) — worth considering as a follow-up if you
  want tax to track priority fee exactly rather than approximate it via bps.