// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Initializes a v4 pool using the previously-deployed ArbLicenseHook.
///         Must be run AFTER DeployCore.s.sol.
///
/// Required env vars:
///   POOL_MANAGER        - address of the deployed v4 PoolManager
///   HOOK_ADDRESS         - address of the deployed ArbLicenseHook (from DeployCore output)
///   CURRENCY0            - lower-sorted currency address (use address(0) for native ETH)
///   CURRENCY1            - higher-sorted currency address (must be > CURRENCY0)
///
/// Optional env vars:
///   TICK_SPACING          - defaults to 60
///   START_SQRT_PRICE_X96  - defaults to the sqrt price at tick 0 (i.e. 1:1)
///
/// Usage:
///   forge script script/InitPool.s.sol:InitPool \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast -vvvv
///
/// @dev The fee field MUST be LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000). If the
///      pool is initialized with a static fee instead, ArbLicenseHook's
///      OVERRIDE_FEE_FLAG return value in _beforeSwap will not be honored by
///      PoolManager the way the hook expects — this is the single most common
///      way to "successfully" deploy a dynamic-fee hook and then have it silently
///      do nothing useful. Currency0/currency1 must also be passed in ascending
///      address order, or PoolManager.initialize will revert.
contract InitPool is Script {
    function run() external returns (PoolKey memory key) {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        address currency0Addr = vm.envAddress("CURRENCY0");
        address currency1Addr = vm.envAddress("CURRENCY1");
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        uint160 startSqrtPriceX96 =
            uint160(vm.envOr("START_SQRT_PRICE_X96", uint256(TickMath.getSqrtPriceAtTick(0))));

        require(currency0Addr < currency1Addr, "InitPool: CURRENCY0 must be < CURRENCY1");

        IPoolManager poolManager = IPoolManager(poolManagerAddr);

        key = PoolKey({
            currency0: Currency.wrap(currency0Addr),
            currency1: Currency.wrap(currency1Addr),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        vm.startBroadcast();
        poolManager.initialize(key, startSqrtPriceX96);
        vm.stopBroadcast();

        console2.log("Pool initialized");
        console2.log("currency0 :", currency0Addr);
        console2.log("currency1 :", currency1Addr);
        console2.log("hook      :", hookAddr);
        console2.log("tickSpacing:", uint256(uint24(tickSpacing)));
    }
}