// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract Escrow is ReentrancyGuard, Ownable {
    enum Status { Created, Funded, Shipped, Released, Disputed, Resolved, Refunded }

    struct Deal {
        address buyer;
        address seller;
        uint256 amount;
        bool collateralRequired;
        uint256 shippedTimestamp;
        Status status;
        uint256 collateralPosted;
        address targetBuyer;
    }

    mapping(uint256 => Deal) public deals;
    uint256 public dealCounter;
    
    address public treasury;
    uint256 public constant FEE_PERCENTAGE = 1; // 1% platform fee
    uint256 public constant DISPUTE_TIMEOUT = 7 days;

    event DealCreated(uint256 indexed dealId, address indexed buyer, address indexed seller, uint256 amount, bool collateralRequired);

    constructor(address _treasury) Ownable(msg.sender) {
        treasury = _treasury;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    // _targetBuyer restricts who may fund this deal: address(0) means any buyer (public
    // marketplace deal), a specific address means only that wallet may deposit (private deal).
    function createDeal(address _seller, uint256 _collateralAmount, address _targetBuyer) external payable returns (uint256) {
        if (msg.value > 0) {
            require(_targetBuyer == address(0) || _targetBuyer == msg.sender, "Caller is not the target buyer");
        }

        dealCounter++;
        Status dealStatus = msg.value == 0 ? Status.Created : Status.Funded;
        address buyerAddress = msg.value == 0 ? address(0) : msg.sender;

        deals[dealCounter] = Deal({
            buyer: buyerAddress,
            seller: _seller,
            amount: msg.value,
            collateralRequired: _collateralAmount > 0,
            shippedTimestamp: 0,
            status: dealStatus,
            collateralPosted: 0,
            targetBuyer: _targetBuyer
        });

        emit DealCreated(dealCounter, buyerAddress, _seller, msg.value, _collateralAmount > 0);
        return dealCounter;
    }

    // Added deposit function to fund existing open-market deals
    function deposit(uint256 dealId) external payable nonReentrant {
        Deal storage deal = deals[dealId];
        require(deal.status == Status.Created, "Deal already funded or invalid");
        require(msg.value > 0, "Must send ETH");
        require(deal.targetBuyer == address(0) || deal.targetBuyer == msg.sender, "Not the designated buyer for this private deal");

        deal.buyer = msg.sender;
        deal.amount = msg.value;
        deal.status = Status.Funded;
    }

    function markShipped(uint256 dealId) external {
        require(deals[dealId].status == Status.Funded, "Must be funded");
        require(msg.sender == deals[dealId].seller, "Only seller");
        
        deals[dealId].status = Status.Shipped;
        deals[dealId].shippedTimestamp = block.timestamp;
    }

    function confirmReceipt(uint256 dealId) external nonReentrant {
        require(deals[dealId].status == Status.Shipped, "Must be shipped");
        require(msg.sender == deals[dealId].buyer, "Only buyer");
        
        _releaseFunds(dealId);
    }

    function claimTimeout(uint256 dealId) external nonReentrant {
        require(deals[dealId].status == Status.Shipped, "Must be shipped");
        require(block.timestamp >= deals[dealId].shippedTimestamp + DISPUTE_TIMEOUT, "Timeout not reached");
        
        _releaseFunds(dealId);
    }

    function raiseDispute(uint256 dealId) external {
        require(deals[dealId].status == Status.Shipped || deals[dealId].status == Status.Funded, "Cannot dispute now");
        require(msg.sender == deals[dealId].buyer || msg.sender == deals[dealId].seller, "Not a party");
        
        deals[dealId].status = Status.Disputed;
    }

    function resolveDispute(uint256 dealId, bool releaseToSeller) external onlyOwner nonReentrant {
        require(deals[dealId].status == Status.Disputed, "Not disputed");
        
        if (releaseToSeller) {
            _releaseFunds(dealId);
        } else {
            Deal storage deal = deals[dealId];
            deal.status = Status.Refunded;
            (bool success, ) = payable(deal.buyer).call{value: deal.amount}("");
            require(success, "Refund failed");
        }
    }

    function _releaseFunds(uint256 dealId) internal {
        Deal storage deal = deals[dealId];
        deal.status = Status.Released;

        uint256 fee = (deal.amount * FEE_PERCENTAGE) / 100;
        uint256 payout = deal.amount - fee;

        (bool feeSuccess, ) = payable(treasury).call{value: fee}("");
        require(feeSuccess, "Fee transfer failed");

        (bool payoutSuccess, ) = payable(deal.seller).call{value: payout}("");
        require(payoutSuccess, "Payout failed");
    }
}
