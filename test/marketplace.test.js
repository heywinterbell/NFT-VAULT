const { expect } = require("chai")
const { ethers } = require("hardhat")

describe("Marketplace — NFT contract address fix", () => {
  let vaultFactory, nftContract, marketplace
  let owner, creator, buyer
  const TOTAL_SHARES = 1000
  const PRICE_PER_SHARE = ethers.parseEther("0.01")

  beforeEach(async () => {
    ;[owner, creator, buyer] = await ethers.getSigners()

    const VaultFactory = await ethers.getContractFactory("VaultFactory")
    vaultFactory = await VaultFactory.deploy()
    await vaultFactory.waitForDeployment()

    const NFTContract = await ethers.getContractFactory("NFTContract")
    nftContract = await NFTContract.deploy(await vaultFactory.getAddress())
    await nftContract.waitForDeployment()

    const Marketplace = await ethers.getContractFactory("Marketplace")
    marketplace = await Marketplace.deploy(await nftContract.getAddress())
    await marketplace.waitForDeployment()

    // Mint an NFT as the creator (tokenId 0). The creator holds the
    // VaultTokens for it, so they can list shares on the marketplace.
    await nftContract
      .connect(creator)
      .mintNFT("ipfs://QmTestHash", TOTAL_SHARES, 0, PRICE_PER_SHARE)
  })

  async function vaultTokenFor(tokenId) {
    const vaultAddress = await nftContract.getVaultContract(tokenId)
    return ethers.getContractAt("VaultToken", vaultAddress)
  }

  it("stores the NFT contract address immutably at deployment", async () => {
    expect(await marketplace.nftContract()).to.equal(await nftContract.getAddress())
  })

  it("reverts deployment with a zero NFT contract address", async () => {
    const Marketplace = await ethers.getContractFactory("Marketplace")
    await expect(Marketplace.deploy(ethers.ZeroAddress)).to.be.revertedWith(
      "NFT contract address required",
    )
  })

  it("lists shares: escrows VaultTokens and records the listing (previously reverted)", async () => {
    const tokenId = 0
    const vaultToken = await vaultTokenFor(tokenId)
    const sharesToList = 100

    await vaultToken.connect(creator).approve(await marketplace.getAddress(), sharesToList)

    await expect(
      marketplace.connect(creator).listNFTShares(tokenId, sharesToList, PRICE_PER_SHARE),
    ).to.emit(marketplace, "SharesListed")

    // Tokens moved into marketplace escrow.
    expect(await vaultToken.balanceOf(await marketplace.getAddress())).to.equal(sharesToList)
    expect(await vaultToken.balanceOf(creator.address)).to.equal(TOTAL_SHARES - sharesToList)

    const [seller, shares, price, active] = await marketplace.getActiveListing(tokenId)
    expect(seller).to.equal(creator.address)
    expect(shares).to.equal(sharesToList)
    expect(price).to.equal(PRICE_PER_SHARE)
    expect(active).to.be.true

    expect(await marketplace.getAllActiveListings()).to.deep.equal([0n])
  })

  it("buys a listing: buyer gets VaultTokens, seller gets paid minus the 2.5% fee", async () => {
    const tokenId = 0
    const vaultToken = await vaultTokenFor(tokenId)
    const sharesToList = 100

    await vaultToken.connect(creator).approve(await marketplace.getAddress(), sharesToList)
    await marketplace.connect(creator).listNFTShares(tokenId, sharesToList, PRICE_PER_SHARE)

    const totalCost = PRICE_PER_SHARE * BigInt(sharesToList)
    const fee = (totalCost * 250n) / 10000n
    const sellerAmount = totalCost - fee

    const sellerBalanceBefore = await ethers.provider.getBalance(creator.address)
    const ownerBalanceBefore = await ethers.provider.getBalance(owner.address)

    await expect(marketplace.connect(buyer).buyShares(tokenId, { value: totalCost })).to.emit(
      marketplace,
      "SharesPurchased",
    )

    expect(await vaultToken.balanceOf(buyer.address)).to.equal(sharesToList)
    expect(await vaultToken.balanceOf(await marketplace.getAddress())).to.equal(0)

    const sellerBalanceAfter = await ethers.provider.getBalance(creator.address)
    expect(sellerBalanceAfter - sellerBalanceBefore).to.equal(sellerAmount)
    const ownerBalanceAfter = await ethers.provider.getBalance(owner.address)
    expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(fee)

    // Listing is closed after purchase.
    const [, , , active] = await marketplace.getActiveListing(tokenId)
    expect(active).to.be.false
    expect(await marketplace.getAllActiveListings()).to.deep.equal([])
  })

  it("refunds excess ETH on purchase", async () => {
    const tokenId = 0
    const vaultToken = await vaultTokenFor(tokenId)
    const sharesToList = 50

    await vaultToken.connect(creator).approve(await marketplace.getAddress(), sharesToList)
    await marketplace.connect(creator).listNFTShares(tokenId, sharesToList, PRICE_PER_SHARE)

    const totalCost = PRICE_PER_SHARE * BigInt(sharesToList)
    const overpay = ethers.parseEther("0.5")
    const buyerBalanceBefore = await ethers.provider.getBalance(buyer.address)

    const tx = await marketplace
      .connect(buyer)
      .buyShares(tokenId, { value: totalCost + overpay })
    const receipt = await tx.wait()
    const gasCost = receipt.gasUsed * receipt.gasPrice

    const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address)
    expect(buyerBalanceBefore - buyerBalanceAfter - gasCost).to.equal(totalCost)
  })

  it("cancels a listing and returns the escrowed VaultTokens to the seller", async () => {
    const tokenId = 0
    const vaultToken = await vaultTokenFor(tokenId)
    const sharesToList = 100

    await vaultToken.connect(creator).approve(await marketplace.getAddress(), sharesToList)
    await marketplace.connect(creator).listNFTShares(tokenId, sharesToList, PRICE_PER_SHARE)

    await expect(marketplace.connect(creator).cancelListing(tokenId)).to.emit(
      marketplace,
      "ListingCancelled",
    )

    expect(await vaultToken.balanceOf(creator.address)).to.equal(TOTAL_SHARES)
    expect(await vaultToken.balanceOf(await marketplace.getAddress())).to.equal(0)
    const [, , , active] = await marketplace.getActiveListing(tokenId)
    expect(active).to.be.false
  })

  it("reverts when the seller tries to buy their own listing", async () => {
    const tokenId = 0
    const vaultToken = await vaultTokenFor(tokenId)

    await vaultToken.connect(creator).approve(await marketplace.getAddress(), 10)
    await marketplace.connect(creator).listNFTShares(tokenId, 10, PRICE_PER_SHARE)

    await expect(
      marketplace.connect(creator).buyShares(tokenId, { value: PRICE_PER_SHARE * 10n }),
    ).to.be.revertedWith("Cannot buy your own shares")
  })

  it("reverts when buying with insufficient ETH", async () => {
    const tokenId = 0
    const vaultToken = await vaultTokenFor(tokenId)

    await vaultToken.connect(creator).approve(await marketplace.getAddress(), 10)
    await marketplace.connect(creator).listNFTShares(tokenId, 10, PRICE_PER_SHARE)

    await expect(
      marketplace.connect(buyer).buyShares(tokenId, { value: ethers.parseEther("0.001") }),
    ).to.be.revertedWith("Insufficient payment")
  })

  it("reverts when a non-seller tries to cancel a listing", async () => {
    const tokenId = 0
    const vaultToken = await vaultTokenFor(tokenId)

    await vaultToken.connect(creator).approve(await marketplace.getAddress(), 10)
    await marketplace.connect(creator).listNFTShares(tokenId, 10, PRICE_PER_SHARE)

    await expect(marketplace.connect(buyer).cancelListing(tokenId)).to.be.revertedWith(
      "Only seller can cancel",
    )
  })

  it("reverts listing without prior VaultToken approval", async () => {
    await expect(
      marketplace.connect(creator).listNFTShares(0, 10, PRICE_PER_SHARE),
    ).to.be.revertedWith("ERC20: insufficient allowance")
  })
})
