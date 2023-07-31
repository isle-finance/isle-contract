// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { UD60x18, ud } from "@prb/math/UD60x18.sol";

import { VersionedInitializable } from "./libraries/upgradability/VersionedInitializable.sol";
import { Errors } from "./libraries/Errors.sol";
import { Adminable } from "./abstracts/Adminable.sol";
import { ILopoGlobals } from "./interfaces/ILopoGlobals.sol";

contract LopoGlobals is ILopoGlobals, VersionedInitializable, Adminable {
    uint256 public constant LOPO_GLOBALS_REVISION = 0x1;
    /*//////////////////////////////////////////////////////////////////////////
                                Struct
    //////////////////////////////////////////////////////////////////////////*/

    struct PoolAdmin {
        address ownedPoolConfigurator;
        bool isPoolAdmin;
    }

    struct Borrower {
        bool isBorrower;
        uint256 riskPremium;
        uint256 discountRate;
        uint256 expirationDate;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////////////////*/

    address public override lopoVault;
    address public override pendingLopoGovernor;

    bool public override protocolPaused;

    mapping(address => bool) public isContractPaused;
    mapping(address => mapping(bytes4 => bool)) public isFunctionUnpaused;

    // configs shared by all pools
    uint256 public override riskFreeRate;
    UD60x18 public override minPoolLiquidityRatio;
    uint256 public override gracePeriod;
    uint256 public override lateInterestExcessRate;

    mapping(address => bool) public override isReceivable;
    mapping(address => bool) public override isCollateralAsset;
    mapping(address => bool) public override isPoolAsset;

    // configs by poolConfigurator
    mapping(address => bool) public override isEnabled;
    mapping(address => UD60x18) public override minDepositLimit;
    mapping(address => uint256) public override withdrawalDurationInDays;
    // mapping(address => address) public override insurancePool; // this should be implemented in other place
    mapping(address => uint256) public override maxCoverLiquidationPercent;
    mapping(address => uint256) public override minCoverAmount;
    mapping(address => uint256) public override exitFeePercent;
    mapping(address => uint256) public override protocolFeeRate;

    mapping(address => PoolAdmin) public override poolAdmins;
    mapping(address => Borrower) public override borrowers;

    /*//////////////////////////////////////////////////////////////////////////
                            Initialization
    //////////////////////////////////////////////////////////////////////////*/

    function initialize(address governor_) external initializer {
        if (governor_ == address(0)) {
            revert Errors.Globals_AdminZeroAddress();
        }
        if (governor_ != admin) {
            transferAdmin(governor_);
        }
        emit Initialized();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function getRevision() internal pure virtual override returns (uint256 revision_) {
        revision_ = LOPO_GLOBALS_REVISION;
    }

    function isPoolAdmin(address account_) external view override returns (bool isPoolAdmin_) {
        isPoolAdmin_ = poolAdmins[account_].isPoolAdmin;
    }

    function isBorrower(address account_) external view override returns (bool isBorrower_) {
        isBorrower_ = borrowers[account_].isBorrower;
    }

    function ownedPoolConfigurator(address account_) external view override returns (address poolConfigurator_) {
        poolConfigurator_ = poolAdmins[account_].ownedPoolConfigurator;
    }

    function governor() external view override returns (address governor_) {
        governor_ = admin;
    }

    function isFunctionPaused(bytes4 sig_) external view override returns (bool functionIsPaused_) {
        functionIsPaused_ = isFunctionPaused(msg.sender, sig_);
    }

    function isFunctionPaused(address contract_, bytes4 sig_) public view override returns (bool functionIsPaused_) {
        functionIsPaused_ = (protocolPaused || isContractPaused[contract_]) && !isFunctionUnpaused[contract_][sig_];
    }

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function transferOwnedPoolConfigurator(address fromPoolAdmin_, address toPoolAdmin_) external override {
        PoolAdmin storage fromAdmin_ = poolAdmins[fromPoolAdmin_];
        PoolAdmin storage toAdmin_ = poolAdmins[toPoolAdmin_];

        /* Checks */
        address poolConfigurator_ = fromAdmin_.ownedPoolConfigurator; // For caching
        if (poolConfigurator_ != msg.sender) {
            revert Errors.Globals_CallerNotPoolConfigurator(poolConfigurator_, msg.sender);
        }

        if (!toAdmin_.isPoolAdmin) {
            revert Errors.Globals_ToInvalidPoolAdmin(toPoolAdmin_);
        }

        poolConfigurator_ = toAdmin_.ownedPoolConfigurator;
        if (poolConfigurator_ != address(0)) {
            revert Errors.Globals_AlreadyHasConfigurator(toPoolAdmin_, poolConfigurator_);
        }

        fromAdmin_.ownedPoolConfigurator = address(0);
        toAdmin_.ownedPoolConfigurator = msg.sender;

        emit PoolConfiguratorOwnershipTransferred(fromPoolAdmin_, toPoolAdmin_, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            MODIFIER
    //////////////////////////////////////////////////////////////////////////*/

    modifier onlyGovernor() {
        _checkIsLopoGovernor();
        _;
    }

    /**
     * Governor Transfer Functions **
     */

    function acceptLopoGovernor() external override {
        require(msg.sender == pendingLopoGovernor, "LG:Caller_Not_Pending_Gov");
        // emit GovernorshipAccepted(admin(), msg.sender);
        pendingLopoGovernor = address(0);
        // lopoGovernor = msg.sender;
        // _setAddress(ADMIN_SLOT, msg.sender);
    }

    function setPendingLopoGovernor(address _pendingGovernor) external override onlyGovernor {
        emit PendingGovernorSet(pendingLopoGovernor = _pendingGovernor);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            GLOBALS SETTERS
    //////////////////////////////////////////////////////////////////////////*/

    function setLopoVault(address _vault) external override onlyGovernor {
        require(_vault != address(0), "LG:Invalid_Vault");
        emit LopoVaultSet(lopoVault, _vault);
        lopoVault = _vault;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            BOOLEAN SETTERS
    //////////////////////////////////////////////////////////////////////////*/

    function setProtocolPause(bool _protocolPaused) external override onlyGovernor {
        emit ProtocolPauseSet(msg.sender, protocolPaused = _protocolPaused);
    }

    /**
     * Allowlist Setters **
     */

    function setIsEnabled(address _poolConfigurator, bool _isEnabled) external override onlyGovernor {
        isEnabled[_poolConfigurator] = _isEnabled;
        emit IsEnabledSet(_poolConfigurator, _isEnabled);
    }

    function setValidReceivable(address _receivable, bool _isValid) external override onlyGovernor {
        require(_receivable != address(0), "LG:SVPD:ZERO_ADDR");
        isReceivable[_receivable] = _isValid;
        emit ValidReceivableSet(_receivable, _isValid);
    }

    function setValidBorrower(address _borrower, bool _isValid) external override onlyGovernor {
        borrowers[_borrower].isBorrower = _isValid;
        emit ValidBorrowerSet(_borrower, _isValid);
    }

    function setValidCollateralAsset(address _collateralAsset, bool _isValid) external override onlyGovernor {
        isCollateralAsset[_collateralAsset] = _isValid;
        emit ValidCollateralAssetSet(_collateralAsset, _isValid);
    }

    function setValidPoolAsset(address _poolAsset, bool _isValid) external override onlyGovernor {
        isPoolAsset[_poolAsset] = _isValid;
        emit ValidPoolAssetSet(_poolAsset, _isValid);
    }

    // function setValidPoolDelegate(address _account, bool _isValid) external override onlyGovernor {
    //     require(_account != address(0), "LG:SVPD:ZERO_ADDR");

    //     // Cannot remove pool delegates that own a pool manager.
    //     require(_isValid || poolDelegates[_account].ownedPoolConfigurator == address(0),
    // "LG:SVPD:OWNS_POOL_MANAGER");

    //     poolDelegates[_account].isPoolDelegate = _isValid;
    //     emit ValidPoolDelegateSet(_account, _isValid);
    // }

    /*//////////////////////////////////////////////////////////////////////////
                            FEE SETTERS
    //////////////////////////////////////////////////////////////////////////*/

    function setRiskFreeRate(uint256 _riskFreeRate) external override onlyGovernor {
        // require(_riskFreeRate <= ud(1e18), "LG:SRFR:GT_1");
        // emit RiskFreeRateSet(_riskFreeRate.intoUint256());
        riskFreeRate = _riskFreeRate;
    }

    function setMinPoolLiquidityRatio(UD60x18 _minPoolLiquidityRatio) external override onlyGovernor {
        require(_minPoolLiquidityRatio <= ud(1e18), "LG:SMPR:GT_1");
        emit MinPoolLiquidityRatioSet(_minPoolLiquidityRatio.intoUint256());
        minPoolLiquidityRatio = _minPoolLiquidityRatio;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            POOL RESTRICTION SETTERS
    //////////////////////////////////////////////////////////////////////////*/

    function setMinDepositLimit(address _poolConfigurator, UD60x18 _minDepositLimit) external override onlyGovernor {
        emit MinDepositLimitSet(_poolConfigurator, _minDepositLimit.intoUint256());
        minDepositLimit[_poolConfigurator] = _minDepositLimit;
    }

    function setWithdrawalDurationInDays(
        address _poolConfigurator,
        uint256 _withdrawalDurationInDays
    )
        external
        onlyGovernor
    {
        emit WithdrawalDurationInDaysSet(_poolConfigurator, _withdrawalDurationInDays);
        withdrawalDurationInDays[_poolConfigurator] = _withdrawalDurationInDays;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _checkIsLopoGovernor() internal view {
        // require(msg.sender == admin(), "LG:Caller_Not_Gov");
    }

    function _setAddress(bytes32 _slot, address _value) private {
        assembly {
            sstore(_slot, _value)
        }
    }
}
