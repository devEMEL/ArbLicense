// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LicenseId} from "@arblicense-libraries/LicenseId.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract LicenseIdTest is Test {
    function test_pack_differsAcrossPools_sameEpoch() public pure {
        PoolId poolA = PoolId.wrap(bytes32(uint256(0xAAAA)));
        PoolId poolB = PoolId.wrap(bytes32(uint256(0xBBBB)));

        uint256 idA = LicenseId.pack(poolA, 47);
        uint256 idB = LicenseId.pack(poolB, 47);

        assertTrue(idA != idB, "same id for different pools - collision risk");
    }

    function test_pack_differsAcrossEpochs_samePool() public pure {
        PoolId pool = PoolId.wrap(bytes32(uint256(0xAAAA)));

        uint256 id46 = LicenseId.pack(pool, 46);
        uint256 id47 = LicenseId.pack(pool, 47);

        assertTrue(id46 != id47, "same id for different epochs - collision risk");
    }

    function test_epochOf_roundTrips() public pure {
        PoolId pool = PoolId.wrap(bytes32(uint256(0xAAAA)));
        uint64 epoch = 12345;

        uint256 id = LicenseId.pack(pool, epoch);
        assertEq(LicenseId.epochOf(id), epoch);
    }

    function test_pack_isPure_deterministic() public pure {
        PoolId pool = PoolId.wrap(bytes32(uint256(0xAAAA)));
        assertEq(LicenseId.pack(pool, 47), LicenseId.pack(pool, 47));
    }
}