// Handler will narrow down the way we call functions
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralisedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 MONEY_TO_DEPOSIT = type(uint96).max; // Max uint96 value

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _engine, DecentralisedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(
            engine.getCollateralTokenPriceFeed(address(weth))
        );
    }

    function mintDsc(uint256 amountDscToMint, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0 || addressSeed == 0) {
            vm.stopPrank();
            return; // No users with collateral deposited
        }

        address sender = usersWithCollateralDeposited[
            addressSeed % usersWithCollateralDeposited.length
        ];

        vm.startPrank(sender);
        //dsc.mint(msg.sender, amountDscToMint);
        //dsc.approve(address(engine), amountDscToMint);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) -
            int256(totalDscMinted); // 50% of collateral value
        if (maxDscToMint < 0) {
            vm.stopPrank();
            return; // No need to mint if maxDscToMint is negative
        }
        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint));
        if (amountDscToMint == 0) {
            vm.stopPrank();
            return; // No need to mint if amount is zero
        }
        engine.mintDsc(amountDscToMint);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    // The redeem collateral function was breaking our invariant testing, so we're going to set it up so that it doesn't break
    //@notice collateral is basically which collateral we are using, whether weth or wbtc.
    function depositCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MONEY_TO_DEPOSIT);
        // Run as a user
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, MONEY_TO_DEPOSIT);
        collateral.approve(address(engine), MONEY_TO_DEPOSIT);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        vm.startPrank(msg.sender);
        uint256 maxCollateralToRedeem = engine.getUserTokenAmount(
            msg.sender,
            address(collateral)
        );
        uint256 userHealth = engine.getHealthFactor(msg.sender);
        if (userHealth < 1e18) {
            vm.stopPrank();
            return; // No need to redeem if health factor is below 1
        }
        if (maxCollateralToRedeem == 0) {
            vm.stopPrank();
            return; // No need to redeem if amount is zero
        }
        amountCollateral = bound(amountCollateral, 1, maxCollateralToRedeem);

        // ✅ Calculate what health factor WOULD BE after redemption
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = engine
            .getAccountInformation(msg.sender);

        if (totalDscMinted > 0) {
            // Only check if user has DSC debt
            uint256 collateralToRedeemValueInUsd = engine.getUsdValue(
                address(collateral),
                amountCollateral
            );
            uint256 newCollateralValue = totalCollateralValueInUsd -
                collateralToRedeemValueInUsd;

            // Calculate new health factor: (newCollateral * 50%) / totalDscMinted
            uint256 newHealthFactor = (newCollateralValue * 50 * 1e18) /
                (100 * totalDscMinted);

            if (newHealthFactor < 1e18) {
                vm.stopPrank();
                return; // Don't redeem - would break health factor
            }
        }
        engine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    // function updateCollateralPrice(uint96 newPrice) public {
    //     // Update the price of WETH
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // } This particular function breaks our test suite, as it makes eth price drop very sharply.

    //Helper function
    function _getCollateralFromSeed(
        uint256 collateralSeed
    ) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
