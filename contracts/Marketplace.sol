// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./NFTContract.sol";
import "./VaultToken.sol";

contract Marketplace is Ownable, ReentrancyGuard {
    /// @notice The NFT contract whose fractional shares this marketplace trades.
    /// Stored once at deployment (immutable) and used to look up the
    /// VaultToken for a given tokenId.
    NFTContract public immutable nftContract;

    struct Listing {
        address seller;
        uint256 shares;
        uint256 pricePerShare;
        bool active;
        uint256 listedAt;
    }
    
    mapping(uint256 => Listing) public listings;
    uint256[] public activeListings;
    
    uint256 public platformFee = 250; // 2.5% in basis points
    
    event SharesListed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 shares,
        uint256 pricePerShare
    );
    
    event SharesPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 shares,
        uint256 totalCost
    );
    
    event ListingCancelled(uint256 indexed tokenId, address indexed seller);
    
    constructor(address _nftContract) {
        require(_nftContract != address(0), "NFT contract address required");
        nftContract = NFTContract(_nftContract);
        _transferOwnership(msg.sender);
    }
    
    function listNFTShares(
        uint256 tokenId,
        uint256 shares,
        uint256 pricePerShare
    ) external nonReentrant {
        require(shares > 0, "Must list at least 1 share");
        require(pricePerShare > 0, "Price must be greater than 0");

        // Get the vault token contract for this NFT from the stored
        // NFT contract. (Previously this used NFTContract(msg.sender),
        // which treated the calling *user* as the NFT contract, so
        // every call reverted.)
        address vaultAddress = nftContract.getVaultContract(tokenId);
        VaultToken vaultToken = VaultToken(vaultAddress);
        
        require(vaultToken.balanceOf(msg.sender) >= shares, "Insufficient vault tokens");
        
        // Transfer vault tokens to marketplace for escrow
        require(vaultToken.transferFrom(msg.sender, address(this), shares), "Transfer failed");
        
        listings[tokenId] = Listing({
            seller: msg.sender,
            shares: shares,
            pricePerShare: pricePerShare,
            active: true,
            listedAt: block.timestamp
        });
        
        activeListings.push(tokenId);
        
        emit SharesListed(tokenId, msg.sender, shares, pricePerShare);
    }
    
    function buyShares(uint256 tokenId) external payable nonReentrant {
        Listing storage listing = listings[tokenId];
        require(listing.active, "Listing not active");
        require(listing.seller != msg.sender, "Cannot buy your own shares");
        
        uint256 totalCost = listing.shares * listing.pricePerShare;
        require(msg.value >= totalCost, "Insufficient payment");
        
        // Calculate platform fee
        uint256 fee = (totalCost * platformFee) / 10000;
        uint256 sellerAmount = totalCost - fee;

        // Get vault token contract from the stored NFT contract.
        address vaultAddress = nftContract.getVaultContract(tokenId);
        VaultToken vaultToken = VaultToken(vaultAddress);
        
        // Transfer vault tokens to buyer
        require(vaultToken.transfer(msg.sender, listing.shares), "Token transfer failed");
        
        // Pay seller
        payable(listing.seller).transfer(sellerAmount);
        
        // Pay platform fee to owner
        if (fee > 0) {
            payable(owner()).transfer(fee);
        }
        
        // Refund excess payment
        if (msg.value > totalCost) {
            payable(msg.sender).transfer(msg.value - totalCost);
        }
        
        // Mark listing as inactive
        listing.active = false;
        
        emit SharesPurchased(tokenId, msg.sender, listing.seller, listing.shares, totalCost);
    }
    
    function cancelListing(uint256 tokenId) external {
        Listing storage listing = listings[tokenId];
        require(listing.seller == msg.sender, "Only seller can cancel");
        require(listing.active, "Listing not active");

        // Return vault tokens to seller (from the stored NFT contract).
        address vaultAddress = nftContract.getVaultContract(tokenId);
        VaultToken vaultToken = VaultToken(vaultAddress);
        
        require(vaultToken.transfer(msg.sender, listing.shares), "Token return failed");
        
        listing.active = false;
        
        emit ListingCancelled(tokenId, msg.sender);
    }
    
    function getActiveListing(uint256 tokenId) external view returns (address, uint256, uint256, bool) {
        Listing memory listing = listings[tokenId];
        return (listing.seller, listing.shares, listing.pricePerShare, listing.active);
    }
    
    function getAllActiveListings() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < activeListings.length; i++) {
            if (listings[activeListings[i]].active) {
                count++;
            }
        }
        
        uint256[] memory result = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < activeListings.length; i++) {
            if (listings[activeListings[i]].active) {
                result[index] = activeListings[i];
                index++;
            }
        }
        
        return result;
    }
    
    function setPlatformFee(uint256 _platformFee) external onlyOwner {
        require(_platformFee <= 1000, "Fee cannot exceed 10%");
        platformFee = _platformFee;
    }
}
