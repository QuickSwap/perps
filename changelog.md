

## Version 4
  ### Pyth Price Feed Contract added
  1. PythPriceFeed
     - Secondary Price Feed contract for Pyth integration
## Version 3
  ### Changes for Quick Perp
  1. OrderBook
     - Receive token added for decrease order
     - Refactoring for chainlink integration
  2. PositionManager
     - Referral code added for partners
     - Minimum Open Time Control added for partners
  3. Vault
     - VaultUtils address overrided
  4. VaultPriceFeed
     - Unused codes removed and Refactoring
  5. VaultUtils
     - getMaxAmountIn function added to get swap limits
  6. FastPriceFeedReader
      - Helper for FastPriceFeed Keeper
  7. PriceFeedTimelock
      - Unused codes removed
  8. Reader, RewardReader
      - Vester and staking codes removed
  9. Timelock
      - Unused codes and function removed
  10. RewardRouter
      - Unused codes removed
      - addLiquidity function added to handle rewards
  11. TokenDistributors
      - StakedQlpDistributor and FeeQlpDistributor added for deployment
  12. TokenTrackers
      - StakedQlpTracker and FeeQlpTracker added for deployment
      
## Version 2
  - Formatting

## Version 1
  - Renamed for Quick Perp
    - Usdg => Usdq
    - Glp => Qlp

## Version 0 
  - Initial Commit (Gmx Version)