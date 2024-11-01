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

/// @title DSCEngine
/// @author Shashank Tiwari
///  This system is minimally designed with DSC token pegged to a 1Dollar token
/// This stablecoin has the properties:
/// - exogenous collateral
/// - Dollar pegged
/// - Algorithmically Stable
/// - It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC
/// - Our system should always be *overcollateralized* At no point, should the value of all collateral be less than the value of DSC.
/// @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC, as well as depositing  & withdrawing collateral
/// @notice This contract is very loosely based on the MakerDAO DSS (DAI) system
/// @dev Explain to a developer any extra details

contract DSCEngine {
    /*//////////////////////////////////////////////////////////////
    //                             ERRORS
    //////////////////////////////////////////////////////////////*/
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();

    /*//////////////////////////////////////////////////////////////
    //                        STATE VARIABLES                     //
    //////////////////////////////////////////////////////////////*/
    mapping(address token => address priceFeed) private s_priceFeeds;

    DecentralizedStableCoin private i_dsc;

    /*//////////////////////////////////////////////////////////////
    //                           MODIFIERS                        //
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {}

    /*//////////////////////////////////////////////////////////////
    //                           FUNCTIONS                        //
    //////////////////////////////////////////////////////////////*/

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        // For example ETH/USD, BTC/USD, MKR/USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
    //                  EXTERNAL Functions                        //
    //////////////////////////////////////////////////////////////*/

    function depositCOllateralAndMintDSC() external {}

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
    {}

    function redeemCollateralForDSC() external {}

    function redeemCollateral() external {}

    function mintDSC() external {}

    function burnDSC() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}
