#!/usr/bin/env bash

  

# forge script script/DeployCore.s.sol:DeployCore \
#   --rpc-url unichain_sepolia \
#   --account myWallet \
#   --sender 0x5Ac521f6814c2D09188A6838e7CDBfe7aEaC0cf9 \
#   --broadcast


# poolManager: contract IPoolManager 0x00B036B58a818B1BC34d502D3fE730Db729e62AC
# licenseNFT: contract LicenseNFT 0x645C1b3E13EC2f36a414410679D0c71AAA8b48a4
# auction: contract EpochAuction 0xD2E89ec3ee53E017b9fE5755baD2D00622250a31
# hook: contract ArbLicenseHook 
# router: contract SwapRouter 0xcf3C40142ff5C31b71c59f5191AAe26093742F2a


forge verify-contract \
  --chain-id 1301 \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  --constructor-args $(cast abi-encode "constructor(address,address)" \
    0x00B036B58a818B1BC34d502D3fE730Db729e62AC \
    0x645C1b3E13EC2f36a414410679D0c71AAA8b48a4) \
  --watch \
  0xaE43461c96dBf1a14249e6fFA93Bc06AEE824088 \
  src/ArbLicenseHook.sol:ArbLicenseHook


forge verify-contract \
  --chain-id 1301 \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  --constructor-args $(cast abi-encode "constructor(address,address)" \
    0x00B036B58a818B1BC34d502D3fE730Db729e62AC \
    0x645C1b3E13EC2f36a414410679D0c71AAA8b48a4) \
  --watch \
  0xD2E89ec3ee53E017b9fE5755baD2D00622250a31 \
  src/EpochAuction.sol:EpochAuction

forge verify-contract \
  --chain-id 1301 \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  --constructor-args $(cast abi-encode "constructor(string,address)" \
    "https://example.com/license/{id}.json" \
    0x5Ac521f6814c2D09188A6838e7CDBfe7aEaC0cf9) \
  --watch \
  0x645C1b3E13EC2f36a414410679D0c71AAA8b48a4 \
  src/LicenseNFT.sol:LicenseNFT


forge verify-contract \
  --chain-id 1301 \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  --constructor-args $(cast abi-encode "constructor(address)" 0x00B036B58a818B1BC34d502D3fE730Db729e62AC) \
  --watch \
  0xcf3C40142ff5C31b71c59f5191AAe26093742F2a \
  src/SwapRouter.sol:SwapRouter