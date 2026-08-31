// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LicenseNFT} from "@arblicense/LicenseNFT.sol";


contract LicenseNFTTest is Test {
    LicenseNFT internal nft;

    address internal owner = makeAddr("owner");
    address internal auction = makeAddr("auction");
    address internal rando = makeAddr("rando");
    address internal alice = makeAddr("alice");

    uint256 internal constant ID = 12345;

    function setUp() public {
        vm.prank(owner);
        nft = new LicenseNFT("https://example.com/{id}.json", owner);

        vm.prank(owner);
        nft.setAuction(auction);
    }

    function test_setAuction_onlyOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        nft.setAuction(rando);
    }

    function test_setAuction_updatesAuctionAddress() public {
        assertEq(nft.auction(), auction);
    }

    function test_mint_onlyAuction() public {
        vm.prank(rando);
        vm.expectRevert(LicenseNFT.NotAuction.selector);
        nft.mint(alice, ID, 1);
    }

    function test_mint_byAuction_succeeds() public {
        vm.prank(auction);
        nft.mint(alice, ID, 1);
        assertEq(nft.balanceOf(alice, ID), 1);
    }

    function test_transfer_bySecondaryMarket_works() public {
        vm.prank(auction);
        nft.mint(alice, ID, 1);

        vm.prank(alice);
        nft.safeTransferFrom(alice, rando, ID, 1, "");

        assertEq(nft.balanceOf(alice, ID), 0);
        assertEq(nft.balanceOf(rando, ID), 1);
    }

    function test_updatingAuction_revokesOldAuctionMintRights() public {
        address newAuction = makeAddr("newAuction");

        vm.prank(owner);
        nft.setAuction(newAuction);

        vm.prank(auction);
        vm.expectRevert(LicenseNFT.NotAuction.selector);
        nft.mint(alice, ID, 1);

        vm.prank(newAuction);
        nft.mint(alice, ID, 1);
        assertEq(nft.balanceOf(alice, ID), 1);
    }
}