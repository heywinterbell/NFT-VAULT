// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./VaultFactory.sol";

contract NFTContract is ERC721, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    
    Counters.Counter private _tokenIdCounter;
    VaultFactory public vaultFactory;
    
    struct NFTInfo {
        address creator;
        string tokenURI;
        uint256 totalShares;
        uint256 availableShares;
        uint256 pricePerShare;
        address vaultContract;
        bool isListed;
        uint256 createdAt;
    }
    
    mapping(uint256 => NFTInfo) public nftInfo;
    mapping(address => uint256[]) public creatorNFTs;
    
    event NFTMinted(
        uint256 indexed tokenId,
        address indexed creator,
        uint256 totalShares,
        uint256 sharesToList,
        address vaultContract
    );
    
    event SharesPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 shares,
        uint256 totalCost
    );
    
    event SharesListed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 shares,
        uint256 pricePerShare
    );
    
    constructor(address _vaultFactory) ERC721("FractionalNFT", "FNFT") {
        vaultFactory = VaultFactory(_vaultFactory);
        _transferOwnership(msg.sender);
    }
    
    function mintNFT(
        string memory tokenURI,
        uint256 totalShares,
        uint256 sharesToList,
        uint256 pricePerShare
    ) external nonReentrant returns (uint256) {
        require(totalShares > 0, "Total shares must be greater than 0");
        require(sharesToList <= totalShares, "Cannot list more shares than total");
        require(pricePerShare > 0, "Price per share must be greater than 0");
        
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        
        // Mint NFT to creator
        _mint(msg.sender, tokenId);
        
        // Create vault token contract
        string memory vaultName = string(abi.encodePacked("Vault Token #", Strings.toString(tokenId)));
        string memory vaultSymbol = string(abi.encodePacked("VT", Strings.toString(tokenId)));
        
        address vaultContract = vaultFactory.createVaultToken(
            tokenId,
            address(this),
            totalShares,
            vaultName,
            vaultSymbol
        );
        
        // Store NFT info
        nftInfo[tokenId] = NFTInfo({
            creator: msg.sender,
            tokenURI: tokenURI,
            totalShares: totalShares,
            availableShares: sharesToList,
            pricePerShare: pricePerShare,
            vaultContract: vaultContract,
            isListed: sharesToList > 0,
            createdAt: block.timestamp
        });

        // Transfer the creator's retained (unlisted) shares to them.
        // The listed shares stay in this contract (escrow) so buyShares
        // can transfer them to buyers. The VaultToken supply was minted
        // to this contract by the factory.
        uint256 retainedShares = totalShares - sharesToList;
        if (retainedShares > 0) {
            VaultToken vaultToken = VaultToken(vaultContract);
            require(vaultToken.transfer(msg.sender, retainedShares), "Retained shares transfer failed");
        }

        creatorNFTs[msg.sender].push(tokenId);
        
        emit NFTMinted(tokenId, msg.sender, totalShares, sharesToList, vaultContract);
        
        return tokenId;
    }
    
    function buyShares(uint256 tokenId, uint256 shares) external payable nonReentrant {
        require(_exists(tokenId), "NFT does not exist");
        require(nftInfo[tokenId].isListed, "NFT shares not listed");
        require(shares > 0, "Must buy at least 1 share");
        require(shares <= nftInfo[tokenId].availableShares, "Not enough shares available");
        
        uint256 totalCost = shares * nftInfo[tokenId].pricePerShare;
        require(msg.value >= totalCost, "Insufficient payment");
        
        // Update available shares
        nftInfo[tokenId].availableShares -= shares;
        if (nftInfo[tokenId].availableShares == 0) {
            nftInfo[tokenId].isListed = false;
        }
        
        // Transfer vault tokens to buyer
        VaultToken vaultToken = VaultToken(nftInfo[tokenId].vaultContract);
        require(vaultToken.transfer(msg.sender, shares), "Vault token transfer failed");
        
        // Pay the creator
        address creator = nftInfo[tokenId].creator;
        payable(creator).transfer(totalCost);
        
        // Refund excess payment
        if (msg.value > totalCost) {
            payable(msg.sender).transfer(msg.value - totalCost);
        }
        
        emit SharesPurchased(tokenId, msg.sender, shares, totalCost);
    }
    
    function listShares(uint256 tokenId, uint256 shares, uint256 pricePerShare) external {
        require(_exists(tokenId), "NFT does not exist");
        require(msg.sender == nftInfo[tokenId].creator, "Only creator can list shares");
        require(shares > 0, "Must list at least 1 share");
        require(pricePerShare > 0, "Price must be greater than 0");

        VaultToken vaultToken = VaultToken(nftInfo[tokenId].vaultContract);
        require(vaultToken.balanceOf(msg.sender) >= shares, "Insufficient vault tokens");

        // Escrow the listed shares in this contract so buyShares can
        // transfer them to buyers. The creator must approve this contract
        // to spend `shares` VaultTokens before calling listShares.
        // (Previously the tokens were never escrowed, so buyShares always
        // reverted: the contract held zero VaultTokens.)
        require(vaultToken.transferFrom(msg.sender, address(this), shares), "Escrow transfer failed");

        nftInfo[tokenId].availableShares += shares;
        nftInfo[tokenId].pricePerShare = pricePerShare;
        nftInfo[tokenId].isListed = true;

        emit SharesListed(tokenId, msg.sender, shares, pricePerShare);
    }
    
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "NFT does not exist");
        return nftInfo[tokenId].tokenURI;
    }
    
    function getTokenShares(uint256 tokenId) external view returns (uint256, uint256) {
        require(_exists(tokenId), "NFT does not exist");
        return (nftInfo[tokenId].totalShares, nftInfo[tokenId].availableShares);
    }
    
    function getVaultContract(uint256 tokenId) external view returns (address) {
        require(_exists(tokenId), "NFT does not exist");
        return nftInfo[tokenId].vaultContract;
    }
    
    function getCreator(uint256 tokenId) external view returns (address) {
        require(_exists(tokenId), "NFT does not exist");
        return nftInfo[tokenId].creator;
    }
    
    function getListingInfo(uint256 tokenId) external view returns (uint256, uint256, bool) {
        require(_exists(tokenId), "NFT does not exist");
        return (
            nftInfo[tokenId].availableShares,
            nftInfo[tokenId].pricePerShare,
            nftInfo[tokenId].isListed
        );
    }
    
    function getCreatorNFTs(address creator) external view returns (uint256[] memory) {
        return creatorNFTs[creator];
    }
    
    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter.current();
    }
}
