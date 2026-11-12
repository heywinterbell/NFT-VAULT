const { expect } = require("chai")
const { ethers } = require("hardhat")

describe("NFTContract — buyShares escrow fix", () => {
  let vaultFactory, nftContract
  let owner, creator, buyer
  const TOTAL_SHARES = 1000
  const SHARES_TO_LIST = 300
  const PRICE_PER_SHARE = ethers.parseEther("0.01") // 0.01 ETH per share

  beforeEach(async () => {
    ;[owner, creator, buyer] = await ethers.getSigners()

    const VaultFactory = await ethers.getContractFactory("VaultFactory")
    vaultFactory = await VaultFactory.deploy()
    await vaultFactory.waitForDeployment()

    const NFTContract = await ethers.getContractFactory("NFTContract")
    nftContract = await NFTContract.deploy(await vaultFactory.getAddress())
    await nftContract.waitForDeployment()
  })

  async function mintNFT(sharesToList = SHARES_TO_LIST) {
    const tx = await nftContract
      .connect(creator)
      .mintNFT("ipfs://QmTestHash", TOTAL_SHARES, sharesToList, PRICE_PER_SHARE)
    await tx.wait()
    return 0 // first tokenId
  }

  async function vaultTokenFor(tokenId) {
    const vaultAddress = await nftContract.getVaultContract(tokenId)
    return ethers.getContractAt("VaultToken", vaultAddress)
  }

  it("mints the VaultToken supply to the NFT contract (escrow), not the creator", async () => {
    const tokenId = await mintNFT()
    const vaultToken = await vaultTokenFor(tokenId)

    // Listed shares stay in the NFT contract (escrow for buyers).
    expect(await vaultToken.balanceOf(await nftContract.getAddress())).to.equal(SHARES_TO_LIST)
    // Retained shares go to the creator.
    expect(await vaultToken.balanceOf(creator.address)).to.equal(TOTAL_SHARES - SHARES_TO_LIST)
    // Total supply is exactly totalShares — nothing minted elsewhere.
    expect(await vaultToken.totalSupply()).to.equal(TOTAL_SHARES)
  })

  it("lets a buyer buy listed shares (previously reverted: contract held 0 tokens)", async () => {
    const tokenId = await mintNFT()
    const vaultToken = await vaultTokenFor(tokenId)

    const sharesToBuy = 50
    const totalCost = PRICE_PER_SHARE * BigInt(sharesToBuy)
    const creatorBalanceBefore = await ethers.provider.getBalance(creator.address)

    await expect(
      nftContract.connect(buyer).buyShares(tokenId, sharesToBuy, { value: totalCost }),
    ).to.emit(nftContract, "SharesPurchased")

    // Buyer received the VaultTokens.
    expect(await vaultToken.balanceOf(buyer.address)).to.equal(sharesToBuy)
    // Contract escrow decreased.
    expect(await vaultToken.balanceOf(await nftContract.getAddress())).to.equal(
      SHARES_TO_LIST - sharesToBuy,
    )
    // Available shares decreased.
    const [, availableShares] = await nftContract.getTokenShares(tokenId)
    expect(availableShares).to.equal(SHARES_TO_LIST - sharesToBuy)
    // Creator was paid.
    const creatorBalanceAfter = await ethers.provider.getBalance(creator.address)
    expect(creatorBalanceAfter - creatorBalanceBefore).to.equal(totalCost)
  })

  it("refunds excess ETH and sells out the listing when all shares are bought", async () => {
    const tokenId = await mintNFT()
    const vaultToken = await vaultTokenFor(tokenId)

    const totalCost = PRICE_PER_SHARE * BigInt(SHARES_TO_LIST)
    const overpay = ethers.parseEther("1")
    const buyerBalanceBefore = await ethers.provider.getBalance(buyer.address)

    const tx = await nftContract
      .connect(buyer)
      .buyShares(tokenId, SHARES_TO_LIST, { value: totalCost + overpay })
    const receipt = await tx.wait()
    const gasCost = receipt.gasUsed * receipt.gasPrice

    expect(await vaultToken.balanceOf(buyer.address)).to.equal(SHARES_TO_LIST)
    expect(await vaultToken.balanceOf(await nftContract.getAddress())).to.equal(0)
    // Listing is closed once sold out. getListingInfo returns
    // (availableShares, pricePerShare, isListed).
    const [availableShares, , isListed] = await nftContract.getListingInfo(tokenId)
    expect(availableShares).to.equal(0)
    expect(isListed).to.be.false
    // Buyer only paid totalCost (overpayment refunded).
    const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address)
    expect(buyerBalanceBefore - buyerBalanceAfter - gasCost).to.equal(totalCost)
  })

  it("lets the creator list more of their retained shares (escrowed via transferFrom)", async () => {
    const tokenId = await mintNFT()
    const vaultToken = await vaultTokenFor(tokenId)

    const extraShares = 100
    const newPrice = ethers.parseEther("0.02")

    // Creator must approve the NFT contract to escrow their tokens.
    await vaultToken.connect(creator).approve(await nftContract.getAddress(), extraShares)

    await expect(nftContract.connect(creator).listShares(tokenId, extraShares, newPrice)).to.emit(
      nftContract,
      "SharesListed",
    )

    // Tokens moved into escrow, available shares increased (not overwritten).
    expect(await vaultToken.balanceOf(await nftContract.getAddress())).to.equal(
      SHARES_TO_LIST + extraShares,
    )
    expect(await vaultToken.balanceOf(creator.address)).to.equal(
      TOTAL_SHARES - SHARES_TO_LIST - extraShares,
    )
    const [, availableShares] = await nftContract.getTokenShares(tokenId)
    expect(availableShares).to.equal(SHARES_TO_LIST + extraShares)

    // The newly listed shares can be bought at the new price.
    const totalCost = newPrice * BigInt(extraShares)
    await nftContract.connect(buyer).buyShares(tokenId, extraShares, { value: totalCost })
    expect(await vaultToken.balanceOf(buyer.address)).to.equal(extraShares)
  })

  it("reverts listShares without prior approval (escrow cannot pull unapproved tokens)", async () => {
    const tokenId = await mintNFT()
    await expect(
      nftContract.connect(creator).listShares(tokenId, 10, PRICE_PER_SHARE),
    ).to.be.revertedWith("ERC20: insufficient allowance")
  })

  it("reverts when buying more shares than are listed", async () => {
    const tokenId = await mintNFT()
    const totalCost = PRICE_PER_SHARE * BigInt(SHARES_TO_LIST + 1)
    await expect(
      nftContract.connect(buyer).buyShares(tokenId, SHARES_TO_LIST + 1, { value: totalCost }),
    ).to.be.revertedWith("Not enough shares available")
  })

  it("reverts when buying with insufficient ETH", async () => {
    const tokenId = await mintNFT()
    await expect(
      nftContract.connect(buyer).buyShares(tokenId, 10, { value: ethers.parseEther("0.001") }),
    ).to.be.revertedWith("Insufficient payment")
  })

  it("mints with zero listed shares: all shares go to the creator, none escrowed", async () => {
    const tokenId = await mintNFT(0)
    const vaultToken = await vaultTokenFor(tokenId)

    expect(await vaultToken.balanceOf(creator.address)).to.equal(TOTAL_SHARES)
    expect(await vaultToken.balanceOf(await nftContract.getAddress())).to.equal(0)
    const [availableShares, , isListed] = await nftContract.getListingInfo(tokenId)
    expect(availableShares).to.equal(0)
    expect(isListed).to.be.false
  })
})
