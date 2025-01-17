// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {BridgeBase} from "../base/BridgeBase.sol";
import {ErrorLib} from "../base/ErrorLib.sol";
import {AztecTypes} from "../../aztec/libraries/AztecTypes.sol";
import {OracleLibrary} from "../../libraries/uniswapv3/OracleLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRollupProcessor} from "../../aztec/interfaces/IRollupProcessor.sol";
import {ISwapRouter} from "../../interfaces/uniswapv3/ISwapRouter.sol";
import {IUniswapV3Factory} from "../../interfaces/uniswapv3/IUniswapV3Factory.sol";
import {IUniswapV3PoolDerivedState} from "../../interfaces/uniswapv3/pool/IUniswapV3PoolDerivedState.sol";
import {IAaveLeverageModule} from "../../interfaces/set/IAaveLeverageModule.sol";
import {ISetToken} from "../../interfaces/set/ISetToken.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {IExchangeIssuanceLeveraged} from "../../interfaces/set/IExchangeIssuanceLeveraged.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title icETH Bridge
 * @notice A smart contract responsible for buying and selling icETH with ETH either through selling/buying from
 * a DEX or by issuing/redeeming icEth set tokens.
 */
contract IndexBridgeContract is BridgeBase {
    using SafeERC20 for IERC20;

    error UnsafeOraclePrice();

    address public constant EXCHANGE_ISSUANCE = 0xB7cc88A13586D862B97a677990de14A122b74598;
    address public constant CURVE = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant ICETH = 0x7C07F7aBe10CE8e33DC6C5aD68FE033085256A84;
    address public constant STETH_PRICE_FEED = 0xAb55Bf4DfBf469ebfe082b7872557D1F87692Fe6;
    address public constant AAVE_LEVERAGE_MODULE = 0x251Bd1D42Df1f153D86a5BA2305FaADE4D5f51DC;
    address public constant CHAINLINK_STETH_ETH = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

    address public constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    uint256 private constant DUST = 1;

    constructor(address _rollupProcessor) BridgeBase(_rollupProcessor) {
        // Tokens can be pre approved since the bridge should not hold any tokens.
        IERC20(ICETH).safeIncreaseAllowance(address(EXCHANGE_ISSUANCE), type(uint256).max);
        IERC20(ICETH).safeIncreaseAllowance(UNIV3_ROUTER, type(uint256).max);
        IERC20(ICETH).safeIncreaseAllowance(ROLLUP_PROCESSOR, type(uint256).max);
        IERC20(WETH).safeIncreaseAllowance(UNIV3_ROUTER, type(uint256).max);
    }

    receive() external payable {}

    /**
     * @notice Function that swaps between icETH and ETH.
     * @dev The flow of this functions is based on the type of input and output assets.
     *
     * @param _inputAssetA - ETH to buy/issue icETH, icETH to sell/redeem icETH.
     * @param _outputAssetA - icETH to buy/issue icETH, ETH to sell/redeem icETH.
     * @param _outputAssetB - ETH to buy/issue icETH, empty to sell/redeem icETH.
     * @param _totalInputValue - Total amount of ETH/icETH to be swapped for icETH/ETH
     * @param _interactionNonce - Globablly unique identifier for this bridge call
     * @param _auxData - Encodes flowSelector and maxSlip. See notes on the decodeAuxData
     * function for encoding details.
     * @return outputValueA - Amount of icETH received when buying/issuing, Amount of ETH
     * received when selling/redeeming.
     * @return outputValueB - Amount of ETH returned when issuing icETH. A portion of ETH
     * is always returned when issuing icETH since the issuing function in ExchangeIssuance
     * requires an exact output amount rather than input.
     */
    function convert(
        AztecTypes.AztecAsset calldata _inputAssetA,
        AztecTypes.AztecAsset calldata _inputAssetB,
        AztecTypes.AztecAsset calldata _outputAssetA,
        AztecTypes.AztecAsset calldata _outputAssetB,
        uint256 _totalInputValue,
        uint256 _interactionNonce,
        uint64 _auxData,
        address
    )
        external
        payable
        override(BridgeBase)
        onlyRollup
        returns (
            uint256 outputValueA,
            uint256 outputValueB,
            bool isAsync
        )
    {
        isAsync = false;

        if (
            // To buy/issue
            _inputAssetA.assetType == AztecTypes.AztecAssetType.ETH &&
            _inputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED &&
            _outputAssetA.erc20Address == ICETH
        ) {
            (outputValueA, outputValueB) = _getIcEth(_totalInputValue, _auxData, _interactionNonce, _outputAssetB);
        } else if (
            // To sell/redeem
            _inputAssetA.erc20Address == ICETH &&
            _inputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED &&
            _outputAssetA.assetType == AztecTypes.AztecAssetType.ETH &&
            _outputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED
        ) {
            outputValueA = _getEth(_totalInputValue - DUST, _auxData, _interactionNonce);
        } else revert ErrorLib.InvalidInput();
    }

    /**
     * @dev This function either redeems icETH for ETH or sells icETH for ETH on univ3 depending
     * on the expected eth returned.
     *
     * @param _totalInputValue - Total amount of icETH to be swapped/redeemed for ETH
     * @param _interactionNonce - Globablly unique identifier for this bridge call
     * @param _auxData - Encodes flowSelector and maxSlip. See notes on the decodeAuxData
     * function for encoding details.
     * @return outputValueA - Amount of ETH to return to the RollupProcessor
     */
    function _getEth(
        uint256 _totalInputValue,
        uint64 _auxData,
        uint256 _interactionNonce
    ) internal returns (uint256 outputValueA) {
        (uint64 flowSelector, uint64 maxSlip, uint64 oracleLimit) = _decodeAuxdata(_auxData);

        uint256 minAmountOut;
        if (flowSelector == 1) //redeem icETH for ETH through the ExchangeIssuance contract
        {
            /**
                Inputs that are too small will result in a loss of precision
                in flashloan calculations. In getAmountBasedOnRedeem() debtOWned
                and colInEth will lose precision. Dito in ExchangeIssuance.
              */
            if (_totalInputValue < 1e18) revert ErrorLib.InvalidInputAmount();

            minAmountOut = (_getAmountBasedOnRedeem(_totalInputValue, oracleLimit) * maxSlip) / 1e4;

            // Creating a SwapData structure used to specify a path in a DEX in the ExchangeIssuance contract
            uint24[] memory fee;
            address[] memory pathToEth = new address[](2);
            pathToEth[0] = STETH;
            pathToEth[1] = ETH;

            IExchangeIssuanceLeveraged.SwapData memory redeemData = IExchangeIssuanceLeveraged.SwapData(
                pathToEth,
                fee,
                CURVE,
                IExchangeIssuanceLeveraged.Exchange.Curve
            );

            // Redeem icETH for eth
            IExchangeIssuanceLeveraged(EXCHANGE_ISSUANCE).redeemExactSetForETH(
                ISetToken(ICETH),
                _totalInputValue,
                minAmountOut,
                redeemData,
                redeemData
            );

            outputValueA = address(this).balance;
            IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueA}(_interactionNonce);
        } else {
            //Sell icETH on univ3

            uint24 _uniFee;
            if (flowSelector == 3) {
                _uniFee = 3000;
            } else if (flowSelector == 5) {
                _uniFee = 500;
            } else revert ErrorLib.InvalidAuxData();

            // Using univ3 TWAP Oracle to get a lower bound on returned ETH.
            minAmountOut = (_getAmountBasedOnTwap(_totalInputValue, ICETH, WETH, _uniFee, oracleLimit) * maxSlip) / 1e4;

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: ICETH,
                tokenOut: WETH,
                fee: _uniFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _totalInputValue,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

            outputValueA = ISwapRouter(UNIV3_ROUTER).exactInputSingle(params) - DUST;

            IWETH(WETH).withdraw(outputValueA);
            IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueA}(_interactionNonce);
        }
    }

    /**
     * @dev This function either issues icETH  or buys icETH with ETH on univ3 depending
     * on the expected icETH returned.
     *
     * @param _totalInputValue - Total amount of icETH to be swapped/redeem for ETH
     * @param _interactionNonce - Globablly unique identifier for this bridge call
     * @param _auxData - Encodes flowSelector and maxSlip. See notes on the decodeAuxData
     * function for encoding details.
     * @return outputValueA - Amount of icETH to return to the Rollupprocessor
     */
    function _getIcEth(
        uint256 _totalInputValue,
        uint64 _auxData,
        uint256 _interactionNonce,
        AztecTypes.AztecAsset memory _outputAssetB
    ) internal returns (uint256 outputValueA, uint256 outputValueB) {
        (uint64 flowSelector, uint64 maxSlip, uint64 oracleLimit) = _decodeAuxdata(_auxData);

        uint256 minAmountOut;
        if (flowSelector == 1 && _outputAssetB.assetType == AztecTypes.AztecAssetType.ETH) {
            /**
                Inputs that are too small will result in a loss of precision
                in flashloan calculations. In getAmountBasedOnRedeem() debtOWned
                and colInEth will lose precision. Dito in ExchangeIssuance.
              */

            if (_totalInputValue < 1e18) revert ErrorLib.InvalidInputAmount();

            minAmountOut = (_getAmountBasedOnIssue(_totalInputValue, oracleLimit) * maxSlip) / 1e4;

            uint24[] memory fee;
            address[] memory pathToSt = new address[](2);
            pathToSt[0] = ETH;
            pathToSt[1] = STETH;
            IExchangeIssuanceLeveraged.SwapData memory issueData = IExchangeIssuanceLeveraged.SwapData(
                pathToSt,
                fee,
                CURVE,
                IExchangeIssuanceLeveraged.Exchange.Curve
            );

            IExchangeIssuanceLeveraged(EXCHANGE_ISSUANCE).issueExactSetFromETH{value: _totalInputValue}(
                ISetToken(ICETH),
                minAmountOut,
                issueData,
                issueData
            );

            outputValueA = ISetToken(ICETH).balanceOf(address(this)) - DUST;
            outputValueB = address(this).balance;

            IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueB}(_interactionNonce);
        } else if (_outputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED) {
            uint24 uniFee;
            if (flowSelector == 3) {
                uniFee = 3000;
            } else if (flowSelector == 5) {
                uniFee = 500;
            } else revert ErrorLib.InvalidAuxData();

            // Using univ3 TWAP Oracle to get a lower bound on returned ETH.
            minAmountOut = (_getAmountBasedOnTwap(_totalInputValue, WETH, ICETH, uniFee, oracleLimit) * maxSlip) / 1e4;
            IWETH(WETH).deposit{value: _totalInputValue}();

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: ICETH,
                fee: uniFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _totalInputValue,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

            outputValueA = ISwapRouter(UNIV3_ROUTER).exactInputSingle(params) - DUST;
        } else revert ErrorLib.InvalidInput();
    }

    /**
     * @dev Function that calculated the output of a swap based on univ3's twap price
     * @dev Based on v3-peripher/contracts/libraries/OracleLibrary.sol modified to
     * explicilty convert uint32 to int32 to support 0.8.x
     *
     * @param _amountIn - Amount to be exchanged
     * @param _baseToken - Address of tokens to be exchanged
     * @param _quoteToken - Address of tokens to be recevied
     * @return amountOut - Amount received of quoteToken
     */
    function _getAmountBasedOnTwap(
        uint256 _amountIn,
        address _baseToken,
        address _quoteToken,
        uint24 _uniFee,
        uint64 _oracleLimit
    ) internal view returns (uint256 amountOut) {
        address pool = IUniswapV3Factory(UNIV3_FACTORY).getPool(WETH, ICETH, _uniFee);

        {
            uint32 secondsAgo = 10;

            (int24 arithmeticmeanTick, ) = OracleLibrary.consult(pool, secondsAgo);

            amountOut = OracleLibrary.getQuoteAtTick(arithmeticmeanTick, uint128(_amountIn), _baseToken, _quoteToken);
        }

        uint256 price;
        if (_baseToken == ICETH) {
            price = (amountOut * 1e18) / _amountIn;
            if (price < uint256(_oracleLimit) * 1e14) revert UnsafeOraclePrice();
        } else {
            price = (_amountIn * 1e18) / amountOut;
            if (price > uint256(_oracleLimit) * 1e14) revert UnsafeOraclePrice();
        }
    }

    /**
     * @dev Calculates the amount of ETH received from redeeming icETH by taking out a
     * flashloan of WETH to pay back debt. Chainlink oracle is used for the ETH/stETH price.
     *
     * @param _setAmount - Amount of icETH to redeem
     * @return Expected amount of ETH returned from redeeming
     */
    function _getAmountBasedOnRedeem(uint256 _setAmount, uint64 _oracleLimit) internal returns (uint256) {
        (, int256 intPrice, , , ) = AggregatorV3Interface(CHAINLINK_STETH_ETH).latestRoundData();
        uint256 price = uint256(intPrice);

        if (price < uint256(_oracleLimit) * 1e14) revert UnsafeOraclePrice();

        IAaveLeverageModule(AAVE_LEVERAGE_MODULE).sync(ISetToken(ICETH));
        IExchangeIssuanceLeveraged.LeveragedTokenData memory issueInfo = IExchangeIssuanceLeveraged(EXCHANGE_ISSUANCE)
            .getLeveragedTokenData(ISetToken(ICETH), _setAmount, true);

        uint256 debtOwed = (issueInfo.debtAmount * (1.0009 ether)) / 1e18;
        uint256 colInEth = (issueInfo.collateralAmount * price) / 1e18;

        return colInEth - debtOwed;
    }

    /**
     * @dev Calculates the amount of icETH issued based on the
     * oracle price of stETH and the cost of the flashloan.
     *
     * @param _totalInputValue - Total amount of ETH used to issue icETH.
     * @param _oracleLimit - The upper limit of ETH/stETH that is acceptable.
     * @return Amount of icETH issued .
     */
    function _getAmountBasedOnIssue(uint256 _totalInputValue, uint64 _oracleLimit) internal returns (uint256) {
        (, int256 intPrice, , , ) = AggregatorV3Interface(CHAINLINK_STETH_ETH).latestRoundData();
        uint256 price = uint256(intPrice);

        if (price > uint256(_oracleLimit) * 1e14) revert UnsafeOraclePrice();

        IAaveLeverageModule(AAVE_LEVERAGE_MODULE).sync(ISetToken(ICETH));
        IExchangeIssuanceLeveraged.LeveragedTokenData memory data = IExchangeIssuanceLeveraged(EXCHANGE_ISSUANCE)
            .getLeveragedTokenData(ISetToken(ICETH), 1e18, true);

        uint256 costOfOneIc = (((data.collateralAmount * 1.0009 ether) / uint256(1e18)) * price) /
            1e18 - // Cost of flashlaon
            data.debtAmount;

        return (_totalInputValue * 1e18) / costOfOneIc;
    }

    /**
     * @dev decode auxData into two variables
     * @param _encoded - encoded auxData the first 32 bytes represent flowSelector
     * @return flowSelector - Used to specify the flow of the bridge:
     *           flowSelector = 1 -> use ExchangeIssue contract to issue/redeem
     *           flowSelector = 3 -> use univ3 pool with a fee of 3000 to buy/sell
     *           flowSelector = 5 -> use univ3 pool with a fee of 500 buy/sell
     * @return maxSlip - Used to specific maximal difference between the expected return based
     * on Oracle data and the received amount. maxSlip uses a decimal value of 4 e.g. to set the
     * minimum discrepency to 1%, maxSlip should be 9900.
     * @return oracleLimit - A safety feature that is either the upper or lower limit
     * of the prices reported by an Oracles, it is set with 4 decimals. If we are buying
     * or issuing it is the upper limit, if we are selling/redeeming it is the lower limit.
     * If we are going through issuing/redeeming it is a limit on ETH/stETH from Chainlink,
     * if we are buying/selling on uniswap it is a limit on the ETH/icETH TWAP price.
     */
    function _decodeAuxdata(uint64 _encoded)
        internal
        pure
        returns (
            uint64 flowSelector,
            uint64 maxSlip,
            uint64 oracleLimit
        )
    {
        maxSlip = _encoded >> 48;
        oracleLimit = (_encoded << 16) >> 48;
        flowSelector = (_encoded << 32) >> 32;
    }
}
