const { ethers } = require("hardhat")
const fs = require("fs")

async function main() {
  console.log("🚀 Deploying NFTVaultChain contracts...")

  // Get the deployer account
  const [deployer] = await ethers.getSigners()
  console.log("Deploying contracts with account:", deployer.address)

  const balance = await deployer.provider.getBalance(deployer.address)
  console.log("Account balance:", ethers.formatEther(balance), "ETH")

  // Deploy VaultCoin
  console.log("\n1. 🪙 Deploying VaultCoin...")
  const VaultCoin = await ethers.getContractFactory("VaultCoin")
  const vaultCoin = await VaultCoin.deploy()
  await vaultCoin.waitForDeployment()
  const vaultCoinAddress = await vaultCoin.getAddress()
  console.log("✅ VaultCoin deployed to:", vaultCoinAddress)

  // Deploy FiatGateway
  console.log("\n2. 💳 Deploying FiatGateway...")
  const FiatGateway = await ethers.getContractFactory("FiatGateway")
  const fiatGateway = await FiatGateway.deploy(vaultCoinAddress)
  await fiatGateway.waitForDeployment()
  const fiatGatewayAddress = await fiatGateway.getAddress()
  console.log("✅ FiatGateway deployed to:", fiatGatewayAddress)

  // Authorize FiatGateway to mint VaultCoin
  console.log("\n3. 🔐 Authorizing FiatGateway...")
  await vaultCoin.authorizeGateway(fiatGatewayAddress, true)
  await fiatGateway.authorizeProcessor(deployer.address, true)
  console.log("✅ FiatGateway authorized")

  // Deploy NFTVault
  console.log("\n4. 🖼️ Deploying NFTVault...")
  const NFTVault = await ethers.getContractFactory("NFTVault")
  const nftVault = await NFTVault.deploy(vaultCoinAddress)
  await nftVault.waitForDeployment()
  const nftVaultAddress = await nftVault.getAddress()
  console.log("✅ NFTVault deployed to:", nftVaultAddress)

  // Deploy VaultFactory (creates one VaultToken ERC-20 per fractional NFT)
  console.log("\n5. 🏭 Deploying VaultFactory...")
  const VaultFactory = await ethers.getContractFactory("VaultFactory")
  const vaultFactory = await VaultFactory.deploy()
  await vaultFactory.waitForDeployment()
  const vaultFactoryAddress = await vaultFactory.getAddress()
  console.log("✅ VaultFactory deployed to:", vaultFactoryAddress)

  // Deploy NFTContract (fractional NFTs backed by VaultTokens)
  console.log("\n6. 🖼️ Deploying NFTContract...")
  const NFTContract = await ethers.getContractFactory("NFTContract")
  const nftContract = await NFTContract.deploy(vaultFactoryAddress)
  await nftContract.waitForDeployment()
  const nftContractAddress = await nftContract.getAddress()
  console.log("✅ NFTContract deployed to:", nftContractAddress)

  // Deploy Marketplace
  // The Marketplace needs the NFTContract address at deployment so it can
  // look up the VaultToken for a tokenId. (Previously it used
  // NFTContract(msg.sender), which treated the caller as the contract and
  // made every marketplace call revert.)
  console.log("\n7. 🏪 Deploying Marketplace...")
  const Marketplace = await ethers.getContractFactory("Marketplace")
  const marketplace = await Marketplace.deploy(nftContractAddress)
  await marketplace.waitForDeployment()
  const marketplaceAddress = await marketplace.getAddress()
  console.log("✅ Marketplace deployed to:", marketplaceAddress)

  // Setup initial configuration
  console.log("\n8. ⚙️ Setting up initial configuration...")

  // Mint some VaultCoins to deployer for testing
  const mintAmount = ethers.parseEther("50000") // 50,000 VAULT tokens
  await vaultCoin.mint(deployer.address, mintAmount)
  console.log("✅ Minted 50,000 VAULT tokens to deployer")

  // Set reasonable fees
  await nftVault.setMintingFee(ethers.parseEther("5")) // 5 VAULT tokens
  await nftVault.setPlatformFeePercentage(250) // 2.5%
  await marketplace.setPlatformFee(250) // 2.5%
  console.log("✅ Platform fees configured")

  console.log("\n🎉 === Deployment Summary ===")
  console.log("VaultCoin:", vaultCoinAddress)
  console.log("FiatGateway:", fiatGatewayAddress)
  console.log("NFTVault:", nftVaultAddress)
  console.log("VaultFactory:", vaultFactoryAddress)
  console.log("NFTContract:", nftContractAddress)
  console.log("Marketplace:", marketplaceAddress)
  console.log("Deployer:", deployer.address)

  // Save deployment addresses
  const deploymentInfo = {
    network: process.env.HARDHAT_NETWORK,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    contracts: {
      vaultCoin: vaultCoinAddress,
      fiatGateway: fiatGatewayAddress,
      nftVault: nftVaultAddress,
      vaultFactory: vaultFactoryAddress,
      nftContract: nftContractAddress,
      marketplace: marketplaceAddress,
    },
    deployer: deployer.address,
    deployedAt: new Date().toISOString(),
    blockNumber: await ethers.provider.getBlockNumber(),
  }

  const filename = `deployment-${process.env.HARDHAT_NETWORK}.json`
  fs.writeFileSync(filename, JSON.stringify(deploymentInfo, null, 2))
  console.log(`\n📄 Deployment addresses saved to ${filename}`)

  // Generate frontend config
  const frontendConfig = {
    NEXT_PUBLIC_CHAIN_ID: deploymentInfo.chainId,
    NEXT_PUBLIC_VAULT_COIN_ADDRESS: vaultCoinAddress,
    NEXT_PUBLIC_FIAT_GATEWAY_ADDRESS: fiatGatewayAddress,
    NEXT_PUBLIC_NFT_VAULT_ADDRESS: nftVaultAddress,
    NEXT_PUBLIC_VAULT_FACTORY_ADDRESS: vaultFactoryAddress,
    NEXT_PUBLIC_NFT_CONTRACT_ADDRESS: nftContractAddress,
    NEXT_PUBLIC_MARKETPLACE_ADDRESS: marketplaceAddress,
  }

  fs.writeFileSync(
    ".env.local",
    Object.entries(frontendConfig)
      .map(([key, value]) => `${key}=${value}`)
      .join("\n"),
  )
  console.log("📄 Frontend environment variables saved to .env.local")

  if (process.env.HARDHAT_NETWORK !== "hardhat" && process.env.HARDHAT_NETWORK !== "localhost") {
    console.log("\n⏳ Waiting for block confirmations...")
    await vaultCoin.deploymentTransaction().wait(5)

    console.log("\n🔍 Verifying contracts on Etherscan...")
    try {
      const hre = require("hardhat") // Declare hre variable
      await hre.run("verify:verify", {
        address: vaultCoinAddress,
        constructorArguments: [],
      })

      await hre.run("verify:verify", {
        address: fiatGatewayAddress,
        constructorArguments: [vaultCoinAddress],
      })

      await hre.run("verify:verify", {
        address: nftVaultAddress,
        constructorArguments: [vaultCoinAddress],
      })

      await hre.run("verify:verify", {
        address: vaultFactoryAddress,
        constructorArguments: [],
      })

      await hre.run("verify:verify", {
        address: nftContractAddress,
        constructorArguments: [vaultFactoryAddress],
      })

      await hre.run("verify:verify", {
        address: marketplaceAddress,
        constructorArguments: [nftContractAddress],
      })

      console.log("✅ All contracts verified on Etherscan")
    } catch (error) {
      console.log("⚠️ Verification failed:", error.message)
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
