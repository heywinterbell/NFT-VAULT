const { expect } = require("chai")
const { ethers } = require("hardhat")

describe("AuctionSystem — share settlement & escrow fix", () => {
  let vaultCoin, nftVault, auctionSystem
  let owner, seller, bidder1, bidder2
  const TOTAL_SHARES = 1000
  const MINTING_FEE = ethers.parseEther("10")

  beforeEach(async () => {
    ;[owner, seller, bidder1, bidder2] = await ethers.getSigners()

    const VaultCoin = await ethers.getContractFactory("VaultCoin")
    vaultCoin = await VaultCoin.deploy()
    await vaultCoin.waitForDeployment()

    const NFTVault = await ethers.getContractFactory("NFTVault")
    nftVault = await NFTVault.deploy(await vaultCoin.getAddress())
    await nftVault.waitForDeployment()

    const AuctionSystem = await ethers.getContractFactory("AuctionSystem")
    auctionSystem = await AuctionSystem.deploy(
      await vaultCoin.getAddress(),
      await nftVault.getAddress(),
    )
    await auctionSystem.waitForDeployment()

    // Authorize the AuctionSystem to move shares in NFTVault (escrow /
    // settlement). Without this, createAuction cannot escrow.
    await nftVault.setShareManager(await auctionSystem.getAddress(), true)

    // Give the seller VAULT for the minting fee, and bidders VAULT to bid with.
    await vaultCoin.mint(seller.address, ethers.parseEther("10000"))
    await vaultCoin.mint(bidder1.address, ethers.parseEther("10000"))
    await vaultCoin.mint(bidder2.address, ethers.parseEther("10000"))

    // Mint an NFT with 0 shares listed, so the seller (creator) holds
    // all 1000 shares and can auction some of them.
    await vaultCoin.connect(seller).approve(await nftVault.getAddress(), MINTING_FEE)
    await nftVault
      .connect(seller)
      .mintNFT("QmTestHash", "Test NFT", "desc", 500, TOTAL_SHARES, 0, 0)
  })

  const tokenId = 0

  async function createAuction(shares = 100, startingBid = ethers.parseEther("1")) {
    const duration = 24 * 60 * 60 // 24h
    const tx = await auctionSystem
      .connect(seller)
      .createAuction(tokenId, shares, startingBid, duration)
    await tx.wait()
    return 0 // first auctionId
  }

  async function placeBid(auctionId, bidder, amount) {
    await vaultCoin.connect(bidder).approve(await auctionSystem.getAddress(), amount)
    await auctionSystem.connect(bidder).placeBid(auctionId, amount)
  }

  it("escrows the seller's shares when an auction is created", async () => {
    expect(await nftVault.getShareHolderBalance(tokenId, seller.address)).to.equal(TOTAL_SHARES)

    const auctionId = await createAuction(100)

    // Seller's shares moved into the AuctionSystem (escrow).
    expect(await nftVault.getShareHolderBalance(tokenId, seller.address)).to.equal(
      TOTAL_SHARES - 100,
    )
    expect(await nftVault.getShareHolderBalance(tokenId, await auctionSystem.getAddress())).to.equal(
      100,
    )

    const auction = await auctionSystem.auctions(auctionId)
    expect(auction.seller).to.equal(seller.address)
    expect(auction.shares).to.equal(100)
    expect(auction.active).to.be.true
  })

  it("reverts creating an auction for more shares than the seller holds", async () => {
    await expect(
      auctionSystem
        .connect(seller)
        .createAuction(tokenId, TOTAL_SHARES + 1, ethers.parseEther("1"), 24 * 60 * 60),
    ).to.be.revertedWith("Not enough shares to auction")
  })

  it("settles with a winner: winner gets the shares, seller gets paid minus the 2.5% fee", async () => {
    const auctionId = await createAuction(100)
    const bidAmount = ethers.parseEther("2")

    await placeBid(auctionId, bidder1, bidAmount)

    const sellerBalanceBefore = await vaultCoin.balanceOf(seller.address)
    const ownerBalanceBefore = await vaultCoin.balanceOf(owner.address)

    // Fast-forward past the auction end.
    await ethers.provider.send("evm_increaseTime", [25 * 60 * 60])
    await ethers.provider.send("evm_mine")

    await expect(auctionSystem.settleAuction(auctionId)).to.emit(auctionSystem, "AuctionSettled")

    // Winner received the shares (previously they paid and got nothing).
    expect(await nftVault.getShareHolderBalance(tokenId, bidder1.address)).to.equal(100)
    expect(await nftVault.getShareHolderBalance(tokenId, await auctionSystem.getAddress())).to.equal(0)

    // Seller got the bid minus the 2.5% platform fee; owner got the fee.
    const fee = (bidAmount * 250n) / 10000n
    expect(await vaultCoin.balanceOf(seller.address)).to.equal(sellerBalanceBefore + (bidAmount - fee))
    expect(await vaultCoin.balanceOf(owner.address)).to.equal(ownerBalanceBefore + fee)
  })

  it("refunds the previous bidder when outbid", async () => {
    const auctionId = await createAuction(100)

    await placeBid(auctionId, bidder1, ethers.parseEther("2"))
    const bidder1AfterFirstBid = await vaultCoin.balanceOf(bidder1.address)

    await placeBid(auctionId, bidder2, ethers.parseEther("3"))

    // bidder1 got their 2 VAULT back.
    expect(await vaultCoin.balanceOf(bidder1.address)).to.equal(bidder1AfterFirstBid + ethers.parseEther("2"))

    const auction = await auctionSystem.auctions(auctionId)
    expect(auction.currentBidder).to.equal(bidder2.address)
    expect(auction.currentBid).to.equal(ethers.parseEther("3"))
  })

  it("returns the escrowed shares to the seller when an auction with no bids is settled", async () => {
    const auctionId = await createAuction(100)

    await ethers.provider.send("evm_increaseTime", [25 * 60 * 60])
    await ethers.provider.send("evm_mine")

    await expect(auctionSystem.settleAuction(auctionId)).to.emit(auctionSystem, "AuctionCancelled")

    expect(await nftVault.getShareHolderBalance(tokenId, seller.address)).to.equal(TOTAL_SHARES)
    expect(await nftVault.getShareHolderBalance(tokenId, await auctionSystem.getAddress())).to.equal(0)
  })

  it("returns the escrowed shares to the seller on cancel", async () => {
    const auctionId = await createAuction(100)

    await expect(auctionSystem.connect(seller).cancelAuction(auctionId)).to.emit(
      auctionSystem,
      "AuctionCancelled",
    )

    expect(await nftVault.getShareHolderBalance(tokenId, seller.address)).to.equal(TOTAL_SHARES)
    expect(await nftVault.getShareHolderBalance(tokenId, await auctionSystem.getAddress())).to.equal(0)
  })

  it("reverts cancel when there is an active bid (bidder funds are protected)", async () => {
    const auctionId = await createAuction(100)
    await placeBid(auctionId, bidder1, ethers.parseEther("2"))

    await expect(auctionSystem.connect(seller).cancelAuction(auctionId)).to.be.revertedWith(
      "Cannot cancel with active bids",
    )
  })

  it("reverts when a non-manager tries to move shares directly in NFTVault", async () => {
    await expect(
      nftVault.connect(bidder1).transferShares(tokenId, seller.address, bidder1.address, 10),
    ).to.be.revertedWith("Not an authorized share manager")
  })

  it("reverts when a non-owner tries to authorize a share manager", async () => {
    await expect(
      nftVault.connect(bidder1).setShareManager(bidder1.address, true),
    ).to.be.revertedWith("Ownable: caller is not the owner")
  })
})
