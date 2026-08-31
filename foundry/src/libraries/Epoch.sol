// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Pure block-math helpers for epoch timing. Used by both the hook and
///         the auction so they can never drift out of sync on "what epoch is it."
library Epoch {
    /// @dev Blocks per epoch. Tune to your desired cadence.
    uint256 internal constant EPOCH_LENGTH = 300;

    function current() internal view returns (uint64) {
        return uint64(block.number / EPOCH_LENGTH);
    }

    function startBlock(uint64 epoch) internal pure returns (uint256) {
        return uint256(epoch) * EPOCH_LENGTH;
    }

    function endBlock(uint64 epoch) internal pure returns (uint256) {
        return startBlock(epoch) + EPOCH_LENGTH - 1;
    }

    function isActive(uint64 epoch) internal view returns (bool) {
        return current() == epoch;
    }
}