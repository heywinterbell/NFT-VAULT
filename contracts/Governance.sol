// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./VaultCoin.sol";
import "./NFTVault.sol";

contract Governance is ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;

    VaultCoin public vaultCoin;
    /// @notice The NFTVault whose fees this governance can change.
    /// The Governance contract must be the owner of the NFTVault (or be
    /// granted the relevant roles) for execution to succeed.
    NFTVault public nftVault;

    Counters.Counter private _proposalIdCounter;

    uint256 public constant VOTING_PERIOD = 7 days;
    uint256 public constant EXECUTION_DELAY = 2 days;
    // Minimum voting power needed to create a proposal. Voting power is
    // sqrt(VAULT balance), so 10 voting power ~= 100 VAULT tokens — reachable
    // for an engaged user. (Previously 1000 voting power, which needs
    // 1,000,000 VAULT — the entire initial supply — so no one could ever
    // create a proposal.)
    uint256 public constant PROPOSAL_THRESHOLD = 10;
    uint256 public constant QUORUM_PERCENTAGE = 10; // 10% of total voting power
    
    enum ProposalState {
        Pending,
        Active,
        Succeeded,
        Failed,
        Executed,
        Cancelled
    }
    
    enum VoteType {
        Against,
        For,
        Abstain
    }
    
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 executionTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool cancelled;
        ProposalType proposalType;
        bytes proposalData;
    }
    
    enum ProposalType {
        ChangeMintingFee,
        ChangePlatformFee,
        ChangeRoyaltyLimit,
        AddFeature,
        Emergency
    }
    
    struct Vote {
        bool hasVoted;
        VoteType vote;
        uint256 weight;
    }
    
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Vote)) public votes;
    mapping(address => uint256[]) public userProposals;
    
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        uint256 startTime,
        uint256 endTime
    );
    
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        VoteType vote,
        uint256 weight
    );
    
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    
    constructor(address _vaultCoin, address _nftVault) {
        vaultCoin = VaultCoin(payable(_vaultCoin));
        nftVault = NFTVault(_nftVault);
        _transferOwnership(msg.sender);
    }
    
    function createProposal(
        string memory _title,
        string memory _description,
        ProposalType _proposalType,
        bytes memory _proposalData
    ) external nonReentrant returns (uint256) {
        require(vaultCoin.votingPower(msg.sender) >= PROPOSAL_THRESHOLD, "Insufficient voting power");
        require(bytes(_title).length > 0, "Title required");
        require(bytes(_description).length > 0, "Description required");
        
        uint256 proposalId = _proposalIdCounter.current();
        _proposalIdCounter.increment();
        
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + VOTING_PERIOD;
        uint256 executionTime = endTime + EXECUTION_DELAY;
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: _title,
            description: _description,
            startTime: startTime,
            endTime: endTime,
            executionTime: executionTime,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            executed: false,
            cancelled: false,
            proposalType: _proposalType,
            proposalData: _proposalData
        });
        
        userProposals[msg.sender].push(proposalId);
        
        emit ProposalCreated(proposalId, msg.sender, _title, startTime, endTime);
        
        return proposalId;
    }
    
    function vote(uint256 _proposalId, VoteType _vote) external nonReentrant {
        Proposal storage proposal = proposals[_proposalId];
        Vote storage userVote = votes[_proposalId][msg.sender];
        
        require(getProposalState(_proposalId) == ProposalState.Active, "Proposal not active");
        require(!userVote.hasVoted, "Already voted");
        
        uint256 weight = vaultCoin.votingPower(msg.sender);
        require(weight > 0, "No voting power");
        
        userVote.hasVoted = true;
        userVote.vote = _vote;
        userVote.weight = weight;
        
        if (_vote == VoteType.For) {
            proposal.forVotes += weight;
        } else if (_vote == VoteType.Against) {
            proposal.againstVotes += weight;
        } else {
            proposal.abstainVotes += weight;
        }
        
        emit VoteCast(_proposalId, msg.sender, _vote, weight);
    }
    
    function executeProposal(uint256 _proposalId) external nonReentrant {
        require(getProposalState(_proposalId) == ProposalState.Succeeded, "Proposal not ready for execution");
        
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp >= proposal.executionTime, "Execution delay not met");
        
        proposal.executed = true;
        
        // Execute proposal based on type
        _executeProposalAction(proposal);
        
        emit ProposalExecuted(_proposalId);
    }
    
    function _executeProposalAction(Proposal memory proposal) internal {
        // proposalData is abi.encode(uint256 newValue) for the fee/limit
        // proposals. The Governance contract must own the NFTVault for
        // these calls to succeed (transfer NFTVault ownership to this
        // contract after deployment).
        if (proposal.proposalType == ProposalType.ChangeMintingFee) {
            uint256 newFee = abi.decode(proposal.proposalData, (uint256));
            nftVault.setMintingFee(newFee);
        } else if (proposal.proposalType == ProposalType.ChangePlatformFee) {
            uint256 newFee = abi.decode(proposal.proposalData, (uint256));
            nftVault.setPlatformFeePercentage(newFee);
        } else if (proposal.proposalType == ProposalType.ChangeRoyaltyLimit) {
            uint256 newLimit = abi.decode(proposal.proposalData, (uint256));
            nftVault.setMaxRoyaltyPercentage(newLimit);
        }
        // AddFeature and Emergency have no on-chain action: they record
        // the community's decision (via the ProposalExecuted event) and
        // are carried out off-chain by the team.
    }
    
    function cancelProposal(uint256 _proposalId) external {
        Proposal storage proposal = proposals[_proposalId];
        require(msg.sender == proposal.proposer || msg.sender == owner(), "Not authorized");
        require(getProposalState(_proposalId) == ProposalState.Pending || getProposalState(_proposalId) == ProposalState.Active, "Cannot cancel");
        
        proposal.cancelled = true;
        
        emit ProposalCancelled(_proposalId);
    }
    
    function getProposalState(uint256 _proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[_proposalId];
        
        if (proposal.cancelled) {
            return ProposalState.Cancelled;
        }
        
        if (proposal.executed) {
            return ProposalState.Executed;
        }
        
        if (block.timestamp < proposal.startTime) {
            return ProposalState.Pending;
        }
        
        if (block.timestamp <= proposal.endTime) {
            return ProposalState.Active;
        }
        
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        uint256 quorum = (vaultCoin.totalVotingPower() * QUORUM_PERCENTAGE) / 100;
        
        if (totalVotes < quorum || proposal.forVotes <= proposal.againstVotes) {
            return ProposalState.Failed;
        }
        
        return ProposalState.Succeeded;
    }
    
    function getUserProposals(address _user) external view returns (uint256[] memory) {
        return userProposals[_user];
    }
    
    function getAllProposals() external view returns (uint256[] memory) {
        uint256[] memory allProposals = new uint256[](_proposalIdCounter.current());
        for (uint256 i = 0; i < _proposalIdCounter.current(); i++) {
            allProposals[i] = i;
        }
        return allProposals;
    }
    
    function getProposalVotes(uint256 _proposalId) external view returns (uint256, uint256, uint256) {
        Proposal storage proposal = proposals[_proposalId];
        return (proposal.forVotes, proposal.againstVotes, proposal.abstainVotes);
    }
}
