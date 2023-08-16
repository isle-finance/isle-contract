// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { UD60x18, ud } from "@prb/math/UD60x18.sol";

import { Errors } from "./libraries/Errors.sol";
import { VersionedInitializable } from "./libraries/upgradability/VersionedInitializable.sol";

import { ILopoGlobals } from "./interfaces/ILopoGlobals.sol";
import { IPoolAddressesProvider } from "./interfaces/IPoolAddressesProvider.sol";
import { ILoanManager } from "./interfaces/ILoanManager.sol";
import { IPoolConfigurator } from "./interfaces/IPoolConfigurator.sol";
import { IReceivable } from "./interfaces/IReceivable.sol";

import { LoanManagerStorage } from "./LoanManagerStorage.sol";
import { ReceivableStorage } from "./ReceivableStorage.sol";

contract LoanManager is ILoanManager, LoanManagerStorage, ReentrancyGuard, VersionedInitializable {
    uint256 public constant LOAN_MANAGER_REVISION = 0x1;

    uint256 public constant HUNDRED_PERCENT = 1e6; // 100.0000%
    uint256 private constant SCALED_ONE = 1e18;
    uint256 public constant PRECISION = 1e27;

    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor(IPoolAddressesProvider provider) {
        ADDRESSES_PROVIDER = provider;
    }

    function initialize(IPoolAddressesProvider provider_) external initializer {
        if (ADDRESSES_PROVIDER != provider_) {
            revert Errors.InvalidAddressProvider({
                expectedProvider: address(ADDRESSES_PROVIDER),
                provider: address(provider_)
            });
        }
    }

    function getRevision() internal pure virtual override returns (uint256 revision_) {
        revision_ = LOAN_MANAGER_REVISION;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier whenNotPaused() {
        _revertIfPaused();
        _;
    }

    modifier onlyPoolAdminOrGovernor() {
        _revertIfNotPoolAdminOrGovernor();
        _;
    }

    modifier onlyPoolAdmin() {
        _revertIfNotPoolAdmin();
        _;
    }

    modifier limitDrawableUse(uint16 loanId_) {
        if (msg.sender == loans[loanId_].borrower) {
            _;
            return;
        }

        uint256 drawableFundsBeforePayment = loans[loanId_].drawableFunds;

        _;

        if (loans[loanId_].drawableFunds < drawableFundsBeforePayment) {
            revert Errors.LoanManager_DrawableFundsDecreased({ loanId_: loanId_ });
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function accruedInterest() public view returns (uint256 accruedInterest_) {
        uint256 issuanceRate_ = issuanceRate;
        accruedInterest_ = issuanceRate_ == 0 ? 0 : _getIssuance(issuanceRate, block.timestamp - domainStart);
    }

    function assetsUnderManagement() public view virtual override returns (uint256 assetsUnderManagement_) {
        assetsUnderManagement_ = principalOut + accountedInterest + accruedInterest();
    }

    function getLoanPaymentDetailedBreakdown(uint16 loanId_)
        public
        view
        returns (uint256 principal_, uint256[2] memory interest_)
    {
        LoanInfo memory loan_ = loans[loanId_];
        (principal_, interest_) = _getPaymentBreakdown(
            block.timestamp,
            loan_.startDate,
            loan_.dueDate,
            loan_.principal,
            loan_.interestRate,
            loan_.lateInterestPremiumRate
        );
    }

    function getLoanPaymentBreakdown(uint16 loanId_) public view returns (uint256 principal_, uint256 interest_) {
        LoanInfo memory loan_ = loans[loanId_];
        uint256[2] memory interestArray_;

        (principal_, interestArray_) = _getPaymentBreakdown(
            block.timestamp,
            loan_.startDate,
            loan_.dueDate,
            loan_.principal,
            loan_.interestRate,
            loan_.lateInterestPremiumRate
        );

        interest_ = interestArray_[0] + interestArray_[1];
    }

    /*//////////////////////////////////////////////////////////////////////////
                        MANUAL ACCOUNTING UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function updateAccounting() external whenNotPaused onlyPoolAdminOrGovernor {
        _advanceGlobalPaymentAccounting();
        _updateIssuanceParams(issuanceRate, accountedInterest);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        BUYER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/
    /**
     *  @dev   Approves the receivable with the following terms.
     *  @param receivablesTokenId_      Token ID of the receivable that would be used as collateral
     *  @param gracePeriod_            Grace period for the loan
     *  @param principalRequested_      Amount of principal approved by the buyer
     *  @param rates_                   Rates parameters:
     *                                      [0]: interestRate,
     *                                      [1]: lateInterestPremiumRate,
     *  @param fee_                     PoolAdmin Fees
     */
    function approveReceivables(uint256 receivablesTokenId_, uint256 gracePeriod_, uint256 principalRequested_, uint256[2] memory rates_, uint256 fee_) external whenNotPaused returns (uint16 loanId_) {
        address collateralAsset_ = collateralAsset;

        ILopoGlobals globals_ = ILopoGlobals(_globals());
        ReceivableStorage.ReceivableInfo memory receivableInfo_ =
            IReceivable(collateralAsset_).getReceivableInfoById(receivablesTokenId_);

        // Only the buyer can approve the receivables
        if (receivableInfo_.buyer != msg.sender) {
            revert Errors.LoanManager_CallerNotBuyer();
        }

        // Check if the buyer and seller are whitelisted
        if (IPoolConfigurator(_poolConfigurator()).isBuyer(receivableInfo_.buyer)) {
            revert Errors.LoanManager_BuyerNotWhitelisted();
        }
        if (IPoolConfigurator(_poolConfigurator()).isSeller(receivableInfo_.seller)) {
            revert Errors.LoanManager_SellerNotWhitelisted();
        }

        if (principalRequested_ > receivableInfo_.faceAmount.intoUint256()) {
            revert Errors.LoanManager_PrincipalRequestedTooLarge();
        }

        // Increment loan
        loanId_ = ++loanCounter;

        // Create loan data structure
        loans[loanId_] = LoanInfo({
            borrower: receivableInfo_.buyer,

            collateralTokenId: receivablesTokenId_,

            principal: principalRequested_,
            drawableFunds: uint256(0),

            interestRate: rates_[0],
            lateInterestPremiumRate: rates_[1],

            startDate: uint256(0),
            dueDate: receivableInfo_.repaymentTimestamp,
            originalDueDate: uint256(0),
            gracePeriod: gracePeriod_,

            issuanceRate: uint256(0),
            isImpaired: false
        });
    }

    function closeLoan(
        uint16 loanId_,
        uint256 amount_
    )
        external
        whenNotPaused
        returns (uint256 principal_, uint256 interest_)
    {
        LoanInfo memory loan_ = loans[loanId_];

        // 1. Advance global accounting
        //   - Update `domainStart` to the current `block.timestamp`
        //   - Update `accountedInterest` to account all accrued interest since last update
        _advanceGlobalPaymentAccounting();

        // 2. Transfer the funds from the borrower to the loan manager
        if (amount_ != uint256(0) && !IERC20(fundsAsset).transferFrom(msg.sender, address(this), amount_)) {
            revert Errors.LoanManager_FundsTransferFailed();
        }

        // 3. Check and update loan accounting
        (principal_, interest_) = getLoanPaymentBreakdown(loanId_);

        uint256 principalAndInterest_ = principal_ + interest_;

        if (loan_.drawableFunds + amount_ < principalAndInterest_) {
            revert Errors.LoanManager_InsufficientPayment(loanId_);
        }

        loan_.drawableFunds = loan_.drawableFunds + amount_ - principalAndInterest_;

        emit PaymentMade(loanId_, principal_, interest_);

        // 4. Transfer the funds to the pool, poolAdmin, and protocolVault
        _distributeClaimedFunds(loanId_, principal_, interest_);

        // 5. Decrement `principalOut`
        if (principal_ != 0) {
            emit PrincipalOutUpdated(principalOut -= SafeCast.toUint128(principal_));
        }

        // 6. Update the accounting based on the payment that was just made
        uint256 paymentIssuanceRate_ = _handlePaymentAccounting(loanId_);

        // 7. Delete paymentId from mapping
        delete paymentIdOf[loanId_];
        _updateIssuanceParams(issuanceRate - paymentIssuanceRate_, accountedInterest);

        emit FundsClaimed(loanId_, principalAndInterest_);
    }

    function drawdownFunds(uint16 loanId_, uint256 amount_, address destination_) external whenNotPaused {
        uint256 drawableFunds_ = loans[loanId_].drawableFunds;

        if (amount_ > drawableFunds_) {
            revert Errors.LoanManager_InsufficientFunds(loanId_);
        }

        loans[loanId_].drawableFunds -= amount_;

        if (!IERC20(fundsAsset).transfer(destination_, amount_)) {
            revert Errors.LoanManager_FundsTransferFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            LOAN FUNDING FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function fundLoan(uint16 loanId_) external nonReentrant whenNotPaused onlyPoolAdmin {
        LoanInfo memory loan_ = loans[loanId_];

        if (!IPoolConfigurator(_poolConfigurator()).isBorrower(loan_.borrower)) {
            revert Errors.NotBorrower({ caller: msg.sender });
        }

        _advanceGlobalPaymentAccounting();

        uint256 principal_ = loan_.principal;

        IPoolConfigurator(_poolConfigurator()).requestFunds(principal_);

        // Update loan state
        LoanInfo storage loanStorage_ = loans[loanId_];
        loanStorage_.drawableFunds = principal_;
        loanStorage_.startDate = block.timestamp;

        emit PrincipalOutUpdated(principalOut += SafeCast.toUint128(principal_));

        // Add new issuance rate from queued payment
        _updateIssuanceParams(issuanceRate + _queuePayment(loanId_, block.timestamp, loan_.dueDate), accountedInterest);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        LOAN IMPAIRMENT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function impairLoan(uint16 loanId_) external whenNotPaused onlyPoolAdminOrGovernor {
        LoanInfo memory loan_ = loans[loanId_];

        if (loan_.isImpaired) {
            revert Errors.LoanManager_LoanImpaired({ loanId: loanId_ });
        }

        uint256 paymentId_ = paymentIdOf[loanId_];

        if (paymentId_ == 0) {
            revert Errors.LoanManager_NotLoan({ loanId: loanId_ });
        }

        PaymentInfo memory paymentInfo_ = payments[paymentId_];

        _advanceGlobalPaymentAccounting();

        _removePaymentFromList(paymentId_);

        // Use issuance rate from payment info in storage, because it would have been set to zero and accounted for
        // already if late
        _updateIssuanceParams(issuanceRate - payments[paymentId_].issuanceRate, accountedInterest);

        (uint256 netInterest_, uint256 netLateInterest_, uint256 protocolFees_) =
            _getDefaultInterestAndFees(loanId_, paymentInfo_);

        liquidationInfoFor[loanId_] = LiquidationInfo({
            triggeredByGovernor: msg.sender == _governor(),
            principal: SafeCast.toUint128(loan_.principal),
            interest: SafeCast.toUint120(netInterest_),
            lateInterest: netLateInterest_,
            protocolFees: SafeCast.toUint96(protocolFees_)
        });

        emit UnrealizedLossesUpdated(unrealizedLosses += SafeCast.toUint128(loan_.principal + netInterest_));

        // Update date on loan data structur

        uint256 originalDueDate_ = loan_.dueDate;

        // if payment is late, do not change the payment due date
        uint256 newDueDate_ = block.timestamp > originalDueDate_ ? originalDueDate_ : block.timestamp;

        LoanInfo storage loanStorage_ = loans[loanId_];

        loanStorage_.dueDate = newDueDate_;
        loanStorage_.originalDueDate = originalDueDate_;

        emit LoanImpaired(newDueDate_);
    }

    function removeLoanImpairment(uint16 loanId_) external nonReentrant whenNotPaused {
        LiquidationInfo memory liquidationInfo_ = liquidationInfoFor[loanId_];

        if (msg.sender != _governor() && (liquidationInfo_.triggeredByGovernor || msg.sender != _poolAdmin())) {
            revert Errors.LoanManager_NotAuthorizedToRemoveLoanImpairment(loanId_);
        }

        if (block.timestamp > loans[loanId_].dueDate) {
            revert Errors.LoanManager_PastDueDate(loanId_);
        }

        _advanceGlobalPaymentAccounting();

        uint24 paymentId_ = paymentIdOf[loanId_];

        if (paymentId_ == 0) {
            revert Errors.LoanManager_NotLoan(loanId_);
        }

        PaymentInfo memory paymentInfo_ = payments[paymentId_];

        _revertLoanImpairment(liquidationInfo_);

        delete liquidationInfoFor[loanId_];
        delete payments[paymentId_];

        payments[paymentIdOf[loanId_] = _addPaymentToList(paymentInfo_.dueDate)] = paymentInfo_;

        // Update missing interest as if payment was always part of the list
        _updateIssuanceParams(
            issuanceRate + paymentInfo_.issuanceRate,
            accountedInterest
                + SafeCast.toUint112(
                    _getPaymentAccruedInterest(paymentInfo_.startDate, block.timestamp, paymentInfo_.issuanceRate)
                )
        );

        // Update date on loan data structure
        LoanInfo memory loan_ = loans[loanId_];
        uint256 originalPaymentDueDate_ = loan_.originalDueDate;

        if (originalPaymentDueDate_ == 0) {
            revert Errors.LoanManager_NotImpaired(loanId_);
        }

        if (block.timestamp > originalPaymentDueDate_) {
            revert Errors.LoanManager_PastDueDate(loanId_);
        }

        loan_.dueDate = originalPaymentDueDate_;
        delete loan_.originalDueDate;

        emit ImpairmentRemoved(originalPaymentDueDate_);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        LOAN DEFAULT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function triggerDefault(uint16 loanId_)
        external
        override
        whenNotPaused
        onlyPoolAdmin
        returns (uint256 remainingLosses_, uint256 protocolFees_)
    {
        uint256 paymentId_ = paymentIdOf[loanId_];

        if (paymentId_ == 0) {
            revert Errors.LoanManager_NotLoan({ loanId: loanId_ });
        }

        // NOTE: must get payment info prior to advancing payment accounting, becasue that will set issuance rate to 0.
        PaymentInfo memory paymentInfo_ = payments[paymentId_];
        LoanInfo memory loan_ = loans[loanId_];

        // This will cause this payment to be removed from the list, so no need to remove it explicitly
        _advanceGlobalPaymentAccounting();

        uint256 netInterest_;
        uint256 netLateInterest_;

        (netInterest_, netLateInterest_, protocolFees_) = loan_.isImpaired
            ? _getInterestAndFeesFromLiquidationInfo(loanId_)
            : _getDefaultInterestAndFees(loanId_, paymentInfo_);

        (remainingLosses_, protocolFees_) = _handleReposession(loanId_, protocolFees_, netInterest_, netLateInterest_);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _getIssuance(uint256 issuanceRate_, uint256 interval_) internal pure returns (uint256 issuance_) {
        issuance_ = (issuanceRate_ * interval_) / PRECISION;
    }

    function _getPaymentBreakdown(
        uint256 currentTime_,
        uint256 startDate_,
        uint256 dueDate_,
        uint256 principal_,
        uint256 interestRate_,
        uint256 lateInterestPremiumRate_
    )
        internal
        pure
        returns (uint256 principalAmount_, uint256[2] memory interest_)
    {
        principalAmount_ = principal_;
        interest_[0] = _getInterest(principal_, interestRate_, dueDate_ - startDate_);
        interest_[1] = _getLateInterest(currentTime_, principal_, interestRate_, dueDate_, lateInterestPremiumRate_);
    }

    function _getInterest(
        uint256 principal_,
        uint256 interestRate_,
        uint256 interval_
    )
        internal
        pure
        returns (uint256 interest_)
    {
        interest_ = (principal_ * _getPeriodicInterestRate(interestRate_, interval_)) / SCALED_ONE;
    }

    function _getLateInterest(
        uint256 currentTime_,
        uint256 principal_,
        uint256 interestRate_,
        uint256 dueDate_,
        uint256 lateInterestPremiumRate_
    )
        internal
        pure
        returns (uint256 lateInterest_)
    {
        if (currentTime_ <= dueDate_) {
            return 0;
        }

        uint256 fullDaysLate_ = ((currentTime_ - dueDate_ + (1 days - 1)) / 1 days) * 1 days;

        lateInterest_ = _getInterest(principal_, interestRate_ + lateInterestPremiumRate_, fullDaysLate_);
    }

    function _getPeriodicInterestRate(
        uint256 interestRate_,
        uint256 interval_
    )
        internal
        pure
        returns (uint256 periodicInterestRate_)
    {
        periodicInterestRate_ = (interestRate_ * (SCALED_ONE / HUNDRED_PERCENT) * interval_) / uint256(365 days);
    }

    /* Protocol Address View Functions */
    function _poolConfigurator() internal view returns (address poolConfigurator_) {
        poolConfigurator_ = ADDRESSES_PROVIDER.getPoolConfigurator();
    }

    function _globals() internal view returns (address globals_) {
        globals_ = ADDRESSES_PROVIDER.getLopoGlobals();
    }

    function _governor() internal view returns (address governor_) {
        governor_ = ILopoGlobals(_globals()).governor();
    }

    function _poolAdmin() internal view returns (address poolAdmin_) {
        poolAdmin_ = IPoolConfigurator(_poolConfigurator()).poolAdmin();
    }

    function _pool() internal view returns (address pool_) {
        pool_ = IPoolConfigurator(_poolConfigurator()).pool();
    }

    function _vault() internal view returns (address vault_) {
        vault_ = ILopoGlobals(_globals()).lopoVault();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _accountForLoanImpairment(uint16 loanId_) internal returns (uint40 impairedDate_) {
        LoanInfo memory loan_ = loans[loanId_];
        impairedDate_ = impairmentFor[loanId_].impairedDate;

        if (impairedDate_ != 0) {
            return impairedDate_;
        }

        impairmentFor[loanId_].impairedDate = impairedDate_;

        _updateInterestAccounting(0, -SafeCast.toInt256(loan_.issuanceRate));
    }

    function _updateInterestAccounting(int256 accountedInterestAdjustment_, int256 issuanceRateAdjustment_) internal {
        accountedInterest = SafeCast.toUint112(
            SafeCast.toUint256(
                SignedMath.max(
                    (SafeCast.toInt256(accountedInterest + accruedInterest()) + accountedInterestAdjustment_), 0
                )
            )
        );

        domainStart = SafeCast.toUint40(block.timestamp);
        issuanceRate = SafeCast.toUint256(SignedMath.max(SafeCast.toInt256(issuanceRate) + issuanceRateAdjustment_, 0));

        emit AccountingStateUpdated(issuanceRate, accountedInterest);
    }

    function _updateUnrealizedLosses(int256 lossesAdjustment_) internal {
        unrealizedLosses = SafeCast.toUint128(
            SafeCast.toUint256(SignedMath.max(SafeCast.toInt256(unrealizedLosses) + lossesAdjustment_, 0))
        );
        emit UnrealizedLossesUpdated(unrealizedLosses);
    }

    function _updatePrincipalOut(int256 principalOutAdjustment_) internal {
        principalOut = SafeCast.toUint128(
            SafeCast.toUint256(SignedMath.max(SafeCast.toInt256(principalOut) + principalOutAdjustment_, 0))
        );
        emit PrincipalOutUpdated(principalOut);
    }

    // Clears all state variables to end a loan, but keep borrower and lender withdrawal functionality intact
    function _clearLoanAccounting(uint16 loanId_) internal {
        LoanInfo storage loan_ = loans[loanId_];

        loan_.gracePeriod = uint256(0);
        loan_.interestRate = uint256(0);
        loan_.lateInterestPremiumRate = uint256(0);

        loan_.dueDate = uint256(0);
        loan_.principal = uint256(0);
        loan_.originalDueDate = uint256(0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INTERNAL STANDARD PROCEDURE UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _advanceGlobalPaymentAccounting() internal {
        uint256 domainEnd_ = domainEnd;

        uint256 accountedInterest_;

        // If the earliest payment in the list is in the past, then the payment accounting must be retroactively updated
        if (domainEnd_ != 0 && block.timestamp > domainEnd_) {
            uint256 paymentId_ = paymentWithEarliestDueDate;

            // Cache variables
            uint256 domainStart_ = domainStart;
            uint256 issuanceRate_ = issuanceRate;

            while (block.timestamp > domainEnd_) {
                uint256 next_ = sortedPayments[paymentId_].next;

                // Account payment that is already in the past
                (uint256 accountedInterestIncrease_, uint256 issuanceRateReduction_) =
                    _accountToEndOfPayment(paymentId_, issuanceRate_, domainStart_, domainEnd_);

                // Update cached aggregate values for updating the global state
                accountedInterest_ += accountedInterestIncrease_;
                issuanceRate_ -= issuanceRateReduction_;

                // Update the domain start and end
                domainStart_ = domainEnd_;
                domainEnd_ = paymentWithEarliestDueDate == 0
                    ? SafeCast.toUint48(block.timestamp)
                    : payments[paymentWithEarliestDueDate].dueDate;

                if ((paymentId_ = next_) == 0) {
                    break;
                }
            }

            domainEnd = SafeCast.toUint48(domainEnd_);
            issuanceRate = issuanceRate_;
        }

        // Account the accrued interest to the accountedInterest
        accountedInterest += SafeCast.toUint112(accountedInterest_ + accruedInterest());
        domainStart = SafeCast.toUint48(block.timestamp);
    }

    function _updateIssuanceParams(uint256 issuanceRate_, uint112 accountedInterest_) internal {
        uint256 earliestPayment_ = paymentWithEarliestDueDate;

        // Set end domain to current time if there are no payments left, else set it to the earliest payment's due date
        emit IssuanceParamsUpdated(
            domainEnd = earliestPayment_ == 0 ? SafeCast.toUint48(block.timestamp) : payments[earliestPayment_].dueDate,
            issuanceRate = issuanceRate_,
            accountedInterest = accountedInterest_
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INTERNAL LOAN ACCOUNTING HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _compareAndSubtractAccountedInterest(uint256 amount_) internal {
        // Rounding errors accrue in `accountedInterest` when loans are late and the issuance rate is used to calculate
        // the interest more often to increment than to decrement.
        // When this is the case, the underflow is prevented on the last decrement by using the minimum of the two
        // values below.
        accountedInterest -= SafeCast.toUint112(_min(accountedInterest, amount_));
    }

    function _getAccruedAmount(
        uint256 totalAccruingAmount_,
        uint256 startTime_,
        uint256 endTime_,
        uint256 currentTime_
    )
        internal
        pure
        returns (uint256 accruedAmount_)
    {
        accruedAmount_ = totalAccruingAmount_ * (currentTime_ - startTime_) / (endTime_ - startTime_);
    }

    function _getDefaultInterestAndFees(
        uint16 loanId_,
        PaymentInfo memory paymentInfo_
    )
        internal
        view
        returns (uint256 netInterest_, uint256 netLateInterest_, uint256 protocolFees_)
    {
        // Accrue the interest only up to the current time if the payment due date has not been reached yet.
        // Note: Issuance Rate in paymentInfo is netRate
        netInterest_ = paymentInfo_.issuanceRate == 0
            ? paymentInfo_.incomingNetInterest
            : _getPaymentAccruedInterest({
                startTime_: paymentInfo_.startDate,
                endTime_: _min(paymentInfo_.dueDate, block.timestamp),
                paymentIssuanceRate_: paymentInfo_.issuanceRate
            });

        // Gross interrest, which means it is not just to the current timestamp but to the due date
        (, uint256[2] memory grossInterest_) = getLoanPaymentDetailedBreakdown(loanId_);

        uint256 grossLateInterest_ = grossInterest_[1];

        netLateInterest_ = _getNetInterest(grossLateInterest_, paymentInfo_.protocolFeeRate + paymentInfo_.adminFeeRate);

        protocolFees_ = (grossInterest_[0] + grossLateInterest_) * paymentInfo_.protocolFeeRate / HUNDRED_PERCENT;

        // If the payment is early, scale back the management fees pro-rata based on the current timestamp
        if (grossLateInterest_ == 0) {
            protocolFees_ =
                _getAccruedAmount(protocolFees_, paymentInfo_.startDate, paymentInfo_.dueDate, block.timestamp);
        }
    }

    function _getInterestAndFeesFromLiquidationInfo(uint16 loanId_)
        internal
        view
        returns (uint256 netInterest_, uint256 netLateInterest_, uint256 protocolFees_)
    {
        LiquidationInfo memory liquidationInfo_ = liquidationInfoFor[loanId_];

        netInterest_ = liquidationInfo_.interest;
        netLateInterest_ = liquidationInfo_.lateInterest;
        protocolFees_ = liquidationInfo_.protocolFees;
    }

    function _getNetInterest(uint256 interest_, uint256 feeRate_) internal pure returns (uint256 netInterest_) {
        netInterest_ = interest_ * (HUNDRED_PERCENT - feeRate_) / HUNDRED_PERCENT;
    }

    function _getPaymentAccruedInterest(
        uint256 startTime_,
        uint256 endTime_,
        uint256 paymentIssuanceRate_
    )
        internal
        pure
        returns (uint256 accruedInterest_)
    {
        accruedInterest_ = (endTime_ - startTime_) * paymentIssuanceRate_ / PRECISION;
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INTERNAL PAYMENT ACCOUNTING FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _accountToEndOfPayment(
        uint256 paymentId_,
        uint256 issuanceRate_,
        uint256 intervalStart_,
        uint256 intervalEnd_
    )
        internal
        returns (uint256 accountedInterestIncrease_, uint256 issuanceRateReduction_)
    {
        PaymentInfo memory payment_ = payments[paymentId_];

        _removePaymentFromList(paymentId_);

        issuanceRateReduction_ = payment_.issuanceRate;

        accountedInterestIncrease_ = (intervalEnd_ - intervalStart_) * issuanceRate_ / PRECISION;

        payments[paymentId_].issuanceRate = 0;
    }

    function _deletePayment(uint16 loanId_) internal {
        delete payments[paymentIdOf[loanId_]];
        delete paymentIdOf[loanId_];
    }

    function _handlePaymentAccounting(uint16 loanId_) internal returns (uint256 issuanceRate_) {
        LiquidationInfo memory liquidationInfo_ = liquidationInfoFor[loanId_];

        uint256 paymentId_ = paymentIdOf[loanId_];

        if (paymentId_ == 0) {
            revert Errors.LoanManager_NotLoan(loanId_);
        }

        // Remove the payment from the mapping once cached in memory
        PaymentInfo memory paymentInfo_ = payments[paymentId_];
        delete payments[paymentId_];

        emit PaymentRemoved({ loanId_: loanId_, paymentId_: paymentId_ });

        // If the payment has been made against a loan that was impaired, reverse the impairment accounting
        if (liquidationInfo_.principal != 0) {
            _revertLoanImpairment(liquidationInfo_);
            delete liquidationInfoFor[loanId_];
            return 0;
        }

        // If a payment has been made late, its interest has already been fully accounted through
        // `advanceGlobalAccounting` logic.
        // It also has been removed from the sorted list, and its `issuanceRate` has been removed from the global
        // `issuanceRate`
        // The only accounting that must be done is to update the `accountedInterest` to account for the payment being
        // made
        if (block.timestamp > paymentInfo_.dueDate) {
            _compareAndSubtractAccountedInterest(paymentInfo_.incomingNetInterest);
            return 0;
        }

        _removePaymentFromList(paymentId_);
        issuanceRate_ = paymentInfo_.issuanceRate;

        // If the amount of interest claimed is greater than the amount accounted for, set to zero.
        // Discrepancy between accounted andd actual is always captured by balance change in the pool from claimed
        // interest.
        // Reduce the AUM by the amount of interest that was represented for this payment
        _compareAndSubtractAccountedInterest(((block.timestamp - paymentInfo_.startDate) * issuanceRate_) / PRECISION);
    }

    function _queuePayment(uint16 loanId_, uint256 startDate_, uint256 dueDate_) internal returns (uint256 newRate_) {
        uint256 protocolFeeRate_ = ILopoGlobals(_globals()).protocolFeeRate(_poolConfigurator());
        uint256 adminFeeRate_ = IPoolConfigurator(_poolConfigurator()).adminFeeRate();
        uint256 feeRate_ = protocolFeeRate_ + adminFeeRate_;

        LoanInfo memory loan_ = loans[loanId_];

        uint256 interest_ = _getInterest(loan_.principal, loan_.interestRate, dueDate_ - startDate_);
        newRate_ = (_getNetInterest(interest_, feeRate_) * PRECISION) / (dueDate_ - startDate_);

        uint256 paymentId_ = paymentIdOf[loanId_] = _addPaymentToList(SafeCast.toUint48(dueDate_)); // Add the payment
            // to the sorted list

        payments[paymentId_] = PaymentInfo({
            protocolFeeRate: SafeCast.toUint24(protocolFeeRate_),
            adminFeeRate: SafeCast.toUint24(adminFeeRate_),
            startDate: SafeCast.toUint48(startDate_),
            dueDate: SafeCast.toUint48(dueDate_),
            incomingNetInterest: SafeCast.toUint128(newRate_ * (dueDate_ - startDate_) / PRECISION),
            issuanceRate: newRate_
        });

        emit PaymentAdded(loanId_, paymentId_, protocolFeeRate_, adminFeeRate_, startDate_, dueDate_, newRate_);
    }

    function _revertLoanImpairment(LiquidationInfo memory liquidationInfo_) internal {
        _compareAndSubtractAccountedInterest(liquidationInfo_.interest);
        unrealizedLosses -= SafeCast.toUint128(liquidationInfo_.principal + liquidationInfo_.interest);

        emit UnrealizedLossesUpdated(unrealizedLosses);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        INTERNAL PAYMENT SORTING FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _addPaymentToList(uint48 paymentDueDate_) internal returns (uint24 paymentId_) {
        paymentId_ = ++paymentCounter;

        uint24 current_ = uint24(0);
        uint24 next_ = paymentWithEarliestDueDate;

        while (next_ != 0 && paymentDueDate_ >= sortedPayments[next_].paymentDueDate) {
            current_ = next_;
            next_ = sortedPayments[current_].next;
        }

        if (current_ != 0) {
            sortedPayments[current_].next = paymentId_;
        } else {
            paymentWithEarliestDueDate = paymentId_;
        }

        if (next_ != 0) {
            sortedPayments[next_].previous = paymentId_;
        }

        sortedPayments[paymentId_] = SortedPayment({ previous: current_, next: next_, paymentDueDate: paymentDueDate_ });
    }

    function _removePaymentFromList(uint256 paymentId_) internal {
        SortedPayment memory sortedPayment_ = sortedPayments[paymentId_];

        uint24 previous_ = sortedPayment_.previous;
        uint24 next_ = sortedPayment_.next;

        if (paymentWithEarliestDueDate == paymentId_) {
            paymentWithEarliestDueDate = next_;
        }

        if (next_ != 0) {
            sortedPayments[next_].previous = previous_;
        }

        if (previous_ != 0) {
            sortedPayments[previous_].next = next_;
        }

        delete sortedPayments[paymentId_];
    }

    /*//////////////////////////////////////////////////////////////////////////
                        INTERNAL FUNDS DISTRIBUTION FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _distributeClaimedFunds(uint16 loanId_, uint256 principal_, uint256 interest_) internal {
        uint256 paymentId_ = paymentIdOf[loanId_];

        if (paymentId_ == 0) {
            revert Errors.LoanManager_NotLoan(loanId_);
        }

        uint256 protocolFee_ = interest_ * payments[paymentId_].protocolFeeRate / HUNDRED_PERCENT;

        uint256 adminFee_ = IPoolConfigurator(_poolConfigurator()).hasSufficientCover()
            ? interest_ * payments[paymentId_].adminFeeRate / HUNDRED_PERCENT
            : 0;

        uint256 netInterest_ = interest_ - protocolFee_ - adminFee_;

        emit FeesPaid(loanId_, adminFee_, protocolFee_);
        emit FundsDistributed(loanId_, principal_, netInterest_);

        address fundsAsset_ = fundsAsset;

        if (!_transfer(fundsAsset_, _pool(), principal_ + netInterest_)) {
            revert Errors.LoanManager_PoolFundsTransferFailed();
        }
        if (!_transfer(fundsAsset_, _poolAdmin(), adminFee_)) {
            revert Errors.LoanManager_PoolAdminFundsTransferFailed();
        }
        if (!_transfer(fundsAsset_, _vault(), protocolFee_)) {
            revert Errors.LoanManager_VaultFundsTransferFailed();
        }
    }

    function _distributeLiquidationFunds(
        uint16 loanId_,
        uint256 recoveredFunds_,
        uint256 protocolFees_,
        uint256 remainingLosses_
    )
        internal
        returns (uint256 updatedRemainingLosses_, uint256 updatedProtocolFees_)
    {
        uint256 toVault_ = _min(recoveredFunds_, protocolFees_);

        recoveredFunds_ -= toVault_;

        updatedProtocolFees_ = (protocolFees_ -= toVault_);

        uint256 toPool_ = _min(recoveredFunds_, remainingLosses_);

        recoveredFunds_ -= toPool_;

        updatedRemainingLosses_ = (remainingLosses_ -= toPool_);

        address fundsAsset_ = fundsAsset;

        if (!_transfer(fundsAsset_, loans[loanId_].borrower, recoveredFunds_)) {
            revert Errors.LoanManager_BorrowerFundsTransferFailed();
        }
        if (!_transfer(fundsAsset_, _pool(), toPool_)) {
            revert Errors.LoanManager_PoolFundsTransferFailed();
        }
        if (!_transfer(fundsAsset_, _vault(), toVault_)) {
            revert Errors.LoanManager_VaultFundsTransferFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INTERNAL LOAN REPOSESSION FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _handleReposession(
        uint16 loanId_,
        uint256 protocolFees_,
        uint256 netInterest_,
        uint256 netLateInterest_
    )
        internal
        returns (uint256 remainingLosses_, uint256 updatedProtocolFees_)
    {
        LoanInfo memory loan_ = loans[loanId_];

        uint256 principal_ = loan_.principal;

        // Reduce principal out, since it has been accounted for in the liquidation
        emit PrincipalOutUpdated(principalOut -= SafeCast.toUint128(principal_));

        // Calculate the late interest if a late payment was made
        remainingLosses_ = principal_ + netInterest_ + netLateInterest_;

        if (loan_.isImpaired) {
            // Remove unrealized losses that `impairLoan` previously accounted for
            emit UnrealizedLossesUpdated(unrealizedLosses -= SafeCast.toUint128(principal_ + netInterest_));
            delete liquidationInfoFor[loanId_];
        }

        // Recover funds that have not been drawn
        uint256 recoveredFunds_ = loan_.drawableFunds;
        loans[loanId_].drawableFunds = uint256(0);

        (remainingLosses_, updatedProtocolFees_) = recoveredFunds_ == 0
            ? (remainingLosses_, protocolFees_)
            : _distributeLiquidationFunds(loanId_, recoveredFunds_, protocolFees_, remainingLosses_);

        _compareAndSubtractAccountedInterest(netInterest_);

        _updateIssuanceParams(issuanceRate, accountedInterest);

        _deletePayment(loanId_);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            REVERT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _revertIfPaused() internal view {
        if (ILopoGlobals(_globals()).isFunctionPaused(msg.sig)) {
            revert Errors.FunctionPaused(msg.sig);
        }
    }

    function _revertIfNotPoolAdminOrGovernor() internal view {
        if (msg.sender != _poolAdmin() && msg.sender != _governor()) {
            revert Errors.NotPoolAdminOrGovernor({ caller: msg.sender });
        }
    }

    function _revertIfNotPoolAdmin() internal view {
        if (msg.sender != _poolAdmin()) {
            revert Errors.NotPoolAdmin({ caller: msg.sender });
        }
    }

    function _transfer(address asset_, address to_, uint256 amount_) internal returns (bool success_) {
        success_ = (to_ != address(0)) && ((amount_ == 0) || IERC20(asset_).transfer(to_, amount_));
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
        minimum_ = a_ < b_ ? a_ : b_;
    }
}
