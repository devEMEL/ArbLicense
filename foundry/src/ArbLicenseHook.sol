// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {
    BaseHook
} from "v4-hooks-public/lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";


import {LicenseNFT} from "./LicenseNFT.sol";
import {LicenseId} from "./libraries/LicenseId.sol";
import {LicensePermit} from "./libraries/LicensePermit.sol";
import {Epoch} from "./libraries/Epoch.sol";


contract ArbLicenseHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    LicenseNFT public immutable licenseNFT;
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @dev Priority fee (wei per gas) above which a swap is treated as
    ///      arb-shaped and becomes eligible for taxation if unlicensed.
    ///      Tune based on observed searcher tip behavior on your target chain.
    uint256 public arbPriorityFeeThreshold = 2 gwei;

    /// @dev Flat rate (basis points, 100 = 1%) applied to the licensee's own
    ///      arb-shaped swaps during their epoch. This is NOT zero — the auction
    ///      bid buys a discount vs. the unlicensed rate, not full exemption.
    ///      Deliberately NOT scaled with priority fee: the licensee already
    ///      pre-paid for cheap access at auction, so their per-swap cost
    ///      should stay predictable regardless of how urgently they trade.
    uint24 public licensedTaxBps = 100; // 1%

    /// @dev Floor tax rate (bps) applied to unlicensed arb-shaped swaps the
    ///      moment they cross arbPriorityFeeThreshold.
    uint24 public minUnlicensedTaxBps = 500; // 5%

    /// @dev Ceiling tax rate (bps) — the unlicensed rate never exceeds this,
    ///      regardless of how high priority fee goes. Keeps the tax from
    ///      approaching 100% and making the pool practically unusable to
    ///      unlicensed arbers (a total block, not just a tax).
    uint24 public maxUnlicensedTaxBps = 3000; // 30%

    /// @dev How many extra bps of tax get added per extra gwei of priority
    ///      fee paid above arbPriorityFeeThreshold. This is the knob that
    ///      makes the tax scale with how much the searcher was willing to
    ///      pay — the closer analogue to Angstrom's "tax ~ priority fee"
    ///      model, expressed in bps-per-gwei instead of wei-per-wei.
    uint256 public taxBpsPerExtraGwei = 200; // +2% tax per extra gwei of tip

    /// @dev Per-licensee replay-protection nonce for permits.
    mapping(address => uint256) public permitNonces;

    event TaxApplied(
        PoolId indexed poolId, uint64 indexed epoch, address indexed swapper, uint256 priorityFee, uint24 taxBps
    );
    event LicenseHonored(PoolId indexed poolId, uint64 indexed epoch, address indexed licensee);

    constructor(IPoolManager _poolManager, LicenseNFT _licenseNFT) BaseHook(_poolManager) {
        licenseNFT = _licenseNFT;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ArbLicenseHook"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 priorityFee = tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;

        // Doesn't look arb-shaped by our proxy metric — no tax logic applies,
        // ordinary swap fee stands.
        if (priorityFee < arbPriorityFeeThreshold) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId poolId = key.toId();
        uint64 epoch = Epoch.current();
        uint256 id = LicenseId.pack(poolId, epoch);

        address licensee = _recoverLicensee(id, hookData);
        bool isLicensee = licensee != address(0) && licenseNFT.balanceOf(licensee, id) > 0;

        uint24 taxBps = isLicensee ? licensedTaxBps : _scaledUnlicensedTaxBps(priorityFee);

        // The OVERRIDE_FEE_FLAG bit convention below must match your pinned
        // v4-core version's dynamic-fee handling in PoolManager.
        uint24 overrideFee = taxBps | 0x400000;

        if (isLicensee) {
            emit LicenseHonored(poolId, epoch, licensee);
        }
        emit TaxApplied(poolId, epoch, sender, priorityFee, taxBps);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
    }

    /// @dev Maps priority fee -> tax bps for unlicensed swaps: starts at
    ///      minUnlicensedTaxBps right at the arb threshold, climbs by
    ///      taxBpsPerExtraGwei for every gwei of priority fee beyond that,
    ///      capped at maxUnlicensedTaxBps.
    function _scaledUnlicensedTaxBps(uint256 priorityFee) internal view returns (uint24) {
        uint256 excessWei = priorityFee - arbPriorityFeeThreshold; // safe: priorityFee >= threshold here
        uint256 excessGwei = excessWei / 1 gwei;
        uint256 scaled = uint256(minUnlicensedTaxBps) + (excessGwei * taxBpsPerExtraGwei);

        if (scaled > maxUnlicensedTaxBps) {
            return maxUnlicensedTaxBps;
        }
        return uint24(scaled);
    }

    /// @dev Recovers and validates the licensee from a signed permit in
    ///      hookData, if present. Returns address(0) if hookData is empty or
    ///      the nonce doesn't match (stale/replayed permit) — NOT if the
    ///      signature itself is malformed, which will revert the swap outright
    ///      via LicensePermit.verify's underlying ECDSA.recover. Decide if you'd
    ///      rather silently fall through to the taxed path on a bad signature
    ///      instead of reverting.
    function _recoverLicensee(uint256 id, bytes calldata hookData) internal returns (address licensee) {
        if (hookData.length == 0) return address(0);

        uint256 nonce;
        uint256 deadline;
        bytes memory signature;
        (licensee, nonce, deadline, signature) = abi.decode(hookData, (address, uint256, uint256, bytes));

        if (nonce != permitNonces[licensee]) return address(0);

        LicensePermit.Permit memory permit =
            LicensePermit.Permit({licenseId: id, licensee: licensee, nonce: nonce, deadline: deadline});

        address signer = LicensePermit.verify(permit, DOMAIN_SEPARATOR, signature);
        if (signer != licensee) return address(0);

        permitNonces[licensee]++;
    }
}