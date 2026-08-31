// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// NOTE ON VERSION SENSITIVITY: this test relies on v4-core's `Deployers` base
// contract (test/utils/Deployers.sol) for PoolManager + router setup, and on
// solmate's MockERC20 for a plain ERC20 test token. Both paths below match
// the common layout across recent v4-core commits but can drift — adjust
// imports/remappings if your pinned version differs.

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {EpochAuction} from "@arblicense/EpochAuction.sol";
import {LicenseNFT} from "@arblicense/LicenseNFT.sol";
import {LicenseId} from "@arblicense-libraries/LicenseId.sol";
import {Epoch} from "@arblicense-libraries/Epoch.sol";

contract EpochAuctionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    EpochAuction internal auction;
    LicenseNFT internal licenseNFT;
    MockERC20 internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint64 internal targetEpoch;

    function setUp() public {
        deployFreshManagerAndRouters();

        // currency0 = native ETH, currency1 = a plain ERC20 test token —
        // matches this project's ETH-paired pool design (see EpochAuction's
        // unlockCallback, which assumes currency0 is native).
        token = new MockERC20("Test Token", "TST", 18);
        token.mint(address(this), 1_000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        currency0 = CurrencyLibrary.ADDRESS_ZERO;
        currency1 = Currency.wrap(address(token));

        licenseNFT = new LicenseNFT("https://example.com/{id}.json", address(this));
        auction = new EpochAuction(manager, licenseNFT);
        licenseNFT.setAuction(address(auction));

        (key,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        // Seed the pool with liquidity so donate() has somewhere to land.
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

        targetEpoch = Epoch.current() + 1;
        // Land comfortably inside the bidding window for targetEpoch.
        vm.roll(Epoch.startBlock(targetEpoch) - auction.BIDDING_BUFFER_BLOCKS() - 1);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // --- bidding ---

    function test_bid_recordsHighBidder() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        (address highBidder, uint256 highBid,) = auction.auctions(key.toId(), targetEpoch);
        assertEq(highBidder, alice);
        assertEq(highBid, 1 ether);
    }

    function test_bid_revertsIfNotHigherThanCurrent() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        vm.prank(bob);
        vm.expectRevert(EpochAuction.BidTooLow.selector);
        auction.bid{value: 1 ether}(key, targetEpoch);
    }

    function test_bid_outbidding_updatesHighBidder() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        vm.prank(bob);
        auction.bid{value: 2 ether}(key, targetEpoch);

        (address highBidder, uint256 highBid,) = auction.auctions(key.toId(), targetEpoch);
        assertEq(highBidder, bob);
        assertEq(highBid, 2 ether);
    }

    function test_bid_cumulativeTopUp_countsTowardTotal() public {
        vm.startPrank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);
        auction.bid{value: 0.5 ether}(key, targetEpoch); // top up own bid
        vm.stopPrank();

        (address highBidder, uint256 highBid,) = auction.auctions(key.toId(), targetEpoch);
        assertEq(highBidder, alice);
        assertEq(highBid, 1.5 ether);
    }

    function test_bid_revertsAfterBiddingWindowCloses() public {
        vm.roll(Epoch.startBlock(targetEpoch) - auction.BIDDING_BUFFER_BLOCKS());

        vm.prank(alice);
        vm.expectRevert(EpochAuction.BiddingClosed.selector);
        auction.bid{value: 1 ether}(key, targetEpoch);
    }

    // --- refunds ---

    function test_refund_outbidBidderCanWithdraw() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        vm.prank(bob);
        auction.bid{value: 2 ether}(key, targetEpoch);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        auction.refund(key, targetEpoch);
        assertEq(alice.balance, balBefore + 1 ether);
    }

    function test_refund_revertsForCurrentHighBidderBeforeSettlement() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        vm.prank(alice);
        vm.expectRevert(EpochAuction.StillHighestBidder.selector);
        auction.refund(key, targetEpoch);
    }

    function test_refund_revertsWithNothingToRefund() public {
        vm.prank(bob);
        vm.expectRevert(EpochAuction.NothingToRefund.selector);
        auction.refund(key, targetEpoch);
    }

    // --- settlement ---

    function test_settle_revertsBeforeBiddingWindowCloses() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        vm.expectRevert(EpochAuction.NotYetSettleable.selector);
        auction.settle(key, targetEpoch);
    }

    function test_settle_revertsWithNoBids() public {
        vm.roll(Epoch.startBlock(targetEpoch) - auction.BIDDING_BUFFER_BLOCKS());

        vm.expectRevert(EpochAuction.NoBids.selector);
        auction.settle(key, targetEpoch);
    }

    function test_settle_mintsLicenseToWinner() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        vm.roll(Epoch.startBlock(targetEpoch) - auction.BIDDING_BUFFER_BLOCKS());
        auction.settle(key, targetEpoch);

        uint256 id = LicenseId.pack(key.toId(), targetEpoch);
        assertEq(licenseNFT.balanceOf(alice, id), 1);
    }

    function test_settle_revertsIfAlreadySettled() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        vm.roll(Epoch.startBlock(targetEpoch) - auction.BIDDING_BUFFER_BLOCKS());
        auction.settle(key, targetEpoch);

        vm.expectRevert(EpochAuction.AlreadySettled.selector);
        auction.settle(key, targetEpoch);
    }

    function test_settle_winningBidIsNotRefundable() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        vm.roll(Epoch.startBlock(targetEpoch) - auction.BIDDING_BUFFER_BLOCKS());
        auction.settle(key, targetEpoch);

        vm.prank(alice);
        vm.expectRevert(EpochAuction.NothingToRefund.selector);
        auction.refund(key, targetEpoch);
    }

    function test_settle_anyoneCanCallOnceWindowClosed() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(key, targetEpoch);

        vm.roll(Epoch.startBlock(targetEpoch) - auction.BIDDING_BUFFER_BLOCKS());

        // bob triggers settlement, not the winner or auction owner.
        vm.prank(bob);
        auction.settle(key, targetEpoch);

        uint256 id = LicenseId.pack(key.toId(), targetEpoch);
        assertEq(licenseNFT.balanceOf(alice, id), 1);
    }
}