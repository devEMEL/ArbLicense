// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// This is the demo: no frontend, so this test file IS the walkthrough.
// Run it with:
//   forge test --match-contract DemoFlowTest -vvvv
// -vvvv gives you full call traces (bid -> settle -> mint -> swap -> tax),
// which is what you want to actually show someone the flow. Drop to -vv if
// you just want the emitted log_named_uint lines without the trace noise.
//
// NOTE ON VERSION SENSITIVITY: same as ArbLicenseHookTest.t.sol — relies on
// v4-core's `Deployers` base and v4-periphery's `HookMiner`. Check both
// against your pinned commit if this fails to compile.
//
// Unlike ArbLicenseHookTest.t.sol (which swaps through v4-core's
// PoolSwapTest to isolate the hook), this test swaps through THIS repo's
// own SwapRouter on purpose — that's the router a real integrator/demo
// would actually call, and it was the one piece of the flow with no
// coverage.

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ArbLicenseHook} from "@arblicense/ArbLicenseHook.sol";
import {EpochAuction} from "@arblicense/EpochAuction.sol";
import {LicenseNFT} from "@arblicense/LicenseNFT.sol";
import {SwapRouter} from "@arblicense/SwapRouter.sol";
import {LicenseId} from "@arblicense-libraries/LicenseId.sol";
import {LicensePermit} from "@arblicense-libraries/LicensePermit.sol";
import {Epoch} from "@arblicense-libraries/Epoch.sol";

contract DemoFlowTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    ArbLicenseHook internal hook;
    EpochAuction internal auction;
    LicenseNFT internal licenseNFT;
    SwapRouter internal router;
    MockERC20 internal token;

    uint256 internal licenseePk = 0xA11CE;
    address internal licensee; // wins the auction
    address internal rival; // never licensed, always pays the scaled tax

    uint64 internal targetEpoch;

    function setUp() public {
        licensee = vm.addr(licenseePk);
        rival = makeAddr("rival");
        vm.deal(licensee, 10 ether);
        vm.deal(rival, 10 ether);

        deployFreshManagerAndRouters();

        token = new MockERC20("Test Token", "TST", 18);
        token.mint(address(this), 1_000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        currency0 = CurrencyLibrary.ADDRESS_ZERO; // native ETH
        currency1 = Currency.wrap(address(token));

        licenseNFT = new LicenseNFT("https://example.com/{id}.json", address(this));
        auction = new EpochAuction(manager, licenseNFT);
        licenseNFT.setAuction(address(auction)); // real auction, not a test stub

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ArbLicenseHook).creationCode, abi.encode(manager, licenseNFT));
        hook = new ArbLicenseHook{salt: salt}(manager, licenseNFT);
        require(address(hook) == hookAddress, "hook address / flags mismatch");

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

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

        router = new SwapRouter(manager); // this repo's own router, not PoolSwapTest

        targetEpoch = Epoch.current() + 1;
        // Comfortably inside the bidding window for targetEpoch.
        vm.roll(Epoch.startBlock(targetEpoch) - auction.BIDDING_BUFFER_BLOCKS() - 10);
    }

    function _buildPermit(uint256 nonce, uint256 id) internal view returns (bytes memory) {
        LicensePermit.Permit memory permit =
            LicensePermit.Permit({licenseId: id, licensee: licensee, nonce: nonce, deadline: block.timestamp + 1 days});
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", hook.DOMAIN_SEPARATOR(), LicensePermit.hashStruct(permit)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(licenseePk, digest);
        return abi.encode(licensee, nonce, permit.deadline, abi.encodePacked(r, s, v));
    }

    /// @dev Swaps 0.01 ETH -> token through THIS repo's SwapRouter (not
    ///      PoolSwapTest), as `who`, attaching `hookData`, and returns the
    ///      taxFee pulled from the hook's TaxApplied event.
    function _swapViaRouter(address who, bytes memory hookData) internal returns (uint24 taxFee) {
        SwapParams memory params = SwapParams({
            zeroForOne: true, // ETH in, token out
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.recordLogs();
        vm.prank(who);
        router.swap{value: 0.01 ether}(key, params, hookData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics.length > 0 && logs[i - 1].topics[0] == ArbLicenseHook.TaxApplied.selector) {
                (, taxFee) = abi.decode(logs[i - 1].data, (uint256, uint24));
                return taxFee;
            }
        }
        revert("TaxApplied event not found");
    }

    /// @notice THE demo scenario. Trace this with -vvvv:
    ///   1. licensee bids and wins the auction for the next epoch
    ///   2. anyone settles once bidding closes -> license NFT minted, bid
    ///      donated to LPs
    ///   3. epoch begins; BOTH licensee and an unlicensed rival fire the
    ///      same aggressively-tipped swap through SwapRouter
    ///   4. licensee attaches a signed permit as hookData and pays the flat
    ///      1% rate; rival pays the scaled rate, capped at 30% here
    function test_demo_fullFlow_licenseeSwapsCheapRivalSwapsExpensive() public {
        // 1. Bid and win.
        vm.prank(licensee);
        auction.bid{value: 1 ether}(key, targetEpoch);

        // 2. Bidding window closes; settle.
        vm.roll(Epoch.startBlock(targetEpoch) - auction.BIDDING_BUFFER_BLOCKS());
        auction.settle(key, targetEpoch);

        uint256 licenseId = LicenseId.pack(key.toId(), targetEpoch);
        assertEq(licenseNFT.balanceOf(licensee, licenseId), 1, "license not minted to winner");

        // 3. Epoch begins. Same aggressive priority fee for both swaps below
        //    so the only variable is licensed vs. unlicensed.
        vm.roll(Epoch.startBlock(targetEpoch) + 1);
        assertTrue(Epoch.isActive(targetEpoch), "not in target epoch");

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + hook.arbPriorityFeeThreshold() + 125 gwei); // aggressive tip, from 20

        // 4a. Rival has no license -> scaled unlicensed tax (capped here).
        uint24 rivalTaxFee = _swapViaRouter(rival, "");

        // 4b. Licensee proves the license via a signed EIP-712 permit passed
        //     as hookData (not msg.sender) -> flat licensed rate.
        bytes memory permitData = _buildPermit(0, licenseId);
        uint24 licenseeTaxFee = _swapViaRouter(licensee, permitData);

        assertEq(licenseeTaxFee, hook.licensedTaxFee(), "licensee should pay the flat 1% rate");
        assertEq(rivalTaxFee, hook.maxUnlicensedTaxFee(), "rival's tip is big enough to hit the 30% cap");
        assertGt(rivalTaxFee, licenseeTaxFee, "rival should pay far more than the licensee");

        emit log_named_uint("licensee taxFee (flat, licensed)", licenseeTaxFee);
        emit log_named_uint("rival taxFee (scaled, unlicensed, capped)", rivalTaxFee);
    }
}