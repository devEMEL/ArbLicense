// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Epoch} from "@arblicense-libraries/Epoch.sol";

contract EpochTest is Test {
    function test_current_derivesFromBlockNumber() public {
        vm.roll(Epoch.EPOCH_LENGTH * 47);
        assertEq(Epoch.current(), 47);
    }

    function test_current_roundsDownWithinEpoch() public {
        vm.roll(Epoch.EPOCH_LENGTH * 47 + Epoch.EPOCH_LENGTH - 1);
        assertEq(Epoch.current(), 47);

        vm.roll(Epoch.EPOCH_LENGTH * 48);
        assertEq(Epoch.current(), 48);
    }

    function test_startBlock_and_endBlock() public pure {
        assertEq(Epoch.startBlock(47), 47 * Epoch.EPOCH_LENGTH);
        assertEq(Epoch.endBlock(47), 48 * Epoch.EPOCH_LENGTH - 1);
    }

    function test_isActive_trueOnlyForCurrentEpoch() public {
        vm.roll(Epoch.startBlock(10));
        assertTrue(Epoch.isActive(10));
        assertFalse(Epoch.isActive(9));
        assertFalse(Epoch.isActive(11));
    }
}