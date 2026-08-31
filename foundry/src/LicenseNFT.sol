// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice The arb-license token. id = LicenseId.pack(poolId, epoch). Transferable
///         by default (standard ERC-1155 transfer), so a losing bidder can still
///         buy in mid-epoch on a secondary market. Minting is gated to the
///         EpochAuction contract only.
contract LicenseNFT is ERC1155, Ownable {
    address public auction;

    event AuctionUpdated(address indexed newAuction);

    error NotAuction();

    modifier onlyAuction() {
        if (msg.sender != auction) revert NotAuction();
        _;
    }

    constructor(string memory uri_, address initialOwner) ERC1155(uri_) Ownable(initialOwner) {}

    /// @dev One-time (or updatable) wiring to the auction contract. Kept
    ///      owner-controlled rather than immutable in case you redeploy the
    ///      auction logic without redeploying the NFT / losing existing licenses.
    function setAuction(address _auction) external onlyOwner {
        auction = _auction;
        emit AuctionUpdated(_auction);
    }

    function mint(address to, uint256 id, uint256 amount) external onlyAuction {
        _mint(to, id, amount, "");
    }
}