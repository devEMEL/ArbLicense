// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LicenseId} from "@arblicense-libraries/LicenseId.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract LicenseIdTest is Test {
    function test_pack_differsAcrossPools_sameEpoch() public pure {
        // Realistic pool IDs are keccak256 hashes spanning the full 256 bits.
        // Tiny literal values here would accidentally collide: pack() keeps
        // only the upper 192 bits of the poolId (the lower 64 are reserved
        // for the epoch), and a small literal like 0xAAAA lives entirely
        // inside that discarded region.
        PoolId poolA = PoolId.wrap(keccak256("poolA"));
        PoolId poolB = PoolId.wrap(keccak256("poolB"));

        uint256 idA = LicenseId.pack(poolA, 47);
        uint256 idB = LicenseId.pack(poolB, 47);

        assertTrue(idA != idB, "same id for different pools - collision risk");
    }

    function test_pack_differsAcrossEpochs_samePool() public pure {
        PoolId pool = PoolId.wrap(keccak256("poolA"));

        uint256 id46 = LicenseId.pack(pool, 46);
        uint256 id47 = LicenseId.pack(pool, 47);

        assertTrue(id46 != id47, "same id for different epochs - collision risk");
    }

    function test_epochOf_roundTrips() public pure {
        PoolId pool = PoolId.wrap(keccak256("poolA"));
        uint64 epoch = 12345;

        uint256 id = LicenseId.pack(pool, epoch);
        assertEq(LicenseId.epochOf(id), epoch);
    }

    function test_pack_isPure_deterministic() public pure {
        PoolId pool = PoolId.wrap(keccak256("poolA"));
        assertEq(LicenseId.pack(pool, 47), LicenseId.pack(pool, 47));
    }
}