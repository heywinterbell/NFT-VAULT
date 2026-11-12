const { expect } = require("chai")
const fs = require("fs")
const path = require("path")

describe("Security — hardhat config", () => {
  const configPath = path.join(__dirname, "..", "hardhat.config.js")
  const configSource = fs.readFileSync(configPath, "utf8")

  it("should not contain any hardcoded Etherscan API key", () => {
    // The previously leaked key must not be present anywhere in the config.
    expect(configSource).to.not.include("E96HBT7SDPGZ7BCZR814T2VKTZYD9FSCSY")
    // No 32+ char alphanumeric string that looks like a hardcoded API key
    // should appear as a quoted literal in the etherscan section.
    const etherscanSection = configSource.slice(configSource.indexOf("etherscan:"))
    const hardcodedKey = /['"][A-Za-z0-9]{32,}['"]/.test(etherscanSection)
    expect(hardcodedKey, "hardcoded API key literal found in etherscan config").to.be.false
  })

  it("should read the Etherscan API key from the environment", () => {
    expect(configSource).to.include("process.env.ETHERSCAN_API_KEY")
  })

  it("should pick up ETHERSCAN_API_KEY from process.env when set", () => {
    const testKey = "TEST_API_KEY_1234567890abcdef"
    process.env.ETHERSCAN_API_KEY = testKey
    // Clear the require cache so the config is re-evaluated with the new env.
    delete require.cache[require.resolve("../hardhat.config.js")]
    const config = require("../hardhat.config.js")
    expect(config.etherscan.apiKey.sepolia).to.equal(testKey)
    expect(config.etherscan.apiKey.holesky).to.equal(testKey)
    delete process.env.ETHERSCAN_API_KEY
    delete require.cache[require.resolve("../hardhat.config.js")]
  })

  it("should not require an Etherscan API key to load (key is optional)", () => {
    delete process.env.ETHERSCAN_API_KEY
    delete require.cache[require.resolve("../hardhat.config.js")]
    const config = require("../hardhat.config.js")
    // With no key set, the value is undefined — loading must not throw.
    expect(config.etherscan.apiKey.sepolia).to.be.undefined
    delete require.cache[require.resolve("../hardhat.config.js")]
  })
})
