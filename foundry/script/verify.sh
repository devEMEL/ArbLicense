#!/usr/bin/env bash

  

# forge script script/DeployCore.s.sol:DeployCore \
#   --rpc-url unichain_sepolia \
#   --account myWallet \
#   --sender 0x5Ac521f6814c2D09188A6838e7CDBfe7aEaC0cf9 \
#   --broadcast


# poolManager: contract IPoolManager 0x00B036B58a818B1BC34d502D3fE730Db729e62AC
# licenseNFT: contract LicenseNFT 0x277d57385768235e93f0B3fC67b48563Eb4A5a8c
# auction: contract EpochAuction 0x58228Bb87820aF037776182e78B41eb4fF82119d
# hook: contract ArbLicenseHook 0xC758922D63D836e9fd3e11418dB340dabdB5c088
# router: contract SwapRouter 0x57C544AAcfBa98b299361C47DDAe391720Ba4aec


forge verify-contract \
  --chain-id 1301 \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  --constructor-args $(cast abi-encode "constructor(address,address)" \
    0x00B036B58a818B1BC34d502D3fE730Db729e62AC \
    0x277d57385768235e93f0B3fC67b48563Eb4A5a8c) \
  --watch \
  0xC758922D63D836e9fd3e11418dB340dabdB5c088 \
  src/ArbLicenseHook.sol:ArbLicenseHook


forge verify-contract \
  --chain-id 1301 \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  --constructor-args $(cast abi-encode "constructor(address,address)" \
    0x00B036B58a818B1BC34d502D3fE730Db729e62AC \
    0x277d57385768235e93f0B3fC67b48563Eb4A5a8c) \
  --watch \
  0x58228Bb87820aF037776182e78B41eb4fF82119d \
  src/EpochAuction.sol:EpochAuction

forge verify-contract \
  --chain-id 1301 \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  --constructor-args $(cast abi-encode "constructor(string,address)" \
    "https://example.com/license/{id}.json" \
    0x5Ac521f6814c2D09188A6838e7CDBfe7aEaC0cf9) \
  --watch \
  0x277d57385768235e93f0B3fC67b48563Eb4A5a8c \
  src/LicenseNFT.sol:LicenseNFT


forge verify-contract \
  --chain-id 1301 \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  --constructor-args $(cast abi-encode "constructor(address)" 0x00B036B58a818B1BC34d502D3fE730Db729e62AC) \
  --watch \
  0x57C544AAcfBa98b299361C47DDAe391720Ba4aec \
  src/SwapRouter.sol:SwapRouter