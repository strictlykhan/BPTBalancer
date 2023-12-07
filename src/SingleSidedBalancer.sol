// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHealthCheck, ERC20} from "@periphery/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAsset} from "./interfaces/Balancer/IAsset.sol";
import {IBalancerPool} from "./interfaces/Balancer/IBalancerPool.sol";
import {IBalancerVault, IERC20} from "./interfaces/Balancer/IBalancerVault.sol";

import {IConvexRewards} from "./interfaces/Convex/IConvexRewards.sol";
import {IRewardPoolDepositWrapper} from "./interfaces/Convex/IRewardPoolDepositWrapper.sol";

interface ITradeFactory {
    function enable(address, address) external;
}

/// @title Single Sided Balancer Tokenized Strategy.
/// @dev This is built to be used with a Composable Stable Pool
contract SingleSidedBalancer is BaseHealthCheck {
    using SafeERC20 for ERC20;

    modifier notReentered() {
        require(_isNotReentered(), "reentrancy");
        _;
    }

    /**
     * @notice Checks the Balancer Vault has not been reentered to manipulate balances.
     * See: https://github.com/balancer/balancer-v2-monorepo/blob/9c1574b7d8c4f5040a016cdf79b9d2cc47364fd9/pkg/pool-utils/contracts/lib/VaultReentrancyLib.sol
     * @return True if the vault is NOT in the middle of a tx.
     */
    function _isNotReentered() internal view returns (bool) {
        (, bytes memory revertData) = address(balancerVault).staticcall{
            gas: 10_000
        }(
            abi.encodeWithSelector(
                IBalancerVault(balancerVault).manageUserBalance.selector,
                0
            )
        );

        // Vault is not reentered if there is no revert data.
        return revertData.length == 0;
    }

    //////////////////////// CONSTANTS \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

    // Address of the main balancer vault.
    address internal constant balancerVault =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    // Aura deposit wrapper. Will deposit into lp and stake the lp.
    address internal constant depositWrapper =
        0xcE66E8300dC1d1F5b0e46E9145fDf680a7E41146;
    /// Reward tokens.
    address internal constant bal = 0x9a71012B13CA4d3D0Cdc72A177DF3ef03b0E76A3;
    address internal constant aura = 0x1509706a6c66CA549ff0cB464de88231DDBe213B;

    //////////////////////// IMMUTABLE \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

    // Address of the lp specific Aura staker.
    address public immutable rewardsContract;
    // Address of the LP pool we are using.
    address public immutable pool;
    // The lp pools specific pool id.
    bytes32 public immutable poolId;
    // The length of the array of tokens the lp uses.
    // This is inclusive of the BPT token.
    uint256 internal immutable numberOfTokens;
    // The index in the tokens array our `asset` sits at.
    uint256 internal immutable index;
    // Difference in decimals between asset and BPT(1e18).
    uint256 internal immutable scaler;

    //////////////////////// STORAGE \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

    // The array of lp tokens all cast into the IAsset interface.
    IAsset[] internal tokens;
    // Address that will handle selling the Aura tokens.
    address public tradeFactory;
    // The max in asset we will deposit or withdraw at a time.
    uint256 public maxSingleTrade;
    // The amount in asset that will trigger a tend if idle.
    uint256 public depositTrigger;
    // The max amount the base fee can be for a tend to happen.
    uint256 public maxTendBasefee;
    // Amount in Basis Points to allow for slippage on deposits.
    uint256 public slippage;

    constructor(
        address _asset,
        string memory _name,
        address _pool,
        address _rewardsContract,
        uint256 _maxSingleTrade
    ) BaseHealthCheck(_asset, _name) {
        // Set Immutables.
        pool = _pool;
        rewardsContract = _rewardsContract;
        poolId = IBalancerPool(_pool).getPoolId();

        // Get all the tokens used in the LP.
        (IERC20[] memory _tokens, , ) = IBalancerVault(balancerVault)
            .getPoolTokens(poolId);

        // Set the length of the array.
        numberOfTokens = _tokens.length;
        // Store them all as IAsset and find the index the asset is.
        (tokens, index) = _setTokensAndIndex(_tokens);

        // Amount to scale up or down from asset -> BPT token.
        scaler = 10 ** (ERC20(pool).decimals() - asset.decimals());

        // Allow for 1% loss.
        _setLossLimitRatio(100);
        // Only allow a 10% gain.
        _setProfitLimitRatio(1_000);

        // Max approvals.
        asset.safeApprove(depositWrapper, type(uint256).max);
        ERC20(bal).safeApprove(balancerVault, type(uint256).max);

        // Set storage
        maxSingleTrade = _maxSingleTrade;
        // Default the default trigger to half the max trade.
        depositTrigger = _maxSingleTrade / 2;
        // Default max tend fee to 100 gwei.
        maxTendBasefee = 100e9;
        // Default slippage to 5%.
        slippage = 500;
    }

    function _setTokensAndIndex(
        IERC20[] memory _tokens
    ) internal view returns (IAsset[] memory tokens_, uint256 _index) {
        tokens_ = new IAsset[](numberOfTokens);

        for (uint256 i = 0; i < numberOfTokens; ++i) {
            tokens_[i] = IAsset(address(_tokens[i]));
            if (_tokens[i] == IERC20(address(asset))) {
                _index = i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {}

    /**
     * @notice Deploy loose asset into the LP and stake it.
     * @dev We don't deploy during each deposit but rather only during tends and reports.
     */
    function _depositAndStake(uint256 _amount) internal {
        if (_amount == 0) return;

        IAsset[] memory _assets = new IAsset[](numberOfTokens);
        uint256[] memory _maxAmountsIn = new uint256[](numberOfTokens);

        _assets = tokens;
        _maxAmountsIn[index] = _amount;

        // Amounts array without the bpt token
        uint256[] memory amountsIn = new uint256[](numberOfTokens - 1);
        amountsIn[index] = _amount;

        bytes memory data = abi.encode(
            IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
            amountsIn,
            _getMinBPTOut(_amount)
        );

        IBalancerVault.JoinPoolRequest memory _request = IBalancerVault
            .JoinPoolRequest({
                assets: _assets,
                maxAmountsIn: _maxAmountsIn,
                userData: data,
                fromInternalBalance: false
            });

        IRewardPoolDepositWrapper(depositWrapper).depositSingle(
            rewardsContract,
            asset,
            _amount,
            poolId,
            _request
        );
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // Get the rate of asset to token.
        uint256 _amountBpt = Math.min(
            fromAssetToBpt(_amount),
            totalLpBalance()
        );

        if (_amountBpt == 0) return;

        _withdrawLP(Math.min(_amountBpt, balanceOfStake()));

        IAsset[] memory _assets = new IAsset[](numberOfTokens);
        // We don't enforce any min amount out since withdrawer's can use `maxLoss`
        uint256[] memory _minAmountsOut = new uint256[](numberOfTokens);

        _assets = tokens;

        bytes memory data = abi.encode(
            IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT,
            _amountBpt,
            index
        );

        IBalancerVault.ExitPoolRequest memory _request = IBalancerVault
            .ExitPoolRequest({
                assets: _assets,
                minAmountsOut: _minAmountsOut,
                userData: data,
                toInternalBalance: false
            });

        IBalancerVault(balancerVault).exitPool(
            poolId,
            address(this),
            payable(address(this)),
            _request
        );
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        notReentered
        returns (uint256 _totalAssets)
    {
        if (!TokenizedStrategy.isShutdown()) {
            _claimAndSellRewards();

            _depositAndStake(
                Math.min(asset.balanceOf(address(this)), maxSingleTrade)
            );
        }

        _totalAssets =
            asset.balanceOf(address(this)) +
            fromBptToAsset(totalLpBalance());
    }

    /**
    * @notice
        Convert from underlying asset to the amount of BPT shares.
    */
    function fromAssetToBpt(uint256 _amount) public view returns (uint256) {
        return (_amount * 1e18 * scaler) / IBalancerPool(pool).getRate();
    }

    /**
     * @notice
     *   Convert from an amount of BPT shares to the underlying asset.
     */
    function fromBptToAsset(uint256 _amount) public view returns (uint256) {
        return (_amount * IBalancerPool(pool).getRate()) / 1e18 / scaler;
    }

    /**
     * @notice Get the min BPT tokens out with a slippage buffer
     */
    function _getMinBPTOut(uint256 _amountIn) internal view returns (uint256) {
        return (fromAssetToBpt(_amountIn) * (MAX_BPS - slippage)) / MAX_BPS;
    }

    /**
     * @notice
     *   Public function that will return the total LP balance held by the Tripod
     * @return both the staked and un-staked balances
     */
    function totalLpBalance() public view returns (uint256) {
        unchecked {
            return balanceOfPool() + balanceOfStake();
        }
    }

    /**
     * @notice
     *  Function returning the liquidity amount of the LP position
     *  This is just the non-staked balance
     * @return balance of LP token
     */
    function balanceOfPool() public view returns (uint256) {
        return ERC20(pool).balanceOf(address(this));
    }

    /**
     * @notice will return the total staked balance
     *   Staked tokens in convex are treated 1 for 1 with lp tokens
     */
    function balanceOfStake() public view returns (uint256) {
        return IConvexRewards(rewardsContract).balanceOf(address(this));
    }

    /**
     * @notice
     *  Function used internally to collect the accrued rewards mid epoch
     */
    function _getReward() internal {
        IConvexRewards(rewardsContract).getReward(address(this), false);
    }

    /**
     * @notice
     *   Internal function to un-stake tokens from Convex
     *   harvest Extras will determine if we claim rewards, normally should be true
     */
    function _withdrawLP(uint256 amount) internal {
        if (amount == 0) return;

        IConvexRewards(rewardsContract).withdrawAndUnwrap(amount, false);
    }

    /**
     * @notice
     *
     */
    function _claimAndSellRewards() internal {
        // Claim all the pending rewards.
        _getReward();

        uint256 balBalance = ERC20(bal).balanceOf(address(this));
        //Cant swap 0
        if (balBalance == 0) return;

        IBalancerVault.BatchSwapStep[]
            memory swaps = new IBalancerVault.BatchSwapStep[](1);
        IAsset[] memory assets = new IAsset[](2);
        int256[] memory limits = new int256[](2);

        swaps[0] = IBalancerVault.BatchSwapStep(
            0x0297e37f1873d2dab4487aa67cd56b58e2f27875000100000000000000000002, //bal pool id
            0, //Index to use for Bal
            1, //index to use for asset
            balBalance,
            abi.encode(0)
        );

        assets[0] = IAsset(bal);
        assets[1] = IAsset(address(asset));
        limits[0] = int256(balBalance);

        IBalancerVault(balancerVault).batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            swaps,
            assets,
            _getFundManagement(),
            limits,
            block.timestamp
        );
    }

    function _getFundManagement()
        internal
        view
        returns (IBalancerVault.FundManagement memory fundManagement)
    {
        fundManagement = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );
    }

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * The TokenizedStrategy contract will do all needed debt and idle updates
     * after this has finished and will have no effect on PPS of the strategy
     * till report() is called.
     *
     * @param . The current amount of idle funds that are available to deploy.
     */
    function _tend(uint256 /*_totalIdle*/) internal override notReentered {
        _depositAndStake(
            Math.min(asset.balanceOf(address(this)), maxSingleTrade)
        );
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     */
    function _tendTrigger() internal view override returns (bool) {
        if (asset.balanceOf(address(this)) > depositTrigger) {
            return block.basefee < maxTendBasefee;
        }
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     */
    function availableDepositLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return maxSingleTrade;
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // Cannot withdraw during Balancer Vault reentrancy.
        if (_isNotReentered()) {
            return TokenizedStrategy.totalIdle() + maxSingleTrade;
        } else {
            return 0;
        }
    }

    // Set the trade factory to dump Aura.
    function setTradeFactory(address _tradeFactory) external onlyManagement {
        // If there is already a TF set. Remove its allowance.
        if (tradeFactory != address(0)) {
            ERC20(aura).safeApprove(tradeFactory, 0);
        }

        // If we are not removing it.
        if (_tradeFactory != address(0)) {
            // Enable and approve.
            ITradeFactory(_tradeFactory).enable(aura, address(asset));
            ERC20(aura).safeApprove(_tradeFactory, type(uint256).max);
        }

        // Update the address.
        tradeFactory = _tradeFactory;
    }

    // Can also be used to pause deposits.
    function setMaxSingleTrade(
        uint256 _maxSingleTrade
    ) external onlyEmergencyAuthorized {
        require(_maxSingleTrade != type(uint256).max, "cannot be max");
        maxSingleTrade = _maxSingleTrade;
    }

    // Set the max base fee for tending to occur at.
    function setMaxTendBasefee(
        uint256 _maxTendBasefee
    ) external onlyManagement {
        maxTendBasefee = _maxTendBasefee;
    }

    // Set the amount in asset that should trigger a tend if idle.
    function setDepositTrigger(
        uint256 _depositTrigger
    ) external onlyManagement {
        depositTrigger = _depositTrigger;
    }

    // Set the slippage for deposits.
    function setSlippage(uint256 _slippage) external onlyManagement {
        slippage = _slippage;
    }

    // Manually pull funds out from the lp without shuting down.
    // This will also stop new deposits and withdraws that would pull from the LP.
    // Can call tend after this to update internal balances.
    function manualWithdraw(
        uint256 _amount
    ) external notReentered onlyEmergencyAuthorized {
        maxSingleTrade = 0;
        depositTrigger = type(uint256).max;
        _freeFunds(_amount);
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(
        uint256 _amount
    ) internal override notReentered {
        maxSingleTrade = 0;
        depositTrigger = type(uint256).max;
        _freeFunds(_amount);
    }
}
