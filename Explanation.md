## Terms

1. OnlyOwner functions  can only be called by the owner of the contract

## DecentralizedStableCoin.sol

1. DSC contract inherits ERC20Burnable and Ownable 
2. ERC20Burnable contract inherits Context and ERC20 contract
3. DSC contract has 
   1. initializing constructor with the super constructor ERC20 taking name and symbol also Ownable 
   2. burn function which is 
      1. onlyOwner 
      2. public overrides onlyOwner 
      3. checks the balance of the msg.sender and if the amount of DSC to be burned is appropriate and not zero burns it
   3. Mint Function
      1. contracts mint the address some amount of dsc

## DSCEngine.sol

1. DSCEngine 
   1. Inherits ReentrancyGuard
   2. Implements all the logic
   3. Functions 
      1. Constructor
         1. function parameter are tokenAddresses and priceFeedAddress and dscAddress
         2. Number of tokens and priceFeeds are equal
         3. loop through and initialize priceFeeds storage mapping from (tokenAddress to priceFeedAddress)
         4. initialize the immutable DSC contract which it points to 
      2. DepositCollateralAndMintDSC
         1. 
      3. DepositCollateral
      4. redeemCollateralForDSC
      5. redeemCollateral
      6. mintDSC
         1. increase the amount of DSC Minted for msg.sender to amountDSCToMint
         2. revert the process if health factor gets broken
      7. burnDSC
      8. liquidate
         1. Modifiers -> moreThanZero nonReentrant
         2. healthFactor check
         3. 
      9.  getHealthFactor


## order of execution

1. Deposit some  collateral
   1. Check for health factor
2. Mint some DSC
   1. check for health Factor
3. Options 
   1. Redeem Collateral
   2. Burn DSC
   3. Liquidate


DSC System 

1. System is 
   1. Exogenous Collateral -> Collateral is of wETH and wBTC
   2. Dollar pegged -> 1 DSC is worth 1 dollar
   3. Algorithmically stable -> by keeping a min 200% collateralization  and ensuring health check


Deposit Collateral

1. User deposits $100 Collateral of ETH
2. this allows User ability to mint upto $50 worth DSC
3. Code and testing

```Solidity
function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom((msg.sender), address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
```

4. Testing to be done
   1. Collateral should be more than Zero -> 0 collateral cannot be allowed
   2. isAllowedToken -> to see if the tokenCollateralAddress is allowed
   3. COre functionality
      1. User -> (token -> tokenCollateral) saved in s_collateralDepossited
      2. Event emitted which showcases the user address, tokenCollateral and amount
      3. if transfer fails then -> error emitted
5. Two functions for Deposit Collateral
   1. depositCollateral  -> (tokenCollateralAddress, amountCollateral)
   2. depositCollateralAndMintDSC -> function to deposit a collateral and mint DSC 


Redeem Collateral 

1. Process
   1. BurnDSC -> Burn amount of DSC
   2. now you will in every case be overcollateralized -> redeem collateral
2. Questions to Ask?
   1. Who can redeem collateral? 
   2. What collateral can be redeemed?
3. Code 

```solidity
function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
{
        // revert if they are trying to pull more collateral

        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
}

function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
```
4. Testing

```
bool success = IERC20(tokenCollateralAddress).transferFrom((msg.sender), address(this), amountCollateral);
bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);

```


Mint DSC

1. User can mint DSC
2. Questions to Ask?
   1. Can they Mint DSC? ie do they have enough collateral??
   2. Is minting successful                                                  


Burn DSC

1. Burn DSC
2. Example
   1. Initially User has $1000 ETH collateral with 500 DSC minted, now he can burn say 100 DSC token
   2. Reason -> to redeem collateral and others?? when collateral worth has decreased so you burn to get health Factor in check

Liquidate

1. Allows a User B to liquidate User A 


healthFactor

1. Checks the health factor of a user 
2. healthFactor of a user is (Collaterals converted into USD) / (DSC minted) 

