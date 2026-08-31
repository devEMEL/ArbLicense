// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {LicenseNFT} from "./LicenseNFT.sol";
import {LicenseId} from "./libraries/LicenseId.sol";
import {Epoch} from "./libraries/Epoch.sol";

/// @notice Simple ascending-bid auction for the arb license of the *next* epoch,
///         per pool. Bidding for epoch N must close before epoch N begins.
///         Settling mints the license NFT to the winner and donates the winning
///         bid straight into the pool as LP fees.
///
/// @dev NOTE: the donate() wiring below uses PoolManager's unlock/callback
///      pattern. The exact settle/sync calls on Currency differ across v4-core
///      versions — double check `_donateToPool`/`unlockCallback` against
///      whatever v4-core commit you've pinned in foundry.toml before deploying.
///      This assumes bids are collected in native ETH as currency0 of the pool;
///      adjust if your pools use a different bid currency.
contract EpochAuction is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;
    LicenseNFT public immutable licenseNFT;

    /// @dev How many blocks before an epoch starts that bidding must close.
    uint256 public constant BIDDING_BUFFER_BLOCKS = 20;

    struct AuctionState {
        address highBidder;
        uint256 highBid;
        bool settled;
    }

    // poolId => epoch => auction state
    mapping(PoolId => mapping(uint64 => AuctionState)) public auctions;
    // poolId => epoch => bidder => amount currently on deposit
    mapping(PoolId => mapping(uint64 => mapping(address => uint256))) public bids;

    event BidPlaced(PoolId indexed poolId, uint64 indexed epoch, address indexed bidder, uint256 amount);
    event AuctionSettled(PoolId indexed poolId, uint64 indexed epoch, address indexed winner, uint256 amount);
    event Refunded(PoolId indexed poolId, uint64 indexed epoch, address indexed bidder, uint256 amount);

    error BiddingClosed();
    error BidTooLow();
    error AlreadySettled();
    error NoBids();
    error NotYetSettleable();
    error StillHighestBidder();
    error NothingToRefund();
    error RefundFailed();
    error NotPoolManager();

    constructor(IPoolManager _poolManager, LicenseNFT _licenseNFT) {
        poolManager = _poolManager;
        licenseNFT = _licenseNFT;
    }

    /// @notice Bid for the license of `epoch` on `key`'s pool. Cumulative deposit
    ///         (this call's value + any prior deposit from msg.sender) must
    ///         exceed the current high bid.
    function bid(PoolKey calldata key, uint64 epoch) external payable {
        PoolId poolId = key.toId();

        if (block.number >= Epoch.startBlock(epoch) - BIDDING_BUFFER_BLOCKS) revert BiddingClosed();

        AuctionState storage a = auctions[poolId][epoch];
        uint256 newTotal = bids[poolId][epoch][msg.sender] + msg.value;
        if (newTotal <= a.highBid) revert BidTooLow();

        bids[poolId][epoch][msg.sender] = newTotal;
        a.highBidder = msg.sender;
        a.highBid = newTotal;

        emit BidPlaced(poolId, epoch, msg.sender, newTotal);
    }

    /// @notice Withdraw your deposit once you've been outbid, or after a
    ///         settled auction if you weren't the winner.
    function refund(PoolKey calldata key, uint64 epoch) external {
        PoolId poolId = key.toId();
        AuctionState storage a = auctions[poolId][epoch];
        if (msg.sender == a.highBidder && !a.settled) revert StillHighestBidder();

        uint256 amount = bids[poolId][epoch][msg.sender];
        if (amount == 0) revert NothingToRefund();
        bids[poolId][epoch][msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert RefundFailed();

        emit Refunded(poolId, epoch, msg.sender, amount);
    }

    /// @notice Settle the auction once bidding has closed: mint the license NFT
    ///         to the winner and donate the winning bid to the pool as LP fees.
    ///         Callable by anyone once the bidding window has passed.
    function settle(PoolKey calldata key, uint64 epoch) external {
        PoolId poolId = key.toId();
        AuctionState storage a = auctions[poolId][epoch];

        if (a.settled) revert AlreadySettled();
        if (block.number < Epoch.startBlock(epoch) - BIDDING_BUFFER_BLOCKS) revert NotYetSettleable();
        if (a.highBidder == address(0)) revert NoBids();

        a.settled = true;
        bids[poolId][epoch][a.highBidder] = 0; // winning bid is spent, not refundable

        uint256 id = LicenseId.pack(poolId, epoch);
        licenseNFT.mint(a.highBidder, id, 1);

        _donateToPool(key, a.highBid);

        emit AuctionSettled(poolId, epoch, a.highBidder, a.highBid);
    }

    function _donateToPool(PoolKey calldata key, uint256 amount) internal {
        poolManager.unlock(abi.encode(key, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 amount) = abi.decode(data, (PoolKey, uint256));

        // Donates entirely into currency0 (assumed native ETH here). Split
        // across currency0/currency1 instead if your bid currency differs.
        poolManager.donate(key, amount, 0, "");
        key.currency0.settle(poolManager, address(this), amount, false);

        return "";
    }

    receive() external payable {}
}