// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHealthCheck, ERC20} from "@periphery/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAsset} from "./interfaces/Balancer/IAsset.sol";
import {IBalancerPool} from "./interfaces/Balancer/IBalancerPool.sol";
import {IBalancerVault, IERC20} from "./interfaces/Balancer/IBalancerVault.sol";
import {IRewardsContract} from "./interfaces/Aura/IRewardsContract.sol";

/// @title BPT Balancer Tokenized Strategy
contract BPTBalancer is BaseHealthCheck {
    using SafeERC20 for ERC20;

    //////////////////////// CONSTANTS \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
    address private constant balancerVault =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    //////////////////////// IMMUTABLE \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
    address public immutable auraRewardsContract;
    address public immutable illiquidReward;
    bytes32 private immutable assetPoolId;
    uint256 private immutable numberOfTokens;

    //////////////////////// STORAGE \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
    // The array of rewards arrays grouped by reward = 0, target = 1, pool = 2
    address[3][] rewardsTargetsPools;
    // The array of lp tokens all cast into the IAsset interface.
    IAsset[] internal lpTokens;
    // Amount in Basis Points to allow for slippage on deposits.
    uint256 public slippage;

    constructor(
        string memory _name,
        address _asset,
        address _auraRewardsContract,
        address[3][] memory _rewardsTargetsPools,
        address _illiquidReward
    ) BaseHealthCheck(_asset, _name) {
        require(_auraRewardsContract != address(0), "no aura rewards contract");
        require(_illiquidReward != _asset, "illiquidReward == asset");
        // Set Immutables.
        auraRewardsContract = _auraRewardsContract;
        rewardsTargetsPools = _rewardsTargetsPools;
        illiquidReward = _illiquidReward;
        assetPoolId = IBalancerPool(_asset).getPoolId();

        // Get all the tokens used in the LP.b
        (IERC20[] memory _lpTokens, , ) = IBalancerVault(balancerVault)
            .getPoolTokens(assetPoolId);

        numberOfTokens = _lpTokens.length;

        // Max approvals
        asset.safeApprove(auraRewardsContract, type(uint256).max);
        lpTokens = _setLpTokenApprovals(_lpTokens);

        uint256 numberOfRewards = _rewardsTargetsPools.length;
        for (uint256 i = 0; i < numberOfRewards; i++) {
            ERC20(_rewardsTargetsPools[i][0]).safeApprove(balancerVault, type(uint256).max);
        }

        // Default slippage to 1%.
        slippage = 100;
    }

    function _setLpTokenApprovals(
        IERC20[] memory _tokens
    ) internal returns (IAsset[] memory tokens_) {
        tokens_ = new IAsset[](numberOfTokens);
        for (uint256 i = 0; i < numberOfTokens; ++i) {
            tokens_[i] = IAsset(address(_tokens[i]));
            if (address(_tokens[i]) == address(asset)) {
                continue;
            }
            ERC20(address(_tokens[i])).safeApprove(balancerVault, type(uint256).max);
            ERC20(address(_tokens[i])).safeApprove(address(asset), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal override {
        IRewardsContract(auraRewardsContract).deposit(_amount, address(this));
    }

    function _freeFunds(uint256 _amount) internal override {
        IRewardsContract(auraRewardsContract).withdrawAndUnwrap(_amount, false);
    }

    function _harvestAndReport()
        internal
        override
        notReentered
        returns (uint256 _totalAssets)
    {
        if (!TokenizedStrategy.isShutdown()) {
            _claimAndSellRewards();
            _createAsset();
            uint256 asset = balanceOfAsset();
            if (asset > 0) {
                _deployFunds(asset);
            }
        }

        _totalAssets = balanceOfAsset() + balanceOfAuraPosition();
    }

    function _claimAndSellRewards() internal {
        //claim all rewards plus extra rewards
        IRewardsContract(auraRewardsContract).getReward(address(this), true);
        address[3][] memory _rewardsTargetsPools = rewardsTargetsPools;
        uint256 numberOfRewards = _rewardsTargetsPools.length;
        for (uint256 i = 0; i < numberOfRewards; i++) {
            uint256 rewardBalance = ERC20(_rewardsTargetsPools[i][0]).balanceOf(address(this));
            if (rewardBalance == 0) {
                continue;
            }
            _swapReward(_rewardsTargetsPools[i][0], rewardBalance, _rewardsTargetsPools[i][1], _rewardsTargetsPools[i][2]);
        }
    }

    function _swapReward(address _reward, uint256 _amount, address _target, address _pool) internal {
        bytes32 _poolId = IBalancerPool(_pool).getPoolId();
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        IAsset[] memory assets = new IAsset[](2);
        int256[] memory limits = new int256[](2);
        swaps[0] = IBalancerVault.BatchSwapStep(
            _poolId,
            0,
            1,
            _amount,
            abi.encode(0)
        );
        assets[0] = IAsset(_reward);
        assets[1] = IAsset(_target);
        limits[0] = int256(_amount);
        IBalancerVault(balancerVault).batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            swaps,
            assets,
            _getFundManagement(),
            limits,
            block.timestamp
        );
    }

    function _createAsset() internal {
        IAsset[] memory _lpTokens = new IAsset[](numberOfTokens);
        _lpTokens = lpTokens;
        uint256[] memory _maxAmountsIn = new uint256[](numberOfTokens);
        // Amounts array without the bpt token
        uint256[] memory amountsIn = new uint256[](numberOfTokens - 1);
        // sum up expected BPT from all lpTokens
        uint256 minBPTOut;
        bool runJoinPool;
        // index manipulation to remove bpt from amountsIn
        uint256 n;

        // Fill _maxAmountsIn and amountsIn:
        for (uint256 i = 0; i < numberOfTokens; i++) {
            if (address(_lpTokens[i]) == address(asset)) {
                continue;
            }
            uint256 tokenBalance = ERC20(address(_lpTokens[i])).balanceOf(address(this));
            _maxAmountsIn[i] = tokenBalance;
            amountsIn[n] = tokenBalance;
            minBPTOut += _getMinBPTOut(address(_lpTokens[i]), tokenBalance);
            runJoinPool = true;
            n++;
        }

        if (runJoinPool) {
            bytes memory data = abi.encode(
                IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                    amountsIn,
                    minBPTOut
            );

            IBalancerVault.JoinPoolRequest memory _request = IBalancerVault
                .JoinPoolRequest({
                    assets: _lpTokens,
                    maxAmountsIn: _maxAmountsIn,
                    userData: data,
                    fromInternalBalance: false
                });

            IBalancerVault(balancerVault).joinPool(assetPoolId, address(this), address(this), _request);
        }
    }

    function fromTokenToBpt(address _token, uint256 _amount) internal view returns (uint256) {
        uint256 scaler = 10 ** (asset.decimals() - ERC20(_token).decimals());
        return (_amount * 1e18 * scaler) / IBalancerPool(address(asset)).getRate();
    }

    function _getMinBPTOut(address _token, uint256 _amountIn) internal view returns (uint256) {
        return (fromTokenToBpt(_token, _amountIn) * (MAX_BPS - slippage)) / MAX_BPS;
    }

    function balanceOfAsset() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function balanceOfAuraPosition() public view returns (uint256) {
        return ERC20(auraRewardsContract).balanceOf(address(this));
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

    function availableWithdrawLimit(
        address //_owner
    ) public view override returns (uint256) {
        // Cannot withdraw during Balancer Vault reentrancy.
        if (_isNotReentered()) {
            return type(uint256).max;
        } else {
            return 0;
        }
    }

    // Claim illiquid reward to management: claim and sell Aura on Mainnet
    function claimIlliquidReward(address _to) external onlyManagement {
        ERC20 reward = ERC20(illiquidReward);
        require(address(reward) != address(0), "illiquidReward == address(0)");
        reward.safeTransfer(_to, reward.balanceOf(address(this)));
    }

    // Set the slippage for deposits.
    function setSlippage(uint256 _slippage) external onlyManagement {
        slippage = _slippage;
    }

    function _emergencyWithdraw(
        uint256 _amount
    ) internal override notReentered {
        _freeFunds(_amount);
    }

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

}
