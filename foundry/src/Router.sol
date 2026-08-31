// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {
    IUnlockCallback
} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {
    ModifyLiquidityParams,
    SwapParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Minimal swap router for demoing/testing the ArbLicenseHook pool.
///         Not gas-optimized or production-hardened — just enough to execute
///         a swap through PoolManager's unlock/settle/take pattern and pass
///         `hookData` through untouched, so you can attach a signed
///         LicensePermit when demoing the licensed-vs-unlicensed tax paths.
///
/// @dev v4-core ships its own test router (`PoolSwapTest` under
///      `v4-core/test/utils/`) that does the same job and is already wired
///      into v4's test suite — worth considering reusing that directly
///      instead of this one if it fits your demo. This version exists so you
///      have full control (e.g. to extend with a helper that builds and signs
///      a LicensePermit for you before calling swap).
contract Router is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    error NotPoolManager();

    struct SwapCallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Executes a swap against `key`'s pool. `hookData` is passed
    ///         straight through to the hook — this is how a licensee attaches
    ///         their signed LicensePermit for the ArbLicenseHook to read in
    ///         `_beforeSwap`.
    /// @dev For native-ETH pools, send the input amount as msg.value; it's
    ///      held by the router until the callback settles it.
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.unlock(abi.encode(SwapCallbackData(msg.sender, key, params, hookData))), (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));

        BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Negative delta = we owe the pool; positive = the pool owes us.
        if (delta0 < 0) _settle(data.key.currency0, data.sender, uint256(uint128(-delta0)));
        if (delta1 < 0) _settle(data.key.currency1, data.sender, uint256(uint128(-delta1)));
        if (delta0 > 0) poolManager.take(data.key.currency0, data.sender, uint256(uint128(delta0)));
        if (delta1 > 0) poolManager.take(data.key.currency1, data.sender, uint256(uint128(delta1)));

        return abi.encode(delta);
    }

    /// @dev NOTE: the exact sync()/settle() call sequence and whether native
    ///      ETH needs a sync() call at all differs slightly across v4-core
    ///      versions — verify against your pinned commit.
    function _settle(Currency currency, address payer, uint256 amount) internal {
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), amount);
            poolManager.settle();
        }
    }

    receive() external payable {}
}