// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";

contract EscrowTest is Test {
    Escrow public escrow;
    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public treasury = address(0x1003);
    address public stranger = address(0x1004);

    function setUp() public {
        // Deploy as the owner/admin, set treasury
        escrow = new Escrow(treasury);
        vm.deal(buyer, 10 ether);
        vm.deal(seller, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    function testFullSuccessfulFlowWithFee() public {
        vm.prank(buyer);
        uint256 dealId = escrow.createDeal{value: 1 ether}(seller, 0, address(0));

        vm.prank(seller);
        escrow.markShipped(dealId);

        vm.prank(buyer);
        escrow.confirmReceipt(dealId);

        // 1 ether = 1e18 wei. 1% fee = 0.01 ether. Seller gets 0.99 ether.
        assertEq(seller.balance, 10.99 ether);
        assertEq(treasury.balance, 0.01 ether);
    }

    function testAutoReleaseTimeout() public {
        vm.prank(buyer);
        uint256 dealId = escrow.createDeal{value: 1 ether}(seller, 0, address(0));

        vm.prank(seller);
        escrow.markShipped(dealId);

        // Fast forward time by 8 days (exceeds the 7-day timeout)
        vm.warp(block.timestamp + 8 days);

        // Anyone can trigger the timeout release
        escrow.claimTimeout(dealId);

        assertEq(seller.balance, 10.99 ether);
        assertEq(treasury.balance, 0.01 ether);
    }

    function testDisputeResolvedRefund() public {
        vm.prank(buyer);
        uint256 dealId = escrow.createDeal{value: 1 ether}(seller, 0, address(0));

        vm.prank(seller);
        escrow.markShipped(dealId);

        vm.prank(buyer);
        escrow.raiseDispute(dealId);

        // Resolve: refund to buyer (false)
        escrow.resolveDispute(dealId, false);

        assertEq(buyer.balance, 10 ether); // Fully refunded
    }

    function testPrivateDealBlocksNonTargetBuyer() public {
        // Seller lists an unfunded deal restricted to `buyer` only
        vm.prank(seller);
        uint256 dealId = escrow.createDeal(seller, 0, buyer);

        // A stranger attempts to fund it and must be rejected
        vm.prank(stranger);
        vm.expectRevert("Not the designated buyer for this private deal");
        escrow.deposit{value: 1 ether}(dealId);
    }

    function testPrivateDealAllowsTargetBuyer() public {
        vm.prank(seller);
        uint256 dealId = escrow.createDeal(seller, 0, buyer);

        // The designated buyer succeeds
        vm.prank(buyer);
        escrow.deposit{value: 1 ether}(dealId);

        (
            ,
            ,
            ,
            ,
            ,
            Escrow.Status status,
            ,

        ) = escrow.deals(dealId);
        assertEq(uint256(status), uint256(Escrow.Status.Funded));
    }

    function testPublicDealAllowsAnyBuyerViaDeposit() public {
        // targetBuyer = address(0) means open marketplace deal
        vm.prank(seller);
        uint256 dealId = escrow.createDeal(seller, 0, address(0));

        vm.prank(stranger);
        escrow.deposit{value: 1 ether}(dealId);

        (
            ,
            ,
            ,
            ,
            ,
            Escrow.Status status,
            ,

        ) = escrow.deals(dealId);
        assertEq(uint256(status), uint256(Escrow.Status.Funded));
    }

    function testDirectFundedCreateDealRejectsWrongCaller() public {
        // If a target buyer is specified up front, only that address may create-and-fund in one call
        vm.prank(stranger);
        vm.expectRevert("Caller is not the target buyer");
        escrow.createDeal{value: 1 ether}(seller, 0, buyer);
    }
}
