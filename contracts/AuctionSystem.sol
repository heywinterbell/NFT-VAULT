// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./VaultCoin.sol";
import "./NFTVault.sol";

contract AuctionSystem is ReentrancyGuard, Pausable, Ownable {
    using Counters for Counters.Counter;
    
    VaultCoin public vaultCoin;
    NFTVault public nftVault;
    
    Counters.Counter private _auctionIdCounter;
    
    uint256 public platformFeePercentage = 250; // 2.5% in basis points
    uint256 public minAuctionDuration = 1 hours;
    uint256 public maxAuctionDuration = 30 days;
    uint256 public bidExtensionTime = 10 minutes;
    
    struct Auction {
        uint256 auctionId;
        uint256 tokenId;
        address seller;
        uint256 shares;
        uint256 startingBid;
        uint256 currentBid;
        address currentBidder;
        uint256 startTime;
        uint256 endTime;
        bool active;
        bool settled;
        uint256 totalBids;
    }
    
    struct Bid {
        address bidder;
        uint256 amount;
        uint256 timestamp;
    }
    
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Bid[]) public auctionBids;
    mapping(address => uint256[]) public userAuctions;
    mapping(address => uint256[]) public userBids;
    
    event AuctionCreated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 shares,
        uint256 startingBid,
        uint256 endTime
    );
    
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount,
        uint256 timestamp
    );
    
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 winningBid,
        uint256 timestamp
    );
    
    event AuctionCancelled(uint256 indexed auctionId, uint256 timestamp);
    
    constructor(address _vaultCoin, address _nftVault) {
        vaultCoin = VaultCoin(payable(_vaultCoin));
        nftVault = NFTVault(_nftVault);
        _transferOwnership(msg.sender);
    }
    
    function createAuction(
        uint256 _tokenId,
        uint256 _shares,
        uint256 _startingBid,
        uint256 _duration
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(_shares > 0, "Must auction at least 1 share");
        require(_startingBid > 0, "Starting bid must be greater than 0");
        require(_duration >= minAuctionDuration && _duration <= maxAuctionDuration, "Invalid duration");
        
        // Verify seller has enough shares
        uint256 sellerShares = nftVault.getShareHolderBalance(_tokenId, msg.sender);
        require(sellerShares >= _shares, "Not enough shares to auction");

        // Escrow the shares in this contract (via NFTVault.transferShares)
        // so the seller cannot sell the same shares elsewhere while the
        // auction runs. They are delivered to the winner on settlement,
        // or returned to the seller if the auction is cancelled / has no bids.
        nftVault.transferShares(_tokenId, msg.sender, address(this), _shares);

        uint256 auctionId = _auctionIdCounter.current();
        _auctionIdCounter.increment();
        
        uint256 endTime = block.timestamp + _duration;
        
        auctions[auctionId] = Auction({
            auctionId: auctionId,
            tokenId: _tokenId,
            seller: msg.sender,
            shares: _shares,
            startingBid: _startingBid,
            currentBid: 0,
            currentBidder: address(0),
            startTime: block.timestamp,
            endTime: endTime,
            active: true,
            settled: false,
            totalBids: 0
        });
        
        userAuctions[msg.sender].push(auctionId);
        
        emit AuctionCreated(auctionId, _tokenId, msg.sender, _shares, _startingBid, endTime);
        
        return auctionId;
    }
    
    function placeBid(uint256 _auctionId, uint256 _bidAmount) external nonReentrant whenNotPaused {
        Auction storage auction = auctions[_auctionId];
        
        require(auction.active, "Auction not active");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(msg.sender != auction.seller, "Seller cannot bid");
        require(_bidAmount >= auction.startingBid, "Bid below starting price");
        require(_bidAmount > auction.currentBid, "Bid too low");
        
        // Transfer bid amount to contract
        require(vaultCoin.transferFrom(msg.sender, address(this), _bidAmount), "Bid transfer failed");
        
        // Refund previous bidder
        if (auction.currentBidder != address(0)) {
            require(vaultCoin.transfer(auction.currentBidder, auction.currentBid), "Refund failed");
        }
        
        // Update auction
        auction.currentBid = _bidAmount;
        auction.currentBidder = msg.sender;
        auction.totalBids++;
        
        // Extend auction if bid placed near end
        if (auction.endTime - block.timestamp < bidExtensionTime) {
            auction.endTime = block.timestamp + bidExtensionTime;
        }
        
        // Record bid
        auctionBids[_auctionId].push(Bid({
            bidder: msg.sender,
            amount: _bidAmount,
            timestamp: block.timestamp
        }));
        
        userBids[msg.sender].push(_auctionId);
        
        emit BidPlaced(_auctionId, msg.sender, _bidAmount, block.timestamp);
    }
    
    function settleAuction(uint256 _auctionId) external nonReentrant {
        Auction storage auction = auctions[_auctionId];
        
        require(auction.active, "Auction not active");
        require(block.timestamp >= auction.endTime, "Auction still ongoing");
        require(!auction.settled, "Auction already settled");
        
        auction.active = false;
        auction.settled = true;
        
        if (auction.currentBidder != address(0)) {
            // Calculate fees
            uint256 platformFee = (auction.currentBid * platformFeePercentage) / 10000;
            uint256 sellerAmount = auction.currentBid - platformFee;

            // Transfer payment to seller
            require(vaultCoin.transfer(auction.seller, sellerAmount), "Payment to seller failed");

            // Transfer platform fee
            require(vaultCoin.transfer(owner(), platformFee), "Platform fee transfer failed");

            // Deliver the escrowed shares to the winner. (Previously the
            // winner paid but never received any shares — the seller kept
            // both the shares and the money.)
            nftVault.transferShares(
                auction.tokenId,
                address(this),
                auction.currentBidder,
                auction.shares
            );

            emit AuctionSettled(_auctionId, auction.currentBidder, auction.currentBid, block.timestamp);
        } else {
            // No bids: return the escrowed shares to the seller.
            nftVault.transferShares(
                auction.tokenId,
                address(this),
                auction.seller,
                auction.shares
            );
            emit AuctionCancelled(_auctionId, block.timestamp);
        }
    }
    
    function cancelAuction(uint256 _auctionId) external nonReentrant {
        Auction storage auction = auctions[_auctionId];

        require(auction.seller == msg.sender, "Only seller can cancel");
        require(auction.active, "Auction not active");
        require(auction.currentBidder == address(0), "Cannot cancel with active bids");

        auction.active = false;

        // Return the escrowed shares to the seller.
        nftVault.transferShares(
            auction.tokenId,
            address(this),
            auction.seller,
            auction.shares
        );

        emit AuctionCancelled(_auctionId, block.timestamp);
    }
    
    function getAuctionBids(uint256 _auctionId) external view returns (Bid[] memory) {
        return auctionBids[_auctionId];
    }
    
    function getUserAuctions(address _user) external view returns (uint256[] memory) {
        return userAuctions[_user];
    }
    
    function getUserBids(address _user) external view returns (uint256[] memory) {
        return userBids[_user];
    }
    
    function getActiveAuctions() external view returns (uint256[] memory) {
        uint256[] memory activeAuctions = new uint256[](_auctionIdCounter.current());
        uint256 count = 0;
        
        for (uint256 i = 0; i < _auctionIdCounter.current(); i++) {
            if (auctions[i].active && block.timestamp < auctions[i].endTime) {
                activeAuctions[count] = i;
                count++;
            }
        }
        
        // Resize array
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = activeAuctions[i];
        }
        
        return result;
    }
    
    function setPlatformFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "Fee cannot exceed 10%");
        platformFeePercentage = _newFee;
    }
    
    function setAuctionDurationLimits(uint256 _min, uint256 _max) external onlyOwner {
        require(_min < _max, "Invalid duration limits");
        minAuctionDuration = _min;
        maxAuctionDuration = _max;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
}
