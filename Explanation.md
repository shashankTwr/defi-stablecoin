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

1. 