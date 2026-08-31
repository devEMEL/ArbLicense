// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// NOTE ON VERSION SENSITIVITY: this test relies on:
//   - v4-core's `Deployers` base contract (test/utils/Deployers.sol)
//   - v4-periphery's `HookMiner` (src/utils/HookMiner.sol) to mine a hook
//     address with the correct permission-flag bits for CREATE2 deployment
//   - v4-core's `PoolSwapTest` router (exposed as `swapRouter` by Deployers)
//     and its `TestSettings` struct
//   - solmate's MockERC20
// All four are among the most version-sensitive parts of the v4 test stack.
// Check these against your pinned commit if compilation fails here.

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ArbLicenseHook} from "@arblicense/ArbLicenseHook.sol";
import {LicenseNFT} from "@arblicense/LicenseNFT.sol";
import {LicenseId} from "@arblicense-libraries/LicenseId.sol";
import {LicensePermit} from "@arblicense-libraries/LicensePermit.sol";
import {Epoch} from "@arblicense-libraries/Epoch.sol";

contract ArbLicenseHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    ArbLicenseHook internal hook;
    LicenseNFT internal licenseNFT;
    MockERC20 internal token;

    uint256 internal licenseePk = 0xA11CE;
    address internal licensee;

    function setUp() public {
        licensee = vm.addr(licenseePk);

        deployFreshManagerAndRouters();

        token = new MockERC20("Test Token", "TST", 18);
        token.mint(address(this), 1_000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        currency0 = CurrencyLibrary.ADDRESS_ZERO; // native ETH
        currency1 = Currency.wrap(address(token));

        licenseNFT = new LicenseNFT("https://example.com/{id}.json", address(this));

        // Mine + deploy the hook at an address encoding the correct
        // permission flags for beforeSwap + beforeSwapReturnDelta.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ArbLicenseHook).creationCode, abi.encode(manager, licenseNFT));

        hook = new ArbLicenseHook{salt: salt}(manager, licenseNFT);
        require(address(hook) == hookAddress, "hook address / flags mismatch");

        // Let this test contract mint license NFTs directly (bypassing
        // EpochAuction, which is tested separately).
        licenseNFT.setAuction(address(this));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    // --- helpers ---

    function _mintLicenseForCurrentEpoch() internal returns (uint64 epoch, uint256 id) {
        epoch = Epoch.current();
        id = LicenseId.pack(key.toId(), epoch);
        licenseNFT.mint(licensee, id, 1);
    }

    function _buildPermit(uint256 nonce, uint256 id) internal view returns (bytes memory hookData) {
        LicensePermit.Permit memory permit =
            LicensePermit.Permit({licenseId: id, licensee: licensee, nonce: nonce, deadline: block.timestamp + 1 days});

        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", hook.DOMAIN_SEPARATOR(), LicensePermit.hashStruct(permit)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(licenseePk, digest);

        hookData = abi.encode(licensee, nonce, permit.deadline, abi.encodePacked(r, s, v));
    }

    function _swap(bool zeroForOne, bytes memory hookData) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -0.01 ether, // small exact-input swap
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        if (zeroForOne) {
            swapRouter.swap{value: 0.01 ether}(key, params, settings, hookData);
        } else {
            swapRouter.swap(key, params, settings, hookData);
        }
    }

    /// @dev Pulls taxBps out of the most recently emitted TaxApplied event.
    function _lastTaxAppliedBps() internal returns (uint24 taxBps) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.topics.length > 0 && log.topics[0] == ArbLicenseHook.TaxApplied.selector) {
                (, taxBps) = abi.decode(log.data, (uint256, uint24));
                return taxBps;
            }
        }
        revert("TaxApplied event not found");
    }

    function _lastLicenseHonoredEmitted() internal returns (bool found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == ArbLicenseHook.LicenseHonored.selector) {
                return true;
            }
        }
        return false;
    }

    // --- threshold gating ---

    function test_belowThreshold_noTaxLogicEngages() public {
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei); // priority fee = 0

        vm.recordLogs();
        _swap(true, "");

        // No TaxApplied event should fire at all below the threshold.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != ArbLicenseHook.TaxApplied.selector);
        }
    }

    // --- unlicensed scaling tax ---

    function test_unlicensedSwap_atThreshold_paysFloorTax() public {
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + hook.arbPriorityFeeThreshold());

        vm.recordLogs();
        _swap(true, "");

        assertEq(_lastTaxAppliedBps(), hook.minUnlicensedTaxBps());
    }

    function test_unlicensedSwap_scalesWithPriorityFee() public {
        vm.fee(1 gwei);
        uint256 threshold = hook.arbPriorityFeeThreshold();
        uint256 extraGwei = 3;
        vm.txGasPrice(1 gwei + threshold + extraGwei * 1 gwei);

        vm.recordLogs();
        _swap(true, "");

        uint24 expected = hook.minUnlicensedTaxBps() + uint24(extraGwei * hook.taxBpsPerExtraGwei());
        assertEq(_lastTaxAppliedBps(), expected);
    }

    function test_unlicensedSwap_capsAtMaxTaxBps() public {
        vm.fee(1 gwei);
        uint256 threshold = hook.arbPriorityFeeThreshold();
        // Comfortably beyond whatever priority fee would be needed to hit the cap.
        vm.txGasPrice(1 gwei + threshold + 1000 gwei);

        vm.recordLogs();
        _swap(true, "");

        assertEq(_lastTaxAppliedBps(), hook.maxUnlicensedTaxBps());
    }

    // --- licensed flat tax ---

    function test_licensedSwap_paysFlatRate_regardlessOfPriorityFee() public {
        (, uint256 id) = _mintLicenseForCurrentEpoch();

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + hook.arbPriorityFeeThreshold() + 50 gwei); // huge tip

        bytes memory hookData = _buildPermit(0, id);

        vm.recordLogs();
        _swap(true, hookData);

        assertEq(_lastTaxAppliedBps(), hook.licensedTaxBps());
        assertTrue(_lastLicenseHonoredEmitted());
    }

    function test_licensedSwap_belowThreshold_noTaxLogicEngagesEither() public {
        _mintLicenseForCurrentEpoch();

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei); // below threshold — license check shouldn't even run

        vm.recordLogs();
        _swap(true, "");

        assertFalse(_lastLicenseHonoredEmitted());
    }

    // --- permit validation edge cases ---

    function test_staleNonce_fallsThroughToUnlicensedTax() public {
        (, uint256 id) = _mintLicenseForCurrentEpoch();

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + hook.arbPriorityFeeThreshold() + 1 gwei);

        // Nonce 999 doesn't match the licensee's current nonce (0) — permit
        // should be rejected and the swap should fall through to the taxed path.
        bytes memory hookData = _buildPermit(999, id);

        vm.recordLogs();
        _swap(true, hookData);

        assertFalse(_lastLicenseHonoredEmitted());
        assertTrue(_lastTaxAppliedBps() >= hook.minUnlicensedTaxBps());
    }

    function test_permitForWrongEpoch_fallsThroughToUnlicensedTax() public {
        _mintLicenseForCurrentEpoch();

        // Build a permit for a licenseId that doesn't match the current
        // epoch (e.g. a stale permit from a prior epoch).
        uint256 wrongId = LicenseId.pack(key.toId(), Epoch.current() + 1);
        bytes memory hookData = _buildPermit(0, wrongId);

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + hook.arbPriorityFeeThreshold() + 1 gwei);

        vm.recordLogs();
        _swap(true, hookData);

        assertFalse(_lastLicenseHonoredEmitted());
    }

    function test_permitNonce_incrementsAfterSuccessfulUse() public {
        (, uint256 id) = _mintLicenseForCurrentEpoch();

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + hook.arbPriorityFeeThreshold() + 1 gwei);

        assertEq(hook.permitNonces(licensee), 0);
        _swap(true, _buildPermit(0, id));
        assertEq(hook.permitNonces(licensee), 1);
    }

    function test_licenseHolderWithoutNFT_treatedAsUnlicensed() public {
        // Build a validly-signed permit for a licenseId the signer never
        // actually holds (e.g. license was never minted, or was transferred
        // away since signing).
        uint256 id = LicenseId.pack(key.toId(), Epoch.current());
        bytes memory hookData = _buildPermit(0, id);

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + hook.arbPriorityFeeThreshold() + 1 gwei);

        vm.recordLogs();
        _swap(true, hookData);

        assertFalse(_lastLicenseHonoredEmitted());
    }
}