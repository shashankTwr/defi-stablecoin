// SPDX-License-Identifier: MIT

// Solidity Layout
// 	Pragma
// 	import
// 	Interfaces
// 	libraries
// 	contracts
// 		Type declarations
// 		state variables
// 		events
// 		modifiers
// 		functions
// 			constructor
// 			recieve
// 			fallback
// 			external
// 			public
// 			internal
// 			private
//          view & pure

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/Test.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/// @title DSCEngine
/// @author Shashank Tiwari
///  This system is minimally designed with DSC token pegged to a 1Dollar token
/// This stablecoin has the properties:
/// - exogenous collateral
/// - Dollar pegged
/// - Algorithmically Stable
/// - It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC
/// - Our system should always be *overcollateralized* At no point, should the value of all collateral be less than the value of DSC.
/// @notice This contract is the core of the DSC system. It handles allorge install openzeppelin/openzeppelin-contracts@v4.8.3 --no-commit the logic for mining and redeeming DSC, as well as depositing  & withdrawing collateral
/// @notice This contract is very loosely based on the MakerDAO DSS (DAI) system
/// @dev Explain to a developer any extra details

contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
    //                             ERRORS
    //////////////////////////////////////////////////////////////*/
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCENGINE__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCENGINE__HealthFactorIsOkay();
    error DSCENGINE__HealthFactorNotImproved();
    error DSCEngine__NotEnoughDSCToBurn();
    error DSCEngine__NotEnoughCollateral();

    /*//////////////////////////////////////////////////////////////
    //                              TYPE                         //
    //////////////////////////////////////////////////////////////*/
    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
    //                        STATE VARIABLES                     //
    //////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //this means 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /*//////////////////////////////////////////////////////////////
    //                        EVENTS                              //
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
    //                           MODIFIERS                        //
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
    //                           FUNCTIONS                        //
    //////////////////////////////////////////////////////////////*/

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
    //                           External Functions               //
    //////////////////////////////////////////////////////////////*/

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount to be deposited as collateral
     * @param amountDscToMint The amount of DSC to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress Collateral address to redeem
     * @param amountCollateral  Amount of collateral to redeem
     * @param amountDscToBurn  amount of DSC to burn
     * @notice This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        _burnDSC(msg.sender, msg.sender, amountDscToBurn);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
        // redeem Collateral already checks factor
    }

    // in order to redeem collateral
    // 1. Health factor must be over 1 after collateral pulled
    // DRY concept: Don't repeat yourself

    // CEI: Check, effects, interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        // revert if they are trying to pull more collateral
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // Do we need to check if this breaks health factor?
    function burnDSC(uint256 amount) external moreThanZero(amount) {
        _burnDSC(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // If we do start nearing undercollateralization, we need someone to liquidate positions

    // $100 ETH backing 50$ DSC
    // 20$ ETH back 50$ DSC <- DSC isn't worth 1$

    // 75$ backing 50$ DSC
    // liquidator take 75$ backing and pays off the 50$ DSC

    // if someone is almost undercollaterlized, we will pay you to liquidate them!

    /**
     *
     * @param collateral The ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor, their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice you can partially liquidate a user
     * @notice you will get a liquidation bonus for taking the users funds
     * @notice THis function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized then we wouldn't be able to incentivize the liquidators
     * For example, if the price of the collateral plummeted before anyone could be liquidated
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCENGINE__HealthFactorIsOkay();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User: 140$ eth 100$ DSC
        // debtToCover: 100
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator 110$ of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts into a treasurey
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDSC(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCENGINE__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
    //                        PUBLIC FUNCTIONS                  ////
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice follows CEI
     * @param amountDscToMint amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much dsc, revert them
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice follows CEI(Checks Effects Interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
    //              Private & Internal  Functions                  //
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factor being broken
     */
    function _burnDSC(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        // decrease the amount of dsc minted by onbehalfOf address
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        /* console.log("Amount of DSC held by the address behalfOf", s_DSCMinted[onBehalfOf]);
        console.log("Amount of DSC to burn: ", amountDscToBurn);

        uint256 contractDscBalance = i_dsc.balanceOf(address(this));
        if (amountDscToBurn > contractDscBalance) {
            revert DSCEngine__NotEnoughDSCToBurn();
        } */

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        if (s_collateralDeposited[from][tokenCollateralAddress] < amountCollateral) {
            revert DSCEngine__NotEnoughCollateral();
        }
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
    //          PRIVATE & INTERNAL VIEW & PURE FUNCTIONS          //
    //////////////////////////////////////////////////////////////*/

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     * 
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDscMinted, collateralValueInUSD);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUSD)
        private
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH  = $1000
        // the returned value from the price feed is in 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    // 1. Check health factor(do they have enough collateral)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCENGINE__BreaksHealthFactor(userHealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
    //     External &  Public  View  & Pure Functions             //
    //////////////////////////////////////////////////////////////*/

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUSD)
        external
        view
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUSD);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address token, address user) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited and map it to
        // the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amountDeposited = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amountDeposited);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH(token)
        // $/ETH ETH??
        // $2000 /ETH , $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getDSCMintedByUser(address user) external view returns (uint256 DSCMinted) {
        return s_DSCMinted[user];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getDebtBalance(address user) external view returns (uint256) {
        return s_DSCMinted[user]; // Assumes s_DSCMinted is a mapping of users' DSC debts.
    }

    function getMinimumHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    // function _getTotalDSCMinted() internal view returns(uint256) {
    //     uint256 totalDscMinted = 0;
    //     for(uint256 i = 0; i < s_DSCMinted.length; i++) {
    //         if (s_DSCMinted[i] != 0) {
    //             totalDscMinted += s_DSCMinted[i];
    //         }
    //     }
    //     return totalDscMinted;
    // }

    // function getTotalCollateralValue() external view returns(uint256) {
    //     for(uint256 i = 0; i < s_collateralTokens.length; i++) {
    //         address token = s_collateralTokens[i];
    //         uint256 amountDeposited = s_collateralDeposited[address(0)][token];
    //         return _getUsdValue(token, amountDeposited);
    //     }
    // }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        if (token == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        return s_priceFeeds[token];
    }
}
