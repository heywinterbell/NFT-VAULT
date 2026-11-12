// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract NFTVault is ERC721, Ownable, ReentrancyGuard, Pausable {
    using Counters for Counters.Counter;
    
    IERC20 public vaultCoin;
    Counters.Counter private _tokenIdCounter;
    
    uint256 public mintingFee = 10 * 10**18; // 10 VAULT tokens
    uint256 public platformFeePercentage = 250; // 2.5% in basis points
    /// @notice Maximum royalty a creator can set, in basis points (1000 = 10%).
    /// Governable via Governance (ChangeRoyaltyLimit proposals).
    uint256 public maxRoyaltyPercentage = 1000;
    
    struct NFTData {
        string ipfsHash;
        string title;
        string description;
        address creator;
        uint256 royaltyPercentage; // in basis points (100 = 1%)
        uint256 totalShares;
        uint256 availableShares;
        uint256 pricePerShare;
        bool isListed;
        uint256 createdAt;
        uint256 totalRevenue;
        mapping(address => uint256) shareHolders;
        address[] shareHoldersList;
    }
    
    struct ShareTransaction {
        uint256 tokenId;
        address buyer;
        address seller;
        uint256 shares;
        uint256 pricePerShare;
        uint256 timestamp;
        bytes32 transactionHash;
    }
    
    mapping(uint256 => NFTData) public nftData;
    mapping(address => uint256[]) public userCreatedNFTs;
    mapping(address => uint256[]) public userOwnedShares;
    mapping(uint256 => ShareTransaction[]) public shareTransactionHistory;
    
    // Events
    event NFTMinted(
        uint256 indexed tokenId,
        address indexed creator,
        string ipfsHash,
        string title,
        uint256 totalShares,
        uint256 timestamp
    );
    
    event SharesPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 shares,
        uint256 totalPrice,
        uint256 timestamp
    );
    
    event SharesListed(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 availableShares,
        uint256 pricePerShare,
        uint256 timestamp
    );
    
    event RoyaltyPaid(
        uint256 indexed tokenId,
        address indexed creator,
        uint256 amount,
        uint256 timestamp
    );
    
    event PlatformFeePaid(
        uint256 indexed tokenId,
        uint256 amount,
        uint256 timestamp
    );
    
    constructor(address _vaultCoin) ERC721("NFTVault", "NFTV") {
        vaultCoin = IERC20(_vaultCoin);
        _transferOwnership(msg.sender);
    }
    
    function mintNFT(
        string memory _ipfsHash,
        string memory _title,
        string memory _description,
        uint256 _royaltyPercentage,
        uint256 _totalShares,
        uint256 _sharesToList,
        uint256 _pricePerShare
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(bytes(_ipfsHash).length > 0, "IPFS hash required");
        require(bytes(_title).length > 0, "Title required");
        require(_royaltyPercentage <= maxRoyaltyPercentage, "Royalty exceeds maximum");
        require(_totalShares > 0, "Total shares must be greater than 0");
        require(_sharesToList <= _totalShares, "Cannot list more shares than total");
        require(vaultCoin.transferFrom(msg.sender, owner(), mintingFee), "Minting fee payment failed");
        
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _mint(msg.sender, tokenId);
        
        NFTData storage nft = nftData[tokenId];
        nft.ipfsHash = _ipfsHash;
        nft.title = _title;
        nft.description = _description;
        nft.creator = msg.sender;
        nft.royaltyPercentage = _royaltyPercentage;
        nft.totalShares = _totalShares;
        nft.availableShares = _sharesToList;
        nft.pricePerShare = _pricePerShare;
        nft.isListed = _sharesToList > 0;
        nft.createdAt = block.timestamp;
        nft.totalRevenue = 0;
        
        // Creator gets remaining shares
        uint256 creatorShares = _totalShares - _sharesToList;
        if (creatorShares > 0) {
            nft.shareHolders[msg.sender] = creatorShares;
            nft.shareHoldersList.push(msg.sender);
            userOwnedShares[msg.sender].push(tokenId);
        }
        
        userCreatedNFTs[msg.sender].push(tokenId);
        
        emit NFTMinted(tokenId, msg.sender, _ipfsHash, _title, _totalShares, block.timestamp);
        
        if (_sharesToList > 0) {
            emit SharesListed(tokenId, msg.sender, _sharesToList, _pricePerShare, block.timestamp);
        }
        
        return tokenId;
    }
    
    function buyShares(uint256 _tokenId, uint256 _shares) external nonReentrant whenNotPaused {
        require(_exists(_tokenId), "NFT does not exist");
        require(nftData[_tokenId].isListed, "NFT shares not listed for sale");
        require(_shares > 0, "Must buy at least 1 share");
        require(_shares <= nftData[_tokenId].availableShares, "Not enough shares available");
        
        uint256 totalPrice = _shares * nftData[_tokenId].pricePerShare;
        require(vaultCoin.transferFrom(msg.sender, address(this), totalPrice), "Payment failed");
        
        // Update available shares
        nftData[_tokenId].availableShares -= _shares;
        if (nftData[_tokenId].availableShares == 0) {
            nftData[_tokenId].isListed = false;
        }
        
        // Update buyer's shares
        if (nftData[_tokenId].shareHolders[msg.sender] == 0) {
            nftData[_tokenId].shareHoldersList.push(msg.sender);
            userOwnedShares[msg.sender].push(_tokenId);
        }
        nftData[_tokenId].shareHolders[msg.sender] += _shares;
        
        // Calculate fees
        uint256 platformFee = (totalPrice * platformFeePercentage) / 10000;
        uint256 royaltyAmount = (totalPrice * nftData[_tokenId].royaltyPercentage) / 10000;
        uint256 ownerAmount = totalPrice - platformFee - royaltyAmount;
        
        // Pay platform fee
        if (platformFee > 0) {
            vaultCoin.transfer(owner(), platformFee);
            emit PlatformFeePaid(_tokenId, platformFee, block.timestamp);
        }
        
        // Pay royalty to creator
        if (royaltyAmount > 0) {
            vaultCoin.transfer(nftData[_tokenId].creator, royaltyAmount);
            emit RoyaltyPaid(_tokenId, nftData[_tokenId].creator, royaltyAmount, block.timestamp);
        }
        
        // Pay remaining amount to NFT owner
        vaultCoin.transfer(ownerOf(_tokenId), ownerAmount);
        
        // Update revenue tracking
        nftData[_tokenId].totalRevenue += totalPrice;
        
        // Record transaction
        shareTransactionHistory[_tokenId].push(ShareTransaction({
            tokenId: _tokenId,
            buyer: msg.sender,
            seller: ownerOf(_tokenId),
            shares: _shares,
            pricePerShare: nftData[_tokenId].pricePerShare,
            timestamp: block.timestamp,
            transactionHash: keccak256(abi.encodePacked(block.timestamp, msg.sender, _tokenId, _shares))
        }));
        
        emit SharesPurchased(_tokenId, msg.sender, ownerOf(_tokenId), _shares, totalPrice, block.timestamp);
    }
    
    function listMoreShares(uint256 _tokenId, uint256 _shares, uint256 _pricePerShare) external whenNotPaused {
        require(ownerOf(_tokenId) == msg.sender, "Only NFT owner can list shares");
        require(nftData[_tokenId].shareHolders[msg.sender] >= _shares, "Not enough shares to list");
        require(_pricePerShare > 0, "Price must be greater than 0");
        
        nftData[_tokenId].shareHolders[msg.sender] -= _shares;
        nftData[_tokenId].availableShares += _shares;
        nftData[_tokenId].pricePerShare = _pricePerShare;
        nftData[_tokenId].isListed = true;
        
        emit SharesListed(_tokenId, msg.sender, _shares, _pricePerShare, block.timestamp);
    }
    
    // View functions
    function getShareHolders(uint256 _tokenId) external view returns (address[] memory) {
        return nftData[_tokenId].shareHoldersList;
    }
    
    function getUserCreatedNFTs(address _user) external view returns (uint256[] memory) {
        return userCreatedNFTs[_user];
    }
    
    function getUserOwnedShares(address _user) external view returns (uint256[] memory) {
        return userOwnedShares[_user];
    }
    
    function getShareHolderBalance(uint256 _tokenId, address _holder) external view returns (uint256) {
        return nftData[_tokenId].shareHolders[_holder];
    }
    
    function getShareTransactionHistory(uint256 _tokenId) external view returns (ShareTransaction[] memory) {
        return shareTransactionHistory[_tokenId];
    }
    
    function getCreator(uint256 tokenId) public view returns (address) {
        return nftData[tokenId].creator;
    }
    
    function getNFTDetails(uint256 _tokenId) external view returns (
        string memory ipfsHash,
        string memory title,
        string memory description,
        address creator,
        uint256 royaltyPercentage,
        uint256 totalShares,
        uint256 availableShares,
        uint256 pricePerShare,
        bool isListed,
        uint256 createdAt,
        uint256 totalRevenue
    ) {
        NFTData storage nft = nftData[_tokenId];
        return (
            nft.ipfsHash,
            nft.title,
            nft.description,
            nft.creator,
            nft.royaltyPercentage,
            nft.totalShares,
            nft.availableShares,
            nft.pricePerShare,
            nft.isListed,
            nft.createdAt,
            nft.totalRevenue
        );
    }
    
    // Admin functions
    function setMintingFee(uint256 _newFee) external onlyOwner {
        mintingFee = _newFee;
    }
    
    function setPlatformFeePercentage(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "Fee cannot exceed 10%");
        platformFeePercentage = _newFee;
    }

    function setMaxRoyaltyPercentage(uint256 _newMax) external onlyOwner {
        require(_newMax <= 5000, "Max royalty cannot exceed 50%");
        maxRoyaltyPercentage = _newMax;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function withdrawFees() external onlyOwner {
        uint256 balance = vaultCoin.balanceOf(address(this));
        require(balance > 0, "No fees to withdraw");
        vaultCoin.transfer(owner(), balance);
    }
    
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "NFT does not exist");
        return string(abi.encodePacked("https://ipfs.io/ipfs/", nftData[tokenId].ipfsHash));
    }
    
    function totalSupply() public view returns (uint256) {
        return _tokenIdCounter.current();
    }
}
