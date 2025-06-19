// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {console} from "forge-std/console.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDsc public deployer;
    DecentralisedStableCoin public dsc;
    DSCEngine public engine;
    HelperConfig public config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    address public DEBTOR = makeAddr("debtor");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 constant STARTING_LIQUIDATOR_BALANCE = 30 ether;
    uint256 public constant LIQUIDATOR_COLLATERAL_AMOUNT = 30 ether; // 30 ETH
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; // 10 ETH
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 100e18;
    uint256 public constant AMOUNT_COLLATERAL_TO_REDEEM = 5 ether; // 5 ETH

    function setUp() public {
        deployer = new DeployDsc();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, , ) = config
            .activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_LIQUIDATOR_BALANCE);
        ERC20Mock(weth).mint(DEBTOR, STARTING_ERC20_BALANCE);
    }

    // events
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

    //Modifiers

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);

        _;
        vm.stopPrank();
    }

    modifier depositCollateralForLiquidator() {
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);

        _;
        vm.stopPrank();
    }

    modifier depositCollateralToMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            AMOUNT_DSC_TO_MINT
        );

        _;
        vm.stopPrank();
    }

    /////////CONSTRUCTOR TESTS

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenAddressesAndPriceFeedAddressesAreNotSameLength()
        public
    {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////PRICE TESTS

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; // 15 ETH
        // Using $2000 as the price of 1 ETH, we expect to get $30000 as the USD value
        uint256 expectedUsdValue = 30000e18; // 30,000 USD
        uint256 actualUsdValue = engine.getUsdValue(weth, ethAmount);
        assertEq(actualUsdValue, expectedUsdValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether; // This is me saying it's $100, do not confuse with 100 eth.
        uint256 expectedWeth = 0.05 ether; // 100 / 2000 = 0.05 ETH, where 2000 is the price of 1 ETH in USD
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /////////DEPOSIT COLLATERAL TESTS

    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_AmountNeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock(
            "Random Token",
            "RND",
            USER,
            STARTING_ERC20_BALANCE
        );
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedTokenNormal = 10 ether; // 10 ETH
        uint256 tokenNormal = engine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        uint256 expectedDepositAmount = engine.getAccountCollateralValue(USER);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedDepositAmount, collateralValueInUsd);
        assertEq(expectedTokenNormal, tokenNormal);
    }

    function testCollateralRevertsIfZeroAddress() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        engine.depositCollateral(address(0), AMOUNT_COLLATERAL);
    }

    //Testing DepositCollateral and Minting DSC at the same time and after each other

    function testIfDscIsMintedWhenDepositingCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 100e18);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 100e18; // 100 DSC
        uint256 expectedCollateralValueInUsd = 20000e18; // 10 ETH * $2000 = $20,000
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
        vm.stopPrank();
    }

    function testRevertsWithHealthFactorBrokenWhenDepositingCollateralAndMintingDsc()
        public
    {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert();
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 100000e18);
        // 100,000 DSC with 10 ETH collateral at $2000 each means a health factor of 0.5
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0; // No DSC should be minted
        //Noticing an error(may not be an error), but when we depositcollateral and mintDsc and the health factor is broken, the depositCollaeral function reverts as well and we're not able to deposit collateral. I think this might not be bad, but in a real security audit, I might flag this as a low/medium.
        uint256 expectedCollateralValueInUsd = 0e18; // 10 ETH * $2000 = $20,000
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
        vm.stopPrank();
    }

    function testIfUserCanMintDscAfterDepositingCollateral()
        public
        depositCollateral
    {
        uint256 expectedDscToBeMinted = 100e18;
        engine.mintDsc(expectedDscToBeMinted);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);
        assertEq(totalDscMinted, expectedDscToBeMinted);
        assert(collateralValueInUsd > 0);
    }

    function testIfRevertsWhenMintingZeroDsc() public depositCollateral {
        vm.expectRevert(DSCEngine.DSCEngine_AmountNeedsMoreThanZero.selector);
        engine.mintDsc(0);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        assert(collateralValueInUsd > 0);
        console.log(totalDscMinted, collateralValueInUsd);
    }

    function testRevertsWhenMintingWithoutCollateral() public {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.mintDsc(100e18);
        vm.stopPrank();
        // There should be a custom error for when trying to mint without a collateral, instead of using the low health factor error
    }

    function testStateS_DSCMintedUpdatesAfterMinting()
        public
        depositCollateral
    {
        (uint256 dscBefore, ) = engine.getAccountInformation(USER);
        uint256 expectedDscToMint = 100e18;
        engine.mintDsc(expectedDscToMint);
        (uint256 dscAfter, ) = engine.getAccountInformation(USER);
        assertEq(dscAfter, dscBefore + expectedDscToMint);
    }

    function testActualDscTokensAreMinted() public depositCollateral {
        uint256 dscBalanceBefore = dsc.balanceOf(USER);
        assertEq(dscBalanceBefore, 0);
        // Mint DSC
        uint256 amountToMint = 100e18;
        engine.mintDsc(amountToMint);

        // Check DSC balance after minting
        uint256 dscBalanceAfter = dsc.balanceOf(USER);
        assertEq(dscBalanceAfter, amountToMint);
    }

    // Time to test BurnDsc and Probably Redeem Collateral Tests

    function testIfRedeemCollateralAndBurnDscWorks()
        public
        depositCollateralToMintDsc
    {
        uint256 dscBalanceBefore = dsc.balanceOf(USER);
        uint256 formerTokenBalance = engine.getUserTokenAmount(USER, weth);
        uint256 beforeReedeemWethBalance = ERC20Mock(weth).balanceOf(USER);
        (uint256 totalDscMinted, ) = engine.getAccountInformation(USER);
        //assertEq(dscBalanceBefore, totalDscMinted);
        dsc.approve(address(engine), totalDscMinted);
        engine.redeemCollateralForDsc(
            weth,
            AMOUNT_COLLATERAL_TO_REDEEM,
            totalDscMinted
        );
        uint256 dscBalanceAfter = dsc.balanceOf(USER);
        uint256 expectedDscBalanceAfter = dscBalanceBefore - totalDscMinted;
        uint256 newTokenBalance = engine.getUserTokenAmount(USER, weth);
        uint256 userAfterRedeemWethBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(dscBalanceAfter, expectedDscBalanceAfter);
        assertEq(
            newTokenBalance,
            formerTokenBalance - AMOUNT_COLLATERAL_TO_REDEEM
        );
        assert(
            userAfterRedeemWethBalance ==
                beforeReedeemWethBalance + AMOUNT_COLLATERAL_TO_REDEEM
        );
    }

    function testIfICanRedeemAllOfCollateralWithoutBurningDsc()
        public
        depositCollateralToMintDsc
    {
        // This test might reveal a bug in the redeemCollateralForDsc function, where it allows you to redeem all of your collateral without burning any DSC.
        //Coming back to this, I will put an expectRevert instead.
        uint256 dscBalanceBefore = dsc.balanceOf(USER); // dsc balance before redeeming
        uint256 formerTokenBalance = engine.getUserTokenAmount(USER, weth); //eth token deposited in dsc engine before redeeming
        vm.expectRevert();
        engine.redeemCollateral(weth, formerTokenBalance);
        uint256 dscBalanceAfter = dsc.balanceOf(USER); // dsc balance after redeeming
        assertEq(dscBalanceAfter, dscBalanceBefore); // dsc balance should be the same as before redeeming if the bug is really there
    }
    //I just realised it would revert because the health factor would be broken, so I will not test this. But I will leave the code here for future reference.

    function testIfRedeemCollateralRevertsWithZeroAddress()
        public
        depositCollateral
    {
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        engine.redeemCollateral(address(0), AMOUNT_COLLATERAL_TO_REDEEM);
    }

    function testIfRedeemCollateralRevertsWithZeroAmount()
        public
        depositCollateral
    {
        vm.expectRevert(DSCEngine.DSCEngine_AmountNeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
    }

    function testRevertsWhenUserTriesToBurnMoreDscThanTheyHave()
        public
        depositCollateralToMintDsc
    {
        //There might be a bug in the burn function of the DecentralisedStableCoin contract, where it allows you to burn more DSC than you have.
        (uint256 dscBalance, ) = engine.getAccountInformation(USER);
        uint256 amountToBurn = dscBalance + 1; // Trying to burn more than the balance
        vm.expectRevert();
        engine.burnDsc(amountToBurn);
    }

    function testIfBurnDscWorks() public depositCollateralToMintDsc {
        (uint256 dscBalanceBefore, ) = engine.getAccountInformation(USER);
        uint256 amountToBurn = dscBalanceBefore / 2; // Burn half of the DSC balance
        dsc.approve(address(engine), amountToBurn);
        engine.burnDsc(amountToBurn);
        (uint256 dscBalanceAfter, ) = engine.getAccountInformation(USER);
        assertEq(dscBalanceAfter, dscBalanceBefore - amountToBurn);
    }

    function testRedeemCollateralEmitsEvent()
        public
        depositCollateralToMintDsc
    {
        (uint256 dscBalanceBefore, ) = engine.getAccountInformation(USER);
        uint256 amountToRedeem = AMOUNT_COLLATERAL_TO_REDEEM;
        dsc.approve(address(engine), dscBalanceBefore);
        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(USER, USER, weth, amountToRedeem);
        engine.redeemCollateralForDsc(weth, amountToRedeem, dscBalanceBefore);
    }

    //Testing Liquidation
    function testIfLiquidationWorks() public {
        // This test will check if the liquidation works as expected
        // First, we need to mimic a broken health factor by dropping the price of eth to usd
        //OUR VARIABLES
        uint256 userDscToMint = 8000e18; // 8000 DSC (remember user has 10eth which is $20,000 at $2000 per eth, if eth drops to $1000, the user is liable to liquidation)
        uint256 minimumHealthFactor = engine.getMinHealthFactor();

        //Let us set up the user first
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            userDscToMint
        );
        console.log(
            "User has deposited collateral and minted DSC",
            userDscToMint,
            ERC20Mock(weth).balanceOf(USER),
            "WETH balance of user"
        );
        vm.stopPrank();
        //Now we need to set the price of eth to usd to $1000
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1000e8); //Reduces the HF of the user to less than 1.
        (uint256 userDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);
        console.log(
            "User DSC minted:",
            userDscMinted,
            "Collateral value in USD:",
            collateralValueInUsd
        );

        //Now we need to check the health factor of the user
        uint256 userHealthFactor = engine.getHealthFactor(USER);
        assert(userHealthFactor < minimumHealthFactor);

        //Now we need to set up the liquidator
        uint256 liquidatorDscToMint = 10000e18; // 10000 DSC
        uint256 debtToCover = 7000e18; // 7000 DSC, this is the amount of DSC the liquidator will cover

        //Let us mimic the liquidator doing stuff like depositing, minting and liqidating
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), LIQUIDATOR_COLLATERAL_AMOUNT);
        engine.depositCollateralAndMintDsc(
            weth,
            LIQUIDATOR_COLLATERAL_AMOUNT,
            liquidatorDscToMint
        );
        (uint256 liquidatorDscMinted, ) = engine.getAccountInformation(
            LIQUIDATOR
        );
        //Now liquidator has to approve the engine to spend their dsc for liquidation
        dsc.approve(address(engine), debtToCover);
        engine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
        //Now we need to check if the liquidation was successful
        // Initially we used engine.getAccountInformation(LIQUIDATOR) to check for the liquidator's dsc balance but this is wrong as we get updated from s_DSCMinted mapping. The liquidator still owes us $10,000 just that they used $7000 to cover the user's debt. So we need to check the liquidator's dsc balance directly from the dsc contract.
        uint256 liquidatorDscBalance = dsc.balanceOf(LIQUIDATOR);
        assertEq(liquidatorDscMinted - debtToCover, liquidatorDscBalance);

        uint256 liquidatorWalletBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 liquidatorCollateralDeposit = engine.getUserTokenAmount(
            LIQUIDATOR,
            weth
        );
        uint256 liquidatorTotalAssets = liquidatorWalletBalance +
            liquidatorCollateralDeposit;
        // In the above loc, we wre using balanceOf instead of getAccountInformation because the liquidator has locked 30eth as their collateral, and getAccountInformation gets just that, but we need to be sure that the liquidators total balance is more than the collateral they deposited, as they should havee about 37.7 eth after liquidation.(7.7 eth is from the liquidation of the user, and 30 eth is from their collateral deposit)
        assert(liquidatorTotalAssets > LIQUIDATOR_COLLATERAL_AMOUNT);
        // Check if the user health factor is now above 1 and more then their previous health factor
        uint256 userHealthFactorAfter = engine.getHealthFactor(USER);
        assert(userHealthFactorAfter > userHealthFactor);
        assert(userHealthFactorAfter > minimumHealthFactor);
    }

    function testSimplePriceUpdate() public {
        console.log("Original ETH price: 2000");

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1000e8);

        (, int256 newPrice, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        console.log("New ETH price:", uint256(newPrice) / 1e8);

        assertEq(newPrice, 1000e8);
    }

    function testCannotLiquidateAHealthyUser() public {
        uint256 userDscToMint = 8000e18; // 8000 DSC
        uint256 minimumHealthFactor = engine.getMinHealthFactor();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            userDscToMint
        );
        vm.stopPrank();
        // Let us check the user's health factor
        uint256 userHealthFactor = engine.getHealthFactor(USER);
        assert(userHealthFactor > minimumHealthFactor);

        // Now let us try to liquidate the user
        vm.startPrank(LIQUIDATOR);
        uint256 debtToCover = 7000e18; // 7000 DSC, this is the amount of DSC the liquidator will cover
        uint256 liquidatorDscToMint = 10000e18; // 10000 DSC
        ERC20Mock(weth).approve(address(engine), LIQUIDATOR_COLLATERAL_AMOUNT);
        engine.depositCollateralAndMintDsc(
            weth,
            LIQUIDATOR_COLLATERAL_AMOUNT,
            liquidatorDscToMint
        );
        dsc.approve(address(engine), debtToCover);
        bytes memory expectedError = abi.encodeWithSelector(
            DSCEngine.DSCEngine_HealthFactorIsOkay.selector,
            userHealthFactor
        );
        vm.expectRevert(expectedError);
        //DSCEngine.DSCEngine_HealthFactorIsOkay(userHealthFactor)
        engine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }
}
