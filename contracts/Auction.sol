// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./IPRNG.sol";
import "./PRNG.sol";

contract Auction is ERC721Holder, IPRNG {
    PRNG public prng;

    address payable public beneficiary;
    uint256 public auctionEndTime;

    // Current state of the auction.
    address public highestBidder;
    uint256 public highestBid;

    // Allowed withdrawals of previous bids
    mapping(address => uint256) public pendingReturns;

    // Set to true at the end, disallows any change.
    // By default initialized to `false`.
    bool public ended;

    address public nftContract;
    uint256 public nftId;
    uint256 public minimumBid;

    address royaltyReceiver;
    uint256 royaltyPercent;

    event HighestBidIncreased(address bidder, uint256 amount);
    event AuctionEnded(address winner, uint256 amount);
    event AuctionNotFullfilled(uint256 nftId, address nftContract, uint256 minimumBid);
    event RoyaltyPaid(address receiver, uint256 amount, uint256 royaltyPercentage);

    /// Auction already ended.
    error AuctionAlreadyEnded();
    /// Higher or equal bid already present.
    error BidNotHighEnough(uint256 highestBid);
    /// Auction not ended yet.
    error AuctionNotYetEnded();
    /// Auction end already called.
    error AuctionEndAlreadyCalled();
    /// Bid not high enough to participate in this auction
    error BidTooLow(uint256 minimumBid);

    /**
        Create an auction with `biddingTime` seconds bidding time on behalf of the
        beneficiary address `beneficiaryAddress`.

        @param _biddingTime Number of seconds the auction will be valid
        @param _beneficiaryAddress The address where the highest big will be credited
        @param _nftId The unique identifier of the NFT that is being sold
        @param _nftContract The address of the contract of the NFT
        @param _minimumBid The minimum bid that must be placed in order for the auction to start.
                Bid lower than this amount are refused.
                If no bid is higher than this amount at the end of the auction the NFT will be sent
                to the beneficiary
        @param _royaltyReceiver The address of the royalty receiver for a given auction
        @param _royaltyPercentage The 18 decimals percentage of the highest bid that will be sent to 
                the royalty receiver
    */
    constructor(
        uint256 _biddingTime,
        address payable _beneficiaryAddress,
        uint256 _nftId,
        address _nftContract,
        uint256 _minimumBid,
        address _royaltyReceiver,
        uint256 _royaltyPercentage
    ) {
        prng = PRNG(computePRNGAddress(msg.sender));
        prng.rotate();

        beneficiary = _beneficiaryAddress;
        auctionEndTime = block.timestamp + _biddingTime;
        nftContract = _nftContract;
        nftId = _nftId;
        minimumBid = _minimumBid;
        royaltyReceiver = _royaltyReceiver;
        royaltyPercent = _royaltyPercentage;
    }

    /** 
        Bid on the auction with the value sent together with this transaction.
        The value will only be refunded if the auction is not won.
    */
    function bid() external payable {
        prng.rotate();

        // check that the auction is still in its bidding period
        if (block.timestamp > auctionEndTime) {
            revert AuctionAlreadyEnded();
        }
        
        // check that the bid is higher or equal to the minimum bid to participate
        // in this auction
        if (msg.value < minimumBid) {
            revert BidTooLow(minimumBid);
        }

        // check that the current bid is higher than the previous
        if (msg.value <= highestBid) {
            revert BidNotHighEnough(highestBid);
        }

        if (highestBid != 0) {
            // save the previously highest bid in the pending return pot
            pendingReturns[highestBidder] += highestBid;
        }

        highestBidder = msg.sender;
        highestBid = msg.value;

        emit HighestBidIncreased(msg.sender, msg.value);
    }

    /**
        Withdraw a bids that were overbid.
    */
    function withdraw() public {
        prng.rotate();

        uint256 amount = pendingReturns[msg.sender];
        if (amount > 0) {
            pendingReturns[msg.sender] = 0;

            // send the preivous bid back to the sender
            Address.sendValue(payable(msg.sender), amount);
        }
    }

    /** 
        End the auction and send the highest bid to the beneficiary.
        If defined split the bid with the royalty receiver
    */
    function endAuction() public {
        prng.rotate();

        // check that the auction is ended
        if (block.timestamp < auctionEndTime) {
            revert AuctionNotYetEnded();
        }
        // check that the auction end call have not already been called
        if (ended) {
            revert AuctionEndAlreadyCalled();
        }

        // mark the auction as ended
        ended = true;

        if (highestBid == 0) {
            // send the NFT to the beneficiary if no bid has been accepted
            ERC721(nftContract).transferFrom(address(this), beneficiary, nftId);
            emit AuctionNotFullfilled(nftId, nftContract, minimumBid);
        }
        else {
            // send the NFT to the bidder
            ERC721(nftContract).transferFrom(address(this), highestBidder, nftId);

            // check if the royalty receiver and the payee are the same address
            // if they are make a transfer only, otherwhise split the bid based on
            // the royalty percentage and send the values

            if (beneficiary == royaltyReceiver) {
                // send the highest bid to the beneficiary
                Address.sendValue(beneficiary, highestBid);
            }
            else {
                // the royalty percentage has 18 decimals
                uint256 royalty = highestBid * royaltyPercent / 1 ether;
                uint256 beneficiaryEarning = highestBid - royalty;

                // send the royalty funds
                Address.sendValue(payable(royaltyReceiver), royalty);
                emit RoyaltyPaid(royaltyReceiver, royalty, royaltyPercent);

                // send the beneficiary earnings
                Address.sendValue(beneficiary, beneficiaryEarning);
            }

            emit AuctionEnded(highestBidder, highestBid);
        }
    }
}
