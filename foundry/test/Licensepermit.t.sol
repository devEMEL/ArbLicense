// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LicensePermit} from "@arblicense-libraries/LicensePermit.sol";

/// @dev LicensePermit's functions are internal, so a thin external harness is
///      needed to call them from a test contract.
contract LicensePermitHarness {
    function verify(LicensePermit.Permit memory permit, bytes32 domainSeparator, bytes memory signature)
        external
        view
        returns (address)
    {
        return LicensePermit.verify(permit, domainSeparator, signature);
    }

    function hashStruct(LicensePermit.Permit memory permit) external pure returns (bytes32) {
        return LicensePermit.hashStruct(permit);
    }
}

contract LicensePermitTest is Test {
    LicensePermitHarness internal harness;
    bytes32 internal domainSeparator = keccak256("test-domain-separator");

    uint256 internal licenseePk = 0xA11CE;
    address internal licensee;

    function setUp() public {
        harness = new LicensePermitHarness();
        licensee = vm.addr(licenseePk);
    }

    function _digest(LicensePermit.Permit memory permit) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, harness.hashStruct(permit)));
    }

    function _signWith(uint256 pk, LicensePermit.Permit memory permit) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(permit));
        return abi.encodePacked(r, s, v);
    }

    function test_verify_recoversCorrectSigner() public view {
        LicensePermit.Permit memory permit = LicensePermit.Permit({
            licenseId: 123,
            licensee: licensee,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes memory sig = _signWith(licenseePk, permit);
        assertEq(harness.verify(permit, domainSeparator, sig), licensee);
    }

    function test_verify_revertsIfExpired() public {
        LicensePermit.Permit memory permit = LicensePermit.Permit({
            licenseId: 123,
            licensee: licensee,
            nonce: 0,
            deadline: block.timestamp == 0 ? 0 : block.timestamp - 1
        });

        bytes memory sig = _signWith(licenseePk, permit);
        vm.expectRevert(bytes("LicensePermit: expired"));
        harness.verify(permit, domainSeparator, sig);
    }

    function test_verify_wrongSigner_doesNotRecoverLicensee() public view {
        LicensePermit.Permit memory permit = LicensePermit.Permit({
            licenseId: 123,
            licensee: licensee,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        uint256 otherPk = 0xB0B;
        bytes memory sig = _signWith(otherPk, permit);

        address recovered = harness.verify(permit, domainSeparator, sig);
        assertTrue(recovered != licensee);
    }

    function test_verify_differentDomainSeparator_doesNotRecoverLicensee() public view {
        LicensePermit.Permit memory permit = LicensePermit.Permit({
            licenseId: 123,
            licensee: licensee,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes memory sig = _signWith(licenseePk, permit);
        address recovered = harness.verify(permit, keccak256("different-domain"), sig);
        assertTrue(recovered != licensee);
    }

    function test_hashStruct_changesWithLicenseId() public view {
        LicensePermit.Permit memory permitA = LicensePermit.Permit({
            licenseId: 1,
            licensee: licensee,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });
        LicensePermit.Permit memory permitB = permitA;
        permitB.licenseId = 2;

        assertTrue(harness.hashStruct(permitA) != harness.hashStruct(permitB));
    }
}