const { expect } = require("chai")
const { ethers } = require("hardhat")

describe("Governance — execution & proposal threshold fix", () => {
  let vaultCoin, nftVault, governance
  let owner, proposer, voter
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  beforeEach(async () => {
    ;[owner, proposer, voter] = await ethers.getSigners()

    const VaultCoin = await ethers.getContractFactory("VaultCoin")
    vaultCoin = await VaultCoin.deploy()
    await vaultCoin.waitForDeployment()

    const NFTVault = await ethers.getContractFactory("NFTVault")
    nftVault = await NFTVault.deploy(await vaultCoin.getAddress())
    await nftVault.waitForDeployment()

    const Governance = await ethers.getContractFactory("Governance")
    governance = await Governance.deploy(
      await vaultCoin.getAddress(),
      await nftVault.getAddress(),
    )
    await governance.waitForDeployment()

    // Governance must own the NFTVault for execution to succeed.
    await nftVault.transferOwnership(await governance.getAddress())

    // Proposer holds 1,000 VAULT -> sqrt(1000) = 31 voting power,
    // above the new threshold of 10. (Previously the threshold was
    // 1000 voting power = 1,000,000 VAULT, unreachable.)
    await vaultCoin.mint(proposer.address, ethers.parseEther("1000"))
    // Voter holds 100 VAULT -> sqrt(100) = 10 voting power.
    await vaultCoin.mint(voter.address, ethers.parseEther("100"))
  })

  function encodeValue(value) {
    return abiCoder.encode(["uint256"], [value])
  }

  async function passProposal(proposalId) {
    // Proposer + voter both vote For (31 + 10 = 41 voting power).
    await governance.connect(proposer).vote(proposalId, 1) // VoteType.For
    await governance.connect(voter).vote(proposalId, 1)
    // The deployer holds 1,000,000 VAULT (1,000 voting power), so the
    // 10% quorum is ~104. The proposer + voter alone (41) cannot reach
    // it — the deployer must also vote For.
    await governance.connect(owner).vote(proposalId, 1)
    // Fast-forward past the 7-day voting period + 2-day execution delay.
    await ethers.provider.send("evm_increaseTime", [9 * 24 * 60 * 60 + 60])
    await ethers.provider.send("evm_mine")
    expect(await governance.getProposalState(proposalId)).to.equal(2) // Succeeded
  }

  it("lets a user with 1,000 VAULT create a proposal (previously impossible)", async () => {
    expect(await vaultCoin.votingPower(proposer.address)).to.equal(31)

    const tx = await governance
      .connect(proposer)
      .createProposal("Lower mint fee", "Reduce the minting fee to 5 VAULT", 0, encodeValue(ethers.parseEther("5")))
    await expect(tx).to.emit(governance, "ProposalCreated")

    const proposal = await governance.proposals(0)
    expect(proposal.proposer).to.equal(proposer.address)
    expect(proposal.title).to.equal("Lower mint fee")
  })

  it("reverts proposal creation when voting power is below the threshold", async () => {
    // A fresh user with only the 20-VAULT bonus has sqrt(20) = 4 power.
    const [, , , newcomer] = await ethers.getSigners()
    await vaultCoin.connect(newcomer).registerUser(newcomer.address)
    expect(await vaultCoin.votingPower(newcomer.address)).to.equal(4)

    await expect(
      governance
        .connect(newcomer)
        .createProposal("Test", "desc", 0, encodeValue(ethers.parseEther("5"))),
    ).to.be.revertedWith("Insufficient voting power")
  })

  it("executes a ChangeMintingFee proposal and actually changes the fee", async () => {
    expect(await nftVault.mintingFee()).to.equal(ethers.parseEther("10"))

    await governance
      .connect(proposer)
      .createProposal("Lower mint fee", "Reduce the minting fee to 5 VAULT", 0, encodeValue(ethers.parseEther("5")))
    await passProposal(0)

    await expect(governance.executeProposal(0)).to.emit(governance, "ProposalExecuted")
    expect(await nftVault.mintingFee()).to.equal(ethers.parseEther("5"))
    expect(await governance.getProposalState(0)).to.equal(4) // Executed
  })

  it("executes a ChangePlatformFee proposal and actually changes the fee", async () => {
    expect(await nftVault.platformFeePercentage()).to.equal(250)

    await governance
      .connect(proposer)
      .createProposal("Raise platform fee", "Raise the platform fee to 5%", 1, encodeValue(500))
    await passProposal(0)

    await governance.executeProposal(0)
    expect(await nftVault.platformFeePercentage()).to.equal(500)
  })

  it("executes a ChangeRoyaltyLimit proposal and actually changes the max royalty", async () => {
    expect(await nftVault.maxRoyaltyPercentage()).to.equal(1000)

    await governance
      .connect(proposer)
      .createProposal("Lower royalty cap", "Cap royalties at 5%", 2, encodeValue(500))
    await passProposal(0)

    await governance.executeProposal(0)
    expect(await nftVault.maxRoyaltyPercentage()).to.equal(500)

    // The new cap is enforced on mint: a 10% royalty now reverts.
    const [, , creator] = await ethers.getSigners()
    await vaultCoin.mint(creator.address, ethers.parseEther("100"))
    await vaultCoin.connect(creator).approve(await nftVault.getAddress(), ethers.parseEther("5"))
    await expect(
      nftVault.connect(creator).mintNFT("QmHash", "T", "d", 1000, 100, 0, 0),
    ).to.be.revertedWith("Royalty exceeds maximum")
  })

  it("reverts execution before the voting period + delay have passed", async () => {
    await governance
      .connect(proposer)
      .createProposal("Lower mint fee", "desc", 0, encodeValue(ethers.parseEther("5")))
    await governance.connect(proposer).vote(0, 1)

    await expect(governance.executeProposal(0)).to.be.revertedWith(
      "Proposal not ready for execution",
    )
  })

  it("marks a proposal Failed when votes do not reach quorum or For <= Against", async () => {
    // Only the voter (10 power) votes For, proposer abstains by not voting.
    // Quorum is 10% of total voting power (31 + 10 = 41) = 4, so 10 meets
    // quorum, but For (10) must exceed Against (0) — it does. So instead,
    // vote Against with the proposer's 31 power to make it fail.
    await governance
      .connect(proposer)
      .createProposal("Lower mint fee", "desc", 0, encodeValue(ethers.parseEther("5")))
    await governance.connect(proposer).vote(0, 0) // VoteType.Against
    await governance.connect(voter).vote(0, 1) // VoteType.For

    await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60])
    await ethers.provider.send("evm_mine")

    // For (10) <= Against (31) -> Failed.
    expect(await governance.getProposalState(0)).to.equal(3) // Failed
    await expect(governance.executeProposal(0)).to.be.revertedWith(
      "Proposal not ready for execution",
    )
  })
})
