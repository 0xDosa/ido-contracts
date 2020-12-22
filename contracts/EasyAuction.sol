// SPDX-License-Identifier: LGPL-3.0-or-newer
pragma solidity >=0.6.8;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./libraries/IterableOrderedOrderSet.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libraries/IdToAddressBiMap.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EasyAuction is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint64;
    using SafeMath for uint96;
    using SafeMath for uint256;
    using SafeCast for uint256;
    using IterableOrderedOrderSet for IterableOrderedOrderSet.Data;
    using IterableOrderedOrderSet for bytes32;
    using IdToAddressBiMap for IdToAddressBiMap.Data;

    modifier atStageOrderPlacement(uint256 auctionId) {
        require(
            block.timestamp < auctionData[auctionId].auctionEndDate,
            "no longer in order placement phase"
        );
        _;
    }

    modifier atStageSolutionSubmission(uint256 auctionId) {
        require(
            block.timestamp > auctionData[auctionId].auctionEndDate &&
                auctionData[auctionId].clearingPriceOrder == bytes32(0),
            "Auction not in solution submission phase"
        );
        _;
    }

    modifier atStageFinished(uint256 auctionId) {
        require(
            auctionData[auctionId].clearingPriceOrder != bytes32(0),
            "Auction not yet finished"
        );
        _;
    }

    event NewSellOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );
    event CancellationSellOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 sellAmount,
        uint96 buyAmount
    );
    event ClaimedFromOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );
    event NewAuction(
        uint256 indexed auctionId,
        IERC20 indexed _auctionedToken,
        IERC20 indexed _bidderToken
    );
    event AuctionCleared(
        uint256 indexed auctionId,
        uint96 priceNumerator,
        uint96 priceDenominator
    );
    event UserRegistration(address indexed user, uint64 userId);

    struct AuctionData {
        IERC20 auctionedToken;
        IERC20 bidderToken;
        uint256 auctionEndDate;
        bytes32 initialAuctionOrder;
        uint256 minimumBiddingAmount;
        uint256 interimSumBiddedAmount;
        bytes32 interimOrder;
        bytes32 clearingPriceOrder;
        uint96 volumeClearingPriceOrder;
        uint256 feeNumerator;
    }
    mapping(uint256 => IterableOrderedOrderSet.Data) public sellOrders;
    mapping(uint256 => AuctionData) public auctionData;
    IdToAddressBiMap.Data private registeredUsers;
    uint64 public numUsers;
    uint256 public auctionCounter;

    constructor() public Ownable() {}

    uint256 public feeNumerator = 0;
    uint256 public constant FEE_DENOMINATOR = 1000;
    uint64 public feeReceiverUserId = 0;

    function setFeeParameters(
        uint256 newFeeNumerator,
        address newfeeReceiverAddress
    ) public onlyOwner() {
        require(
            newFeeNumerator <= 15,
            "Fee is not allowed to be set higher than 1.5%"
        );
        // caution: for currently running auctions, the feeReceiverUserId is changing as well.
        feeReceiverUserId = getUserId(newfeeReceiverAddress);
        feeNumerator = newFeeNumerator;
    }

    function initiateAuction(
        IERC20 _auctionedToken,
        IERC20 _bidderToken,
        uint256 duration,
        uint96 _auctionedSellAmount,
        uint96 _minBuyAmount,
        uint256 minimumBiddingAmount
    ) public returns (uint256) {
        uint64 userId = getUserId(msg.sender);

        // withdraws sellAmount + fees
        _auctionedToken.safeTransferFrom(
            msg.sender,
            address(this),
            _auctionedSellAmount.mul(FEE_DENOMINATOR.add(feeNumerator)).div(
                FEE_DENOMINATOR
            )
        );
        require(
            minimumBiddingAmount > 0,
            "minimumBiddingAmount is not allowed to be zero"
        );
        auctionCounter++;
        auctionData[auctionCounter] = AuctionData(
            _auctionedToken,
            _bidderToken,
            block.timestamp + duration,
            IterableOrderedOrderSet.encodeOrder(
                userId,
                _minBuyAmount,
                _auctionedSellAmount
            ),
            minimumBiddingAmount,
            0,
            bytes32(0),
            bytes32(0),
            0,
            feeNumerator
        );
        emit NewAuction(auctionCounter, _auctionedToken, _bidderToken);
        return auctionCounter;
    }

    function placeSellOrders(
        uint256 auctionId,
        uint96[] memory _minBuyAmounts,
        uint96[] memory _sellAmounts,
        bytes32[] memory _prevSellOrders
    ) public atStageOrderPlacement(auctionId) returns (uint64 userId) {
        (
            ,
            uint96 buyAmountOfInitialAuctionOrder,
            uint96 sellAmountOfInitialAuctionOrder
        ) = auctionData[auctionId].initialAuctionOrder.decodeOrder();
        uint256 sumOfSellAmounts = 0;
        userId = getUserId(msg.sender);
        for (uint256 i = 0; i < _minBuyAmounts.length; i++) {
            require(
                _minBuyAmounts[i].mul(buyAmountOfInitialAuctionOrder) <
                    sellAmountOfInitialAuctionOrder.mul(_sellAmounts[i]),
                "limit price not better than mimimal offer"
            );
            // orders size should have a minimum size, in order
            // to limit price calculation gas consumption
            require(
                _minBuyAmounts[i] > auctionData[auctionId].minimumBiddingAmount,
                "order too small"
            );
            bool success =
                sellOrders[auctionId].insert(
                    IterableOrderedOrderSet.encodeOrder(
                        userId,
                        _minBuyAmounts[i],
                        _sellAmounts[i]
                    ),
                    _prevSellOrders[i]
                );
            if (success) {
                sumOfSellAmounts = sumOfSellAmounts.add(_sellAmounts[i]);
                emit NewSellOrder(
                    auctionId,
                    userId,
                    _minBuyAmounts[i],
                    _sellAmounts[i]
                );
            }
        }
        auctionData[auctionId].bidderToken.safeTransferFrom(
            msg.sender,
            address(this),
            sumOfSellAmounts
        );
    }

    function cancelSellOrders(
        uint256 auctionId,
        bytes32[] memory _sellOrders,
        bytes32[] memory _prevSellOrders
    ) public atStageOrderPlacement(auctionId) {
        uint64 userId = getUserId(msg.sender);
        uint256 claimableAmount = 0;
        for (uint256 i = 0; i < _sellOrders.length; i++) {
            (
                uint64 userIdOfIter,
                uint96 buyAmountOfIter,
                uint96 sellAmountOfIter
            ) = _sellOrders[i].decodeOrder();
            require(
                userIdOfIter == userId,
                "Only the user can cancel his orders"
            );
            if (
                sellOrders[auctionId].remove(_sellOrders[i], _prevSellOrders[i])
            ) {
                claimableAmount = claimableAmount.add(sellAmountOfIter);
                emit CancellationSellOrder(
                    auctionId,
                    userId,
                    buyAmountOfIter,
                    sellAmountOfIter
                );
            }
        }
        auctionData[auctionId].bidderToken.safeTransfer(
            msg.sender,
            claimableAmount
        );
    }

    function precalculateSellAmountSum(
        uint256 auctionId,
        uint256 iterationSteps
    ) public atStageSolutionSubmission(auctionId) {
        (, , uint96 auctioneerSellAmount) =
            auctionData[auctionId].initialAuctionOrder.decodeOrder();
        uint256 sumBiddedAmount = auctionData[auctionId].interimSumBiddedAmount;
        bytes32 iterOrder = auctionData[auctionId].interimOrder;
        if (iterOrder == bytes32(0)) {
            iterOrder = IterableOrderedOrderSet.QUEUE_START;
        }

        for (uint256 i = 0; i < iterationSteps; i++) {
            iterOrder = sellOrders[auctionId].next(iterOrder);
            (, , uint96 sellAmountOfIter) = iterOrder.decodeOrder();
            sumBiddedAmount = sumBiddedAmount.add(sellAmountOfIter);
        }

        // it is checked that not too many iteration steps were taken:
        // require that the sum of SellAmounts times the price of the last order
        // is not more than intially sold amount
        (, uint96 buyAmountOfIter, uint96 sellAmountOfIter) =
            iterOrder.decodeOrder();
        require(
            sumBiddedAmount.mul(buyAmountOfIter) <
                auctioneerSellAmount.mul(sellAmountOfIter),
            "too many orders summed up"
        );

        auctionData[auctionId].interimSumBiddedAmount = sumBiddedAmount;
        auctionData[auctionId].interimOrder = iterOrder;
    }

    // @dev function verifiying the auction price
    // @parameter price: This should either be a price encoded as an order
    // with userId = 0, priceNumerator = buyAmount, priceDenominator = sellAmount
    // or it should reference to the particular order settled only partially within
    // this auction.
    function verifyPrice(uint256 auctionId, bytes32 price)
        public
        atStageSolutionSubmission(auctionId)
    {
        (, uint96 priceNumerator, uint96 priceDenominator) =
            price.decodeOrder();
        (
            uint64 auctioneerId,
            uint96 auctioneerBuyAmount,
            uint96 auctioneerSellAmount
        ) = auctionData[auctionId].initialAuctionOrder.decodeOrder();
        require(priceNumerator > 0, "price must be postive");
        uint256 sumBiddedAmount = auctionData[auctionId].interimSumBiddedAmount;
        bytes32 iterOrder = auctionData[auctionId].interimOrder;
        if (iterOrder == bytes32(0)) {
            iterOrder = IterableOrderedOrderSet.QUEUE_START;
        }
        if (sellOrders[auctionId].size > 0) {
            iterOrder = sellOrders[auctionId].next(iterOrder);
            while (iterOrder != price && iterOrder.smallerThan(price)) {
                (, , uint96 sellAmountOfIter) = iterOrder.decodeOrder();
                sumBiddedAmount = sumBiddedAmount.add(sellAmountOfIter);
                iterOrder = sellOrders[auctionId].next(iterOrder);
            }
        }
        uint256 sumBuyAmount =
            sumBiddedAmount.mul(priceNumerator).div(priceDenominator);
        if (price == iterOrder) {
            // case 1: one sellOrder is partically filled
            // The partially filled order is the iterOrder, if:
            // 1) The sumBuyAmounts is not bigger than the intitial order's sell amount
            // i.e, sellAmount >= sumBuyAmount
            // 2) The volume of the particial order is not bigger than its sell volume
            // i.e. auctionData[auctionId].volumeClearingPriceOrder <= sellAmountOfIter,
            (, , uint96 sellAmountOfIter) = iterOrder.decodeOrder();
            uint256 clearingOrderBuyAmount =
                auctioneerSellAmount.sub(sumBuyAmount);
            // Attention: This conversion can prevent closing auctions, if rounding down
            // to uint96 does fail. Should not happen, unless token has more than 18 digits
            // or prices are huge.
            auctionData[auctionId].volumeClearingPriceOrder = (
                clearingOrderBuyAmount.mul(priceDenominator).div(priceNumerator)
            )
                .toUint64();
            require(
                auctionData[auctionId].volumeClearingPriceOrder <=
                    sellAmountOfIter,
                "order can not be clearing order"
            );
            auctionData[auctionId].clearingPriceOrder = iterOrder;
        } else {
            if (sumBuyAmount < auctioneerSellAmount) {
                // case 2: initialAuction order is partically filled
                // We require that the price was the initialOrderLimit price's inverse
                // as this ensures that the for-loop iterated through all orders
                // and all orders are considered
                require(
                    priceNumerator.mul(auctioneerBuyAmount) ==
                        auctioneerSellAmount.mul(priceDenominator),
                    "supplied price must be inverse initialOrderLimit"
                );
                auctionData[auctionId].volumeClearingPriceOrder = sumBuyAmount
                    .toUint64();
                auctionData[auctionId]
                    .clearingPriceOrder = IterableOrderedOrderSet.encodeOrder(
                    auctioneerId,
                    priceNumerator,
                    priceDenominator
                );
            } else {
                // case 3: no order is partically filled
                // In this case the sumBuyAmount must be equal to
                // the sellAmount of the initialAuctionOrder, without
                // any rounding errors.
                // This price is always existing as we can choose
                // priceNumerator = sellAmount and priceDenominator = sumSellAmount
                auctionData[auctionId].clearingPriceOrder = price;
                require(
                    sumBuyAmount == auctioneerSellAmount,
                    "price is not clearing price"
                );
                require(
                    priceNumerator.mul(auctioneerBuyAmount) <=
                        auctioneerSellAmount.mul(priceDenominator),
                    "clearing price is better than initialAuctionOrder"
                );
            }
        }

        emit AuctionCleared(auctionId, priceNumerator, priceDenominator);
        if (auctionData[auctionId].feeNumerator > 0) {
            claimFees(auctionId);
        }
        claimAuctioneerFunds(auctionId);
    }

    function claimFromParticipantOrder(
        uint256 auctionId,
        bytes32[] memory orders,
        bytes32[] memory previousOrders
    )
        public
        atStageFinished(auctionId)
        returns (uint256 sumAuctionedTokenAmount, uint256 sumBidderTokenAmount)
    {
        AuctionData memory auction = auctionData[auctionId];
        (, uint96 priceNumerator, uint96 priceDenominator) =
            auction.clearingPriceOrder.decodeOrder();
        (uint64 userId, , ) = orders[0].decodeOrder();
        for (uint256 i = 0; i < orders.length; i++) {
            require(
                sellOrders[auctionId].remove(orders[i], previousOrders[i]),
                "order is no longer claimable"
            );
            (uint64 userIdOrder, uint96 buyAmount, uint96 sellAmount) =
                orders[i].decodeOrder();
            require(
                userIdOrder == userId,
                "only allowed to claim for same user"
            );
            if (orders[i] == auction.clearingPriceOrder) {
                sumAuctionedTokenAmount = sumAuctionedTokenAmount.add(
                    auction.volumeClearingPriceOrder.mul(priceNumerator).div(
                        priceDenominator
                    )
                );
                sumBidderTokenAmount = sumBidderTokenAmount.add(
                    sellAmount.sub(auction.volumeClearingPriceOrder)
                );
            } else {
                if (orders[i].smallerThan(auction.clearingPriceOrder)) {
                    sumAuctionedTokenAmount = sumAuctionedTokenAmount.add(
                        sellAmount.mul(priceNumerator).div(priceDenominator)
                    );
                } else {
                    sumBidderTokenAmount = sumBidderTokenAmount.add(sellAmount);
                }
            }
            emit ClaimedFromOrder(auctionId, userId, buyAmount, sellAmount);
        }
        sendOutTokens(
            auctionId,
            sumAuctionedTokenAmount,
            sumBidderTokenAmount,
            userId
        );
    }

    function claimAuctioneerFunds(uint256 auctionId)
        internal
        returns (uint256 auctionedTokenAmount, uint256 bidderTokenAmount)
    {
        (uint64 auctioneerId, uint96 buyAmount, uint96 sellAmount) =
            auctionData[auctionId].initialAuctionOrder.decodeOrder();
        auctionData[auctionId].initialAuctionOrder = bytes32(0);
        (, uint96 priceNumerator, uint96 priceDenominator) =
            auctionData[auctionId].clearingPriceOrder.decodeOrder();
        if (priceNumerator.mul(buyAmount) == priceDenominator.mul(sellAmount)) {
            // In this case we have a partial match of the initialSellOrder
            auctionedTokenAmount = sellAmount.sub(
                auctionData[auctionId].volumeClearingPriceOrder
            );
            bidderTokenAmount = auctionData[auctionId]
                .volumeClearingPriceOrder
                .mul(priceDenominator)
                .div(priceNumerator);
        } else {
            bidderTokenAmount = sellAmount.mul(priceDenominator).div(
                priceNumerator
            );
        }
        sendOutTokens(
            auctionId,
            auctionedTokenAmount,
            bidderTokenAmount,
            auctioneerId
        );
    }

    function claimFees(uint256 auctionId) internal {
        (uint64 auctioneerId, uint96 buyAmount, uint96 sellAmount) =
            auctionData[auctionId].initialAuctionOrder.decodeOrder();
        (, uint96 priceNumerator, uint96 priceDenominator) =
            auctionData[auctionId].clearingPriceOrder.decodeOrder();
        uint256 feeAmount =
            sellAmount.mul(auctionData[auctionId].feeNumerator).div(
                FEE_DENOMINATOR
            );
        if (priceNumerator.mul(buyAmount) == priceDenominator.mul(sellAmount)) {
            // In this case we have a partial match of the initialSellOrder
            uint256 auctionedTokenAmount =
                sellAmount.sub(auctionData[auctionId].volumeClearingPriceOrder);
            sendOutTokens(
                auctionId,
                feeAmount.mul(auctionedTokenAmount).div(sellAmount),
                0,
                feeReceiverUserId
            );
            sendOutTokens(
                auctionId,
                feeAmount.mul(sellAmount.sub(auctionedTokenAmount)).div(
                    sellAmount
                ),
                0,
                auctioneerId
            );
        } else {
            sendOutTokens(auctionId, feeAmount, 0, feeReceiverUserId);
        }
    }

    function sendOutTokens(
        uint256 auctionId,
        uint256 auctionedTokenAmount,
        uint256 bidderTokenAmount,
        uint64 userId
    ) internal {
        address userAddress = registeredUsers.getAddressAt(userId);
        if (auctionedTokenAmount > 0) {
            auctionData[auctionId].auctionedToken.safeTransfer(
                userAddress,
                auctionedTokenAmount
            );
        }
        if (bidderTokenAmount > 0) {
            auctionData[auctionId].bidderToken.safeTransfer(
                userAddress,
                bidderTokenAmount
            );
        }
    }

    function registerUser(address user) public returns (uint64 userId) {
        require(
            registeredUsers.insert(numUsers, user),
            "User already registered"
        );
        userId = numUsers;
        numUsers = numUsers.add(1).toUint64();
        emit UserRegistration(user, userId);
    }

    function getUserId(address user) public returns (uint64 userId) {
        if (registeredUsers.hasAddress(user)) {
            return registeredUsers.getId(user);
        } else {
            return registerUser(user);
        }
    }

    function getSecondsRemainingInBatch(uint256 auctionId)
        public
        view
        returns (uint256)
    {
        if (auctionData[auctionId].auctionEndDate < block.timestamp) {
            return 0;
        }
        return auctionData[auctionId].auctionEndDate.sub(block.timestamp);
    }

    function containsOrder(uint256 auctionId, bytes32 order)
        public
        view
        returns (bool)
    {
        return sellOrders[auctionId].contains(order);
    }
}
