// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCENGINE__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCENGINE__HealthFactorIsOkay();
    error DSCENGINE__HealthFactorNotImproved();

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;

    address public USER = makeAddr("user");
    address public DEBTOR = makeAddr("DEBTOR");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DEBTOR_STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant LIQUIDATOR_STARTING_ERC20_BALANCE = 100 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant DEBTOR_AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant LIQUIDATOR_AMOUNT_COLLATERAL = 50 ether;

    uint256 public constant MINT_AMOUNT = 1 ether;
    uint256 public constant DEBTOR_MINT_AMOUNT = 1 ether;
    uint256 public constant LIQUIDATOR_MINT_AMOUNT = 5 ether;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
    //                      Constructor tests                     //
    //////////////////////////////////////////////////////////////*/

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoestMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
    //                         PRICEFEEDTESTS                     //
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000 = 3000
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);

        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    /*//////////////////////////////////////////////////////////////
    //                          BURNDSC TEST                      //
    //////////////////////////////////////////////////////////////*/

    // Deposit collateral and mint DSC for testing
    modifier depositedAndMinted() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.mintDSC(MINT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testBurnDSCRevertsIfAmountToBeBurnedIsZero() public depositedAndMinted {
        // Expect revert due to zero amount
        vm.expectRevert(DSCEngine__MustBeMoreThanZero.selector);
        // Act
        vm.prank(USER);
        dscEngine.burnDSC(0);
    }

    function testIBurnDscRevertsIfAmountDscToBurnIsGreaterThanDSCMintedByParticipant() public {
        // Expect revert due to zero amount
        vm.expectRevert();
        // Act
        vm.prank(USER);
        dscEngine.burnDSC(MINT_AMOUNT);
    }

    function testBurnDSCWorks() public depositedAndMinted {
        vm.startPrank(USER);

        dsc.approve(address(dscEngine), MINT_AMOUNT);
        dscEngine.burnDSC(MINT_AMOUNT);
        vm.stopPrank();

        uint256 remainingUserBalance = dsc.balanceOf(USER);
        assertEq(remainingUserBalance, 0);
    }

    /*//////////////////////////////////////////////////////////////
    //                              Mint DSC                     //
    //////////////////////////////////////////////////////////////*/

    function testMintDSCRevertsIfZeroAmount() public depositedCollateral {
        // Expect revert due to zero amount
        vm.expectRevert(DSCEngine__MustBeMoreThanZero.selector);

        // Act
        vm.prank(USER);
        dscEngine.mintDSC(0);
    }

    // mint fails if collateral is not enough
    function testMintDSCRevertsIfHealthFactorBroken() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));

        vm.startPrank(USER);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCENGINE__BreaksHealthFactor.selector, expectedHealthFactor));
        // Act
        // Set up scenario where health factor will break
        dscEngine.mintDSC(amountToMint); // Hypothetically high amount to break health factor
        vm.stopPrank();
    }

    function testMintDSCWorks() public depositedCollateral {
        vm.startPrank(USER);
        dscEngine.mintDSC(MINT_AMOUNT);
        vm.stopPrank();

        uint256 remainingUserBalance = dsc.balanceOf(USER);
        assertEq(remainingUserBalance, MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
    //                     Deposit collateral                     //
    //////////////////////////////////////////////////////////////*/

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock hackToken = new ERC20Mock("HackToken", "HT", USER, STARTING_ERC20_BALANCE);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(hackToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedCollateralValueInUsd);
    }

    /*//////////////////////////////////////////////////////////////
    //                       REDEEM COLLATERAL                   //
    //////////////////////////////////////////////////////////////*/

    // 10 ether Starting ERC balance 10 ether collateral 1 ether Minted DSC
    modifier redeemCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.mintDSC(MINT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testRedeemCollateralForDSCSucceeds() public redeemCollateral {
        uint256 amountDscToBurn = 0.25 ether; // Assume this amount keeps the health factor safe
        uint256 amountCollateralToRedeem = 0.5 ether; // Choose a safe amount of collateral

        // USER burns DSC and redeems collateral
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountDscToBurn);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateralToRedeem);
        dscEngine.redeemCollateralForDSC(weth, amountCollateralToRedeem, amountDscToBurn);
        // Assertions
        uint256 remainingDscBalance = dsc.balanceOf(USER);
        uint256 remainingCollateral = dscEngine.getCollateralBalanceOfUser(weth, USER);
        // Check that the DSC balance has decreased by the burned amount
        assertEq(remainingDscBalance, MINT_AMOUNT - amountDscToBurn, "DSC balance has decreased");
        // Check that the collateral balance has decreased by the redeemed amount
        assertEq(
            remainingCollateral,
            AMOUNT_COLLATERAL - amountCollateralToRedeem,
            "collateral balance has decreased appropriately"
        );
        // Ensure that the user's health factor is above the minimum
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        assertTrue(userHealthFactor >= dscEngine.getMinimumHealthFactor());
    }

    function testRedeemCollateralForDSCRevertsIfHealthFactorBroken() public redeemCollateral {
        uint256 amountDscToBurn = 0.25 ether; // initially minted 1 ether  -> burnt 0.25 ether -> (1 - 0.25) remaining DSC Minted
        uint256 amountCollateralToRedeem = 9.5 ether; // 0.5 ether -> 0.5 *  1000 -> 500 mint??

        //  7.5e17

        // Mint some DSC to USER so they can burn it
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountDscToBurn);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateralToRedeem);

        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 amountToMint = (
            (AMOUNT_COLLATERAL - amountCollateralToRedeem) * (uint256(price) * dscEngine.getAdditionalFeedPrecision())
        ) / dscEngine.getPrecision();
        dscEngine.mintDSC(amountToMint);

       
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(
            amountToMint + MINT_AMOUNT - amountDscToBurn, dscEngine.getUsdValue(weth, (AMOUNT_COLLATERAL - amountCollateralToRedeem))
        );

        // implement code to get AMOUNT_COLLATERAL - amountCollateralToRedeem and accurate health factor by utilizing latest round data
        // (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // uint256 amountToMint =
        //     (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        // uint256 expectedHealthFactor =
        //     dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));
        // Attempt to redeem more collateral than the health factor allows
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCENGINE__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.redeemCollateralForDSC(weth, amountCollateralToRedeem, amountDscToBurn);
    }

    // redeemCollateral -> redeems collateral without burning DSC

    // morethanzero modifier works
    function testRedeemCollateralRevertsIfReedeemAmountIsZero() public redeemCollateral {
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        // Act and Assert
        vm.expectRevert(DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
    }

    // allowedToken
    function testRedeemCollateralRevertsIfTokenIsNotAllowed() public redeemCollateral {
        // Arrange
        ERC20Mock hackToken = new ERC20Mock("HackToken", "HT", USER, STARTING_ERC20_BALANCE);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.redeemCollateral(address(hackToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfRedeemAmountIsMoreThanCollateralAtDisposal() public redeemCollateral {
        uint256 amountCollateralToRedeem = 11 ether; // amount collateral is 10 ether
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateralToRedeem);

        // Act and Assert
        vm.expectRevert(DSCEngine.DSCEngine__NotEnoughCollateral.selector);
        dscEngine.redeemCollateral(weth, amountCollateralToRedeem);
    }

    function testRedeemCollateralRevertsIfHealthFactorIsNotSafe() public redeemCollateral {
        uint256 amountCollateralToRedeem = 9.5 ether; // .5 ether -> .5 * $ethUSD collateral
        // amount collateral is 10 ether 1 is minted we have 200% overcollateralization
        // to keep health factor safe we have to keep atleast 2 ether collateral, so if we redeem 8.1 ether
        // we will break health factor
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateralToRedeem);

        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        console.log("Price: ", price);
        uint256 amountToMint = (
            (AMOUNT_COLLATERAL - amountCollateralToRedeem) * (uint256(price) * dscEngine.getAdditionalFeedPrecision())
        ) / dscEngine.getPrecision();
        dscEngine.mintDSC(amountToMint);

        
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(
            amountToMint + MINT_AMOUNT, dscEngine.getUsdValue(weth, (AMOUNT_COLLATERAL - amountCollateralToRedeem))
        );

        // Act and Assert
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCENGINE__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.redeemCollateral(weth, amountCollateralToRedeem);
        // console.log("Expected Health Factor: ", dscEngine.getHealthFactor(USER));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
    //                           LIQUIDATE
    //////////////////////////////////////////////////////////////*/


    // modifier idea will be to change the pricefeed data after initializing the debtor so for example
    // eth -> 1000 usd to eth -> 100 usd then we can liquidate
    // modifier liquidatorSetup() {
    //     // Set up the account
    //     // Account Starting_ERC20_balance Collateral DSC_MINTED
    //     // DEBTOR  10  10 1
    //     // LIQUDATOR 100 50 5
    //     // price 2000 

    //     ERC20Mock(weth).mint(DEBTOR, DEBTOR_STARTING_ERC20_BALANCE);
    //     ERC20Mock(weth).mint(LIQUIDATOR, LIQUIDATOR_STARTING_ERC20_BALANCE);

    //     (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
    //      uint256 debtorAmountToMint = (
    //         (DEBTOR_AMOUNT_COLLATERAL /2 ) * (uint256(price) * dscEngine.getAdditionalFeedPrecision())
    //     ) / dscEngine.getPrecision();
    //      uint256 liquidatorAmountToMint = (
    //         (LIQUIDATOR_AMOUNT_COLLATERAL / 2 ) * (uint256(price) * dscEngine.getAdditionalFeedPrecision())
    //     ) / dscEngine.getPrecision();

    //     vm.startPrank(DEBTOR);
    //     ERC20Mock(weth).approve(address(dscEngine), DEBTOR_AMOUNT_COLLATERAL);
    //     dscEngine.depositCollateral(weth, DEBTOR_AMOUNT_COLLATERAL);
    //     dscEngine.mintDSC(debtorAmountToMint);
    //     vm.stopPrank();
    //     console.log(dscEngine.getHealthFactor(DEBTOR));

    //     vm.startPrank(LIQUIDATOR);
    //     ERC20Mock(weth).approve(address(dscEngine), LIQUIDATOR_AMOUNT_COLLATERAL);
    //     dscEngine.depositCollateral(weth, LIQUIDATOR_AMOUNT_COLLATERAL);
    //     dscEngine.mintDSC(liquidatorAmountToMint);
    //     vm.stopPrank();
    //     _;
    // }

    // function testDummyFunc() public liquidatorSetup {
    //     uint256 amountCollateralToRedeem = 9.5 ether; // .5 ether -> .5 * $ethUSD collateral
    //     // amount collateral is 10 ether 1 is minted we have 200% overcollateralization
    //     // to keep health factor safe we have to keep atleast 2 ether collateral, so if we redeem 8.1 ether
    //     // we will break health factor
    //     // Arrange
    //     vm.startPrank(DEBTOR);
    //     ERC20Mock(weth).approve(address(dscEngine), amountCollateralToRedeem);
    //     dscEngine.redeemCollateral(weth, amountCollateralToRedeem);
    //     assertEq(dscEngine.getHealthFactor(DEBTOR), 200);

    // }

/* 
    function testLiquidateSucceedsAndImprovesHealthFactor() public liquidatorSetup {
        vm.prank(DEBTOR);
        dscEngine.mintDSC(DEBTOR_MINT_AMOUNT * 5);
        console.log(dscEngine.getHealthFactor(DEBTOR));

        // 10000000000000000000000
        // 1666666666666666666666666

        // Set up the liquidation
        uint256 debtToCover = 6 ether; // Amount of DSC to burn
        address collateral = weth; // Collateral token address
        uint256 bonusCollateralAmount = dscEngine.getLiquidationBonus(collateral, debtToCover);

        // Ensure the `user` has a low health factor by manipulating prices or borrowing too much.
        // Assume this setup is done here, and the user's health factor is already below MIN_HEALTH_FACTOR.

        uint256 startingUserHealthFactor = dscEngine.getHealthFactor(DEBTOR);

        // Liquidator burns `debtToCover` DSC in exchange for `totalCollateralToRedeem`
        vm.prank(LIQUIDATOR); // LIQUIDATOR acts as the caller
        dscEngine.liquidate(collateral, DEBTOR, debtToCover);

        // Check the user's collateral balance to ensure some was redeemed
        uint256 userRemainingCollateral = dscEngine.getCollateralBalanceOfUser(collateral, DEBTOR);
        uint256 liquidatorCollateralBalance = dscEngine.getCollateralBalanceOfUser(collateral, LIQUIDATOR);

        // Assert collateral transfer with bonus
        assertEq(liquidatorCollateralBalance, bonusCollateralAmount);

        // Check health factor of `user` to confirm improvement
        uint256 endingUserHealthFactor = dscEngine.getHealthFactor(DEBTOR);
        assertTrue(endingUserHealthFactor > startingUserHealthFactor);
        assertTrue(endingUserHealthFactor >= dscEngine.getMinimumHealthFactor());
    }

    function testLiquidateRevertsIfHealthFactorAboveMinimum() public depositedAndMinted liquidatorSetup {
        uint256 debtToCover = 10 ether;
        address collateral = weth;

        // Ensure USER has a safe health factor before liquidation
        uint256 safeHealthFactor = dscEngine.getHealthFactor(USER);
        assertTrue(safeHealthFactor >= dscEngine.getMinimumHealthFactor());

        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCENGINE__HealthFactorIsOkay.selector);
        dscEngine.liquidate(collateral, USER, debtToCover);
    }

    function testLiquidateRevertsIfDebtToCoverIsZero() public depositedAndMinted liquidatorSetup {
        uint256 debtToCover = 0;
        address collateral = weth;

        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.liquidate(collateral, USER, debtToCover);
    }

    function testLiquidateRevertsIfHealthFactorNotImproved() public depositedAndMinted liquidatorSetup {
        uint256 debtToCover = 1 ether; // A small amount that won't significantly improve health factor
        address collateral = weth;

        // Simulate a condition where debtToCover isn't sufficient to improve health factor meaningfully
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCENGINE__HealthFactorNotImproved.selector);
        dscEngine.liquidate(collateral, USER, debtToCover);
    }

    function testPartialLiquidationReducesDebtAndRewardsLiquidator() public depositedAndMinted liquidatorSetup {
        uint256 initialDebtToCover = 100 ether; // USER's total DSC debt
        uint256 partialDebtToCover = 40 ether; // LIQUIDATOR covers part of the debt
        address collateral = weth;

        // Assume user has low health factor
        uint256 startingUserCollateralBalance = dscEngine.getCollateralBalanceOfUser(collateral, USER);
        uint256 liquidatorStartingCollateralBalance = dscEngine.getCollateralBalanceOfUser(collateral, LIQUIDATOR);

        vm.prank(LIQUIDATOR);
        dscEngine.liquidate(collateral, USER, partialDebtToCover);

        // Check that partial debt has been burned and collateral rewarded to the liquidator
        uint256 userRemainingDebt = dscEngine.getDebtBalance(USER);
        uint256 liquidatorNewCollateralBalance = dscEngine.getCollateralBalanceOfUser(collateral, LIQUIDATOR);

        // Ensure partial debt has been reduced from USER's balance
        assertEq(userRemainingDebt, initialDebtToCover - partialDebtToCover);

        // Check that LIQUIDATOR's collateral balance increased by the correct amount
        uint256 expectedBonusCollateral = dscEngine.getLiquidationBonus(collateral, partialDebtToCover);
        assertEq(liquidatorNewCollateralBalance, liquidatorStartingCollateralBalance + expectedBonusCollateral);

        // Check that USER's health factor has improved, even if partial
        uint256 endingUserHealthFactor = dscEngine.getHealthFactor(USER);
        assertTrue(endingUserHealthFactor > dscEngine.getMinimumHealthFactor());
    }  */
}
