// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./VaultToken.sol";

contract VaultFactory is Ownable {
    mapping(bytes32 => address) public vaultTokens;
    mapping(address => bool) public isVaultToken;
    
    event VaultTokenCreated(
        uint256 indexed nftId,
        address indexed nftContract,
        address vaultToken,
        uint256 totalSupply
    );
    
    constructor() {
        _transferOwnership(msg.sender);
    }
    
    function createVaultToken(
        uint256 nftId,
        address nftContract,
        uint256 totalSupply,
        string memory name,
        string memory symbol
    ) external returns (address) {
        bytes32 key = keccak256(abi.encodePacked(nftId, nftContract));
        require(vaultTokens[key] == address(0), "Vault token already exists");
        
        VaultToken vaultToken = new VaultToken(
            nftId,
            nftContract,
            totalSupply,
            name,
            symbol,
            // Mint to the NFT contract (escrow). The NFT contract holds the
            // listed shares and transfers them to buyers in buyShares, and
            // transfers the creator's retained shares to the creator at mint.
            // Minting to tx.origin left the NFT contract with a zero balance,
            // so every buyShares call reverted.
            nftContract
        );
        
        address vaultAddress = address(vaultToken);
        vaultTokens[key] = vaultAddress;
        isVaultToken[vaultAddress] = true;
        
        emit VaultTokenCreated(nftId, nftContract, vaultAddress, totalSupply);
        
        return vaultAddress;
    }
    
    function getVaultToken(uint256 nftId, address nftContract) external view returns (address) {
        bytes32 key = keccak256(abi.encodePacked(nftId, nftContract));
        return vaultTokens[key];
    }
}
