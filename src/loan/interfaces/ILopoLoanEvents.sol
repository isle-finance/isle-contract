// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

interface ILopoLoanEvents {
    /**
     *  @dev   Borrower was accepted, and set to a new account.
     *  @param borrower_ The address of the new borrower.
     */
    event BorrowerAccepted(address indexed borrower_);

    /**
     *  @dev   The loan was funded.
     *  @param lender_             The address of the lender.
     *  @param amount_             The amount funded.
     *  @param nextPaymentDueDate_ The due date of the next payment.
     */
    event Funded(address indexed lender_, uint256 amount_, uint256 nextPaymentDueDate_);

    /**
     *  @dev   Funds were claimed.
     *  @param amount_      The amount of funds claimed.
     *  @param destination_ The recipient of the funds claimed.
     */
    event FundsClaimed(uint256 amount_, address indexed destination_);

    /**
     *  @dev   Funds were drawn.
     *  @param amount_      The amount of funds drawn.
     *  @param destination_ The recipient of the funds drawn down.
     */
    event FundsDrawnDown(uint256 amount_, address indexed destination_);

    /**
     *  @dev   Funds were returned.
     *  @param amount_ The amount of funds returned.
     */
    event FundsReturned(uint256 amount_);

    /**
     *  @dev   The loan impairment was explicitly removed (i.e. not the result of a payment or new terms acceptance).
     *  @param nextPaymentDueDate_ The new next payment due date.
     */
    event ImpairmentRemoved(uint256 nextPaymentDueDate_);

    /**
     *  @dev   Loan was initialized.
     *  @param borrower_    The address of the borrower.
     *  @param lender_      The address of the lender.
     *  @param feeManager_  The address of the entity responsible for calculating fees.
     *  @param assets_      Array of asset addresses.
     *                       [0]: collateralAsset,
     *                       [1]: fundsAsset.
     *  @param termDetails_ Array of loan parameters:
     *                       [0]: gracePeriod,
     *                       [1]: paymentInterval,
     *                       [2]: payments,
     *  @param amounts_     Requested amounts:
     *                       [0]: collateralRequired,
     *                       [1]: principalRequested,
     *                       [2]: endingPrincipal.
     *  @param rates_       Fee parameters:
     *                       [0]: interestRate,
     *                       [1]: closingFeeRate,
     *                       [2]: lateFeeRate,
     *                       [3]: lateInterestPremiumRate
     *  @param fees_        Array of fees:
     *                       [0]: delegateOriginationFee,
     *                       [1]: delegateServiceFee
     */
    event Initialized(
        address    indexed borrower_,
        address    indexed lender_,
        address    indexed feeManager_,
        address[2]         assets_,
        uint256[3]         termDetails_,
        uint256[3]         amounts_,
        uint256[4]         rates_,
        uint256[2]         fees_
    );

    /**
     *  @dev   Lender was accepted, and set to a new account.
     *  @param lender_ The address of the new lender.
     */
    event LenderAccepted(address indexed lender_);

    /**
     *  @dev   The next payment due date was fast forwarded to the current time, activating the grace period.
     *         This is emitted when the pool delegate wants to force a payment (or default).
     *  @param nextPaymentDueDate_ The new next payment due date.
     */
    event LoanImpaired(uint256 nextPaymentDueDate_);

    /**
     *  @dev   Loan was repaid early and closed.
     *  @param principalPaid_ The portion of the total amount that went towards principal.
     *  @param interestPaid_  The portion of the total amount that went towards interest.
     *  @param feesPaid_      The portion of the total amount that went towards fees.
     */
    event LoanClosed(uint256 principalPaid_, uint256 interestPaid_, uint256 feesPaid_);

    /**
     *  @dev   Payments were made.
     *  @param principalPaid_ The portion of the total amount that went towards principal.
     *  @param interestPaid_  The portion of the total amount that went towards interest.
     *  @param fees_          The portion of the total amount that went towards fees.
     */
    event PaymentMade(uint256 principalPaid_, uint256 interestPaid_, uint256 fees_);

    /**
     *  @dev   Pending borrower was set.
     *  @param pendingBorrower_ Address that can accept the borrower role.
     */
    event PendingBorrowerSet(address pendingBorrower_);

    /**
     *  @dev   Pending lender was set.
     *  @param pendingLender_ Address that can accept the lender role.
     */
    event PendingLenderSet(address pendingLender_);

    /**
     *  @dev   The loan was in default and funds and collateral was repossessed by the lender.
     *  @param collateralRepossessed_ The amount of collateral asset repossessed.
     *  @param fundsRepossessed_      The amount of funds asset repossessed.
     *  @param destination_           The recipient of the collateral and funds, if any.
     */
    event Repossessed(uint256 collateralRepossessed_, uint256 fundsRepossessed_, address indexed destination_);

    /**
     *  @dev   Some token (neither fundsAsset nor collateralAsset) was removed from the loan.
     *  @param token_       The address of the token contract.
     *  @param amount_      The amount of token remove from the loan.
     *  @param destination_ The recipient of the token.
     */
    event Skimmed(address indexed token_, uint256 amount_, address indexed destination_);
}
