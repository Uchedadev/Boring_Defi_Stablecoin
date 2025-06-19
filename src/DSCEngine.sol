// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;
import {DecentralisedStableCoin} from "./DecentralisedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
* @title DSCEngine
 * @author Mary
 * @notice This system is designed to be as minimal as possible. Our aim is to make sure that the token maintains its peg to the USD, i.e 1 DSC = 1 USD.
 @notice This contract is responsible for the core logic of the Decentralised Stable Coin (DSC) system.
    * @dev This contract will handle collateral deposits, withdrawals, and minting/burning of the DSC token.
    It is loosely based on the DAI and MakerDAO system, but with a focus on simplicity and minimalism, and it will not be goverened.
    We must ensure that the system is overcollateralised, i.e. the value of the collateral must always be greater than the value of the DSC minted.
 * @dev This contract is not intended to be used in production, it is for educational purposes only. 
 */

contract DSCEngine is ReentrancyGuard {
    ///////
    //Errors
    error DSCEngine_AmountNeedsMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_TransferFailed();
    error DSCEngine_HealthFactorBroken(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_HealthFactorIsOkay(uint256 healthFactor);
    error DSCEngine_HealthFactorNotImproved(uint256 healthFactor);
    error DSCEngine_NotEnoughCollateralToRedeem();
    error DSCEngine_InsufficientDSC();

    //Types
    using OracleLib for AggregatorV3Interface;

    ///////
    //State Variables
    mapping(address token => address priceFeed) private s_priceFeeds; // Maps token addresses to their price feed addresses
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposits; // Maps user addresses to their collateral deposits
    mapping(address user => uint256 dscMinted) private s_DSCMinted; // Maps user addresses to the amount of DSC minted
    address[] private s_collateralTokens;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 50%
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    DecentralisedStableCoin private immutable i_dsc; // The Decentralised Stable Coin contract

    ////////
    //Events
    event CollateralDeposits(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    ////////
    //Modifiers
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine_AmountNeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    ////////
    //Functions

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]); // Store the collateral token addresses
        }
        i_dsc = DecentralisedStableCoin(dscAddress);
    }

    ////////
    //External Functions

    /*
     * @notice This function allows users to deposit collateral and mint DSC tokens in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of DSC tokens to mint.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     *@notice This function allows users to deposit collateral into the system.
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposits[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral; // Update the user's collateral deposit
        emit CollateralDeposits(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }
    /*
     *@notice This function allows users to redeem their collateral for DSC tokens.
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC tokens to burn.
     * @dev This function will burn the specified amount of DSC tokens and then redeem the collateral in one transaction.
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external isAllowedToken(tokenCollateralAddress) {
        if (s_DSCMinted[msg.sender] < amountDscToBurn)
            revert DSCEngine_InsufficientDSC();
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // RedeemCollateral will check if the health factor is still above the minimum threshold
    }

    /*
    *@notice This function allows users to redeem their collateral.
    //In order to redeem collateral, health factor must be above the minimum threshold AFTER the collateral is pulled out.
    *
    */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        if (
            s_collateralDeposits[msg.sender][tokenCollateralAddress] <
            amountCollateral
        ) {
            revert DSCEngine_NotEnoughCollateralToRedeem();
        }
        // We will first check if the user has enough collateral to redeem

        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        // After redeeming collateral, we need to check if the health factor is still above the minimum threshold
        revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @notice This function allows users to mint DSC tokens by depositing collateral.
     * We check if 
     1. collateral value > DSC amount
     @param amountDscToMint The amount of DSC tokens to mint.
     @notice They must have more collateral value than the minimum threshold.
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint; // Update the user's DSC minted
        // If user mints wayy more than they can afford, revert
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender); // Not sure if we need this as we already check for this in function redeemCOllateral, but it might be useful as a backup.
    }

    // This function will help a user liquidate another user if the other user's health factor is below the minimum threshold.
    /*
     *@param collateral is the erc20 collateral token address to liquidate from the liquidated user.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        // Need to check if the user has a health factor below the minimum threshold
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorIsOkay(startingHealthFactor);
        }

        // We will burn the user's DSC tokens to cover the debt, and then transfer the collateral to the liquidator.
        // Eg: If the user has $145 worth of collateral and have minted $100 worth of dsc, the liquidator will burn $100 worth of token and then get the collateral worth $145.
        // We might probably just give the liquidator a 10% bonus on the collateral, so they get $110 worth of collateral, and we can take up the rest of the collateral as a fee for the protocol.
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; // 10% bonus
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        // And now we will finally redeem the collateral from the liquidated user and transfer to the liquidator.
        _redeemCollateral(
            collateral,
            totalCollateralToRedeem,
            user,
            msg.sender
        );
        // Now we will burn the user's DSC tokens to cover the debt
        _burnDsc(debtToCover, user, msg.sender); // We are burning the DSC tokens on behalf of the user, so we can cover the debt.
        // We also need to check
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorNotImproved(endingUserHealthFactor);
        }
        revertIfHealthFactorIsBroken(msg.sender); // Check if the liquidator's health factor is still above the minimum threshold
    }

    ////////
    //Private & Internal view Functions

    /*
     *@notice This function burns the specified amount of DSC tokens on behalf of the user.
     * @param amountDscToBurn The amount of DSC tokens to burn.
     * @param burningOnBehalfOf The address of the user who is being burned, that is the liquidated user who we are subtracting the DSC from.
     * @param dscFrom the liquidator address, we are actually taking dsc from the liquidator, so we can burn it.
     @dev this is a low-level function, do not call it directly unless the function calling it also checks for the health factor of the user.
     */
    function _burnDsc(
        uint256 amountDscToBurn,
        address burningOnBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[burningOnBehalfOf] -= amountDscToBurn; // Update the user's DSC minted
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private moreThanZero(amountCollateral) {
        s_collateralDeposits[from][tokenCollateralAddress] -= amountCollateral; // Update the user's collateral deposit
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function _getAccountInfo(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     *@notice This function calculates the health factor for a user.
     * @dev The health factor is a measure of the user's collateralisation ratio.
     * If the health factor is below 1, the user can be liquidated.
     */
    function _healthFactor(address user) private view returns (uint256) {
        //Get total collateral value
        // Get total DSC minted
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInfo(user);
        if (totalDscMinted == 0) {
            return type(uint256).max; //When a user has no dsc minted, their health factor is considered to be infinite, so we return the max value of uint256.
        }
        // return (collateralValueInUsd / totalDscMinted); //This might not work as solidity does not support decimal figures
        uint256 collateralAdjustedForThreshHold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshHold * PRECISION) / totalDscMinted;
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Checks health factor (if they have enough collateral to cover the DSC minted)
        // 2. If not, revert with an error message
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorBroken(userHealthFactor);
        }
    }

    ///////
    //Public & External view Functions

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        // The worth of the collateral is given by the pricefeed, and it comes in usd. We want to get the amount of the token that is worth the usd amount. The math will be like this:
        // amountToken = (priceOfTokenInDollar * 1e18) / (priceFeed * 1e10)
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        // We will loop through each collateral token that the use has, get the amount they have deposited, and map it to the price to get the usd value.

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposits[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // If 1 eth were equal to 2000 usd, then 1 eth = 2000 usd. From the chainlink price feed the value of usd is returned in 8 decimals, so we adjust to get it up to 18 decimals.
        // So wed multiply whatever we get from the price feed by 10^10(Which is now the state variable ADDITIONAL_FEED_PRECISION) to get it up to 18 decimals. Also, I think the amount we'd get from the user is not in 18 decimals, so we'd multiply it by 1e18 (Which is now the state variable PRECISION) as well. And then multilply the two together, which will give us how much the user has in usd, but its raised to 18 decimals.
        //On a second thought, the amount the user has will come in 18 decimals, so we'd multiply the price by ADDITIONAL_FEED_PRECISION, which is 1e10, and then multiply it by the amount the user has, which is in 18 decimals, and then divide the whole thing by 1e18 to get the final value in usd.

        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInfo(user);
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposits[user][token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice Gets the amount of a specific token a user has deposited
     * @param user The address of the user
     * @param token The address of the token contract
     * @return The amount of tokens deposited (in wei/smallest unit)
     */
    function getUserTokenAmount(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposits[user][token];
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeeds[token];
    }
}
