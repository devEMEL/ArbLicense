// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {EpochAuction} from "@arblicense/EpochAuction.sol";

import {ArbLicenseHook} from "@arblicense/ArbLicenseHook.sol";
import {LicenseNFT} from "@arblicense/LicenseNFT.sol";
import {SwapRouter} from "@arblicense/SwapRouter.sol";

/// @notice Deploys the full ArbLicenseHook stack in dependency order:
///         (PoolManager) -> LicenseNFT -> EpochAuction -> (wire auction into NFT) -> ArbLicenseHook -> SwapRouter.
///
/// Required env vars:
///   PRIVATE_KEY       - deployer key (used implicitly via --private-key / --account on the CLI)
///
/// Optional env vars:
///   POOL_MANAGER      - address of an EXISTING v4 PoolManager to reuse. If unset or
///                        address(0), this script deploys a fresh PoolManager instead
///                        (fine for local/testnet demos; on mainnet/L2s you almost
///                        certainly want to point at the canonical deployed instance
///                        rather than deploying your own — check the official v4
///                        deployment addresses for the target chain).
///   POOL_MANAGER_OWNER - owner of a freshly-deployed PoolManager (protocol-fee admin
///                        rights). Defaults to the deployer address if unset.
///   LICENSE_NFT_URI   - ERC-1155 metadata URI template for LicenseNFT (defaults to a placeholder)
///
/// Usage:
///   forge script script/DeployCore.s.sol:DeployCore \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast -vvvv
///
/// @dev Hook address mining: v4 encodes a hook's permitted callbacks in the low
///      bits of its deployed address, so ArbLicenseHook cannot be deployed with
///      a plain `new`. This script uses HookMiner to find a CREATE2 salt whose
///      resulting address has exactly the BEFORE_SWAP and BEFORE_SWAP_RETURNS_DELTA
///      bits set (matching getHookPermissions()), then deploys with that salt
///      through the canonical deterministic CREATE2 deployer. Foundry's
///      broadcaster routes any `new X{salt: s}(...)` call through that same
///      deployer automatically once a salt is present, so no manual low-level
///      call is needed here.
contract DeployCore is Script {
    /// @dev Canonical CREATE2 factory (Arachnid's deterministic deployment
    ///      proxy) present on essentially every EVM chain at this exact address.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run()
        external
        returns (
            IPoolManager poolManager,
            LicenseNFT licenseNFT,
            EpochAuction auction,
            ArbLicenseHook hook,
            SwapRouter router
        )
    {
        address existingPoolManager = vm.envOr("POOL_MANAGER", address(0));
        string memory nftUri = vm.envOr("LICENSE_NFT_URI", string("https://example.com/license/{id}.json"));

        vm.startBroadcast();
        address deployer = vm.envAddress("DEPLOYER");

        // 0. PoolManager: reuse an existing deployment if POOL_MANAGER was set,
        //    otherwise deploy a fresh one owned by the deployer (or
        //    POOL_MANAGER_OWNER if set). Deploying your own is normal for a
        //    local anvil chain or a from-scratch testnet demo; on a chain that
        //    already has a canonical v4 PoolManager you almost always want to
        //    set POOL_MANAGER instead of forking liquidity across two managers.
        if (existingPoolManager != address(0)) {
            poolManager = IPoolManager(existingPoolManager);
            console2.log("PoolManager     : (reused)", existingPoolManager);
        } else {
            address poolManagerOwner = vm.envAddress("DEPLOYER");
            poolManager = IPoolManager(address(new PoolManager(poolManagerOwner)));
            console2.log("PoolManager     : (deployed)", address(poolManager));
        }

        // 1. License NFT. Owner = deployer so we can call setAuction() next;
        //    consider transferring ownership afterward if that matters for your setup.
        licenseNFT = new LicenseNFT(nftUri, deployer);
        console2.log("LicenseNFT      :", address(licenseNFT));

        // 2. Auction. Needs the NFT address already deployed above.
        auction = new EpochAuction(poolManager, licenseNFT);
        console2.log("EpochAuction    :", address(auction));

        // 3. Wire the auction as the sole minter on the NFT.
        licenseNFT.setAuction(address(auction));
        console2.log("LicenseNFT.auction set to EpochAuction");

        // 4. Mine a salt for the hook's permission-flagged address, then deploy.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, licenseNFT);

        (address predictedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(ArbLicenseHook).creationCode, constructorArgs);

        hook = new ArbLicenseHook{salt: salt}(poolManager, licenseNFT);
        require(address(hook) == predictedHook, "DeployCore: mined hook address mismatch");
        console2.log("ArbLicenseHook  :", address(hook));

        // 5. Minimal demo/test swap router that forwards hookData untouched
        //    (needed so a caller can attach a signed LicensePermit).
        router = new SwapRouter(poolManager);
        console2.log("SwapRouter      :", address(router));

        vm.stopBroadcast();

        console2.log("---");
        console2.log("Next: run script/InitPool.s.sol with HOOK_ADDRESS =", address(hook));
    }
}