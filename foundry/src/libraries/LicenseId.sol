// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Packs (poolId, epoch) into a single uint256 ERC-1155 token id, cheaply,
///         with no storage read or hashing needed at swap time.
///         Layout: top 192 bits = truncated poolId, bottom 64 bits = epoch.
library LicenseId {
    function pack(PoolId poolId, uint64 epoch) internal pure returns (uint256 id) {
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        id = (poolIdUint & ~uint256(type(uint64).max)) | uint256(epoch);
    }

    function epochOf(uint256 id) internal pure returns (uint64) {
        return uint64(id);
    }
}