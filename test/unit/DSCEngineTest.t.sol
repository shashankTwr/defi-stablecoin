// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

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
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MINT_AMOUNT = 1 ether;
    uint256 public LIQUIDATOR_DSC_BALANCE = 10 ether;

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

    /*//////////////////////////////////////////////////////////////
    //                              Mint DSC                     //
    //////////////////////////////////////////////////////////////*/

    function testMintDSCSuccess() public depositedCollateral {
        // Act
        vm.prank(USER);
        dscEngine.mintDSC(MINT_AMOUNT);

        // Assert
        assertEq(dsc.balanceOf(USER), MINT_AMOUNT, "User should have minted the correct amount of DSC");
        assertEq(dscEngine.getDSCMinted(USER), MINT_AMOUNT, "Minted amount should be updated in contract");
    }

    function testMintDSCRevertsIfZeroAmount() public depositedCollateral {
        // Expect revert due to zero amount
        vm.expectRevert(DSCEngine__MustBeMoreThanZero.selector);

        // Act
        vm.prank(USER);
        dscEngine.mintDSC(0);
    }

    // does not break if too high of a health factor
    // function testMintDSCRevertsIfHealthFactorBroken() public  {
        
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    //     dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
 
    //     // Set up scenario where health factor will break
    //     uint256 unsafeMintAmount = STARTING_ERC20_BALANCE * 1000; // Hypothetically high amount to break health factor

    //     uint256 expectedHealthFactor = dscEngine.getHealthFactor(USER);
    //     console.log(expectedHealthFactor);
    //     vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCENGINE__BreaksHealthFactor.selector, expectedHealthFactor));
    //     dscEngine.mintDSC(unsafeMintAmount);
    //     // Act       
    //     vm.stopPrank();
    // }

    // function testMintDSCRevertsIfMintFails() public depositedCollateral {
    //     // Set up to force a mint failure by manipulating the DSC contract behavior
    //     // This may require modifying the `DecentralizedStableCoin` or mocking the failure

    //     // To illustrate, we assume a function exists to simulate mint failure
    //     dsc.setMintFailCondition(true); // Assuming such a function exists in your mock

    //     vm.expectRevert(DSCEngine__MintFailed.selector);

    //     // Act
    //     vm.prank(USER);
    //     dscEngine.mintDSC(MINT_AMOUNT);

    //     // Cleanup for other tests
    //     dsc.setMintFailCondition(false);
    // }

    function testMintDSCUpdatesStateCorrectly() public depositedCollateral {
        // Arrange
        uint256 initialMintedAmount = dscEngine.getDSCMinted(USER);

        // Act
        vm.prank(USER);
        dscEngine.mintDSC(MINT_AMOUNT);

        // Assert state update
        uint256 expectedMintedAmount = initialMintedAmount + MINT_AMOUNT;
        assertEq(dscEngine.getDSCMinted(USER), expectedMintedAmount, "Minted DSC amount should update correctly");
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

    function testRedeemCollateralForDSCSucceeds() public depositedCollateral {
        uint256 amountDscToBurn = 1 ether; // Assume this amount keeps the health factor safe
        uint256 amountCollateralToRedeem = 0.5 ether; // Choose a safe amount of collateral

        // Mint some DSC to USER so they can burn it
        vm.prank(USER);
        dscEngine.mintDSC(amountDscToBurn);

        // USER burns DSC and redeems collateral
        vm.prank(USER);
        dscEngine.redeemCollateralForDSC(weth, amountCollateralToRedeem, amountDscToBurn);

        // Assertions
        uint256 remainingDscBalance = dsc.balanceOf(USER);
        uint256 remainingCollateral = dscEngine.getCollateralBalance(weth, USER);

        // Check that the DSC balance has decreased by the burned amount
        assertEq(remainingDscBalance, STARTING_ERC20_BALANCE - amountDscToBurn);

        // Check that the collateral balance has decreased by the redeemed amount
        assertEq(remainingCollateral, AMOUNT_COLLATERAL - amountCollateralToRedeem);

        // Ensure that the user's health factor is above the minimum
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        assertTrue(userHealthFactor >= dscEngine.getMinimumHealthFactor());
    }

    function testRedeemCollateralForDSCRevertsIfHealthFactorBroken() public depositedCollateral {
        uint256 amountDscToBurn = 1 ether;
        uint256 amountCollateralToRedeem = 10 ether; // This large amount should trigger a health factor issue

        // Mint some DSC to USER so they can burn it
        vm.prank(USER);
        dscEngine.mintDSC(amountDscToBurn);

        // Attempt to redeem more collateral than the health factor allows
        vm.prank(USER);
        vm.expectRevert(DSCENGINE__BreaksHealthFactor.selector);
        dscEngine.redeemCollateralForDSC(weth, amountCollateralToRedeem, amountDscToBurn);
    }

    function testRedeemCollateralForDSCRevertsWithZeroAmounts() public {
        // Attempt to redeem with zero collateral amount
        vm.prank(USER);
        vm.expectRevert(DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateralForDSC(weth, 0, 1 ether);

        // Attempt to redeem with zero DSC burn amount
        vm.prank(USER);
        vm.expectRevert(DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateralForDSC(weth, 1 ether, 0);
    }

    /*//////////////////////////////////////////////////////////////
    //                           LIQUIDATE
    //////////////////////////////////////////////////////////////*/

    modifier liquidatorSetup() {
        vm.startPrank(LIQUIDATOR);
        // Mint DSC to the liquidator so they have enough balance to cover debt for liquidation.
        dsc.mint(LIQUIDATOR, LIQUIDATOR_DSC_BALANCE);
        vm.stopPrank();
        _;
    }

    function testLiquidateSucceedsAndImprovesHealthFactor() public depositedAndMinted liquidatorSetup {
        uint256 debtToCover = 50 ether; // Amount of DSC to burn
        address collateral = weth; // Collateral token address
        uint256 bonusCollateralAmount = dscEngine.getLiquidationBonus(collateral, debtToCover);

        // Ensure the `user` has a low health factor by manipulating prices or borrowing too much.
        // Assume this setup is done here, and the user's health factor is already below MIN_HEALTH_FACTOR.

        uint256 startingUserHealthFactor = dscEngine.getHealthFactor(USER);

        // Liquidator burns `debtToCover` DSC in exchange for `totalCollateralToRedeem`
        vm.prank(LIQUIDATOR); // LIQUIDATOR acts as the caller
        dscEngine.liquidate(collateral, USER, debtToCover);

        // Check the user's collateral balance to ensure some was redeemed
        uint256 userRemainingCollateral = dscEngine.getCollateralBalance(collateral, USER);
        uint256 liquidatorCollateralBalance = dscEngine.getCollateralBalance(collateral, LIQUIDATOR);

        // Assert collateral transfer with bonus
        assertEq(liquidatorCollateralBalance, bonusCollateralAmount);

        // Check health factor of `user` to confirm improvement
        uint256 endingUserHealthFactor = dscEngine.getHealthFactor(USER);
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
        uint256 startingUserCollateralBalance = dscEngine.getCollateralBalance(collateral, USER);
        uint256 liquidatorStartingCollateralBalance = dscEngine.getCollateralBalance(collateral, LIQUIDATOR);

        vm.prank(LIQUIDATOR);
        dscEngine.liquidate(collateral, USER, partialDebtToCover);

        // Check that partial debt has been burned and collateral rewarded to the liquidator
        uint256 userRemainingDebt = dscEngine.getDebtBalance(USER);
        uint256 liquidatorNewCollateralBalance = dscEngine.getCollateralBalance(collateral, LIQUIDATOR);

        // Ensure partial debt has been reduced from USER's balance
        assertEq(userRemainingDebt, initialDebtToCover - partialDebtToCover);

        // Check that LIQUIDATOR's collateral balance increased by the correct amount
        uint256 expectedBonusCollateral = dscEngine.getLiquidationBonus(collateral, partialDebtToCover);
        assertEq(liquidatorNewCollateralBalance, liquidatorStartingCollateralBalance + expectedBonusCollateral);

        // Check that USER's health factor has improved, even if partial
        uint256 endingUserHealthFactor = dscEngine.getHealthFactor(USER);
        assertTrue(endingUserHealthFactor > dscEngine.getMinimumHealthFactor());
    }
}
