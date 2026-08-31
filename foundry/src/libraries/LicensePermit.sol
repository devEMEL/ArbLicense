// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice EIP-712 permit verification for arb-license proofs passed in a swap's
///         hookData. Lets a licensee delegate execution to their own bots/routers
///         without relying on msg.sender or tx.origin, which break for
///         aggregators and smart contract wallets.
library LicensePermit {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("LicensePermit(uint256 licenseId,address licensee,uint256 nonce,uint256 deadline)");

    struct Permit {
        uint256 licenseId;
        address licensee;
        uint256 nonce;
        uint256 deadline;
    }

    function hashStruct(Permit memory permit) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(PERMIT_TYPEHASH, permit.licenseId, permit.licensee, permit.nonce, permit.deadline)
        );
    }

    /// @dev Reverts if the permit is expired. Returns address(0) recovery is not
    ///      possible with OZ's ECDSA (it reverts on malformed signatures), so a
    ///      malformed sig will revert the whole swap rather than silently
    ///      falling through to the taxed path — decide if that's the UX you want.
    function verify(Permit memory permit, bytes32 domainSeparator, bytes memory signature)
        internal
        view
        returns (address signer)
    {
        require(block.timestamp <= permit.deadline, "LicensePermit: expired");
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, hashStruct(permit)));
        signer = ECDSA.recover(digest, signature);
    }
}