// SPDX-License-Identifier: GPL-2.0-only
pragma solidity >=0.6.10 <=0.8.10;
pragma experimental ABIEncoderV2;

import {SafeMath} from '@openzeppelin/contracts/utils/math/SafeMath.sol';
import {BridgeBase} from "../base/BridgeBase.sol";
import {ErrorLib} from "../base/ErrorLib.sol";
import {AztecTypes} from '../../aztec/libraries/AztecTypes.sol';
import {TickMath} from "../../libraries/uniswapv3/TickMath.sol";
import {FullMath} from "../../libraries/uniswapv3/FullMath.sol";
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IRollupProcessor} from "../../aztec/interfaces/IRollupProcessor.sol";
import {ISwapRouter} from '../../interfaces/uniswapv3/ISwapRouter.sol';
import {IUniswapV3Factory} from "../../interfaces/uniswapv3/IUniswapV3Factory.sol";
import {IUniswapV3PoolDerivedState} from "../../interfaces/uniswapv3/pool/IUniswapV3PoolDerivedState.sol";

import {IAaveLeverageModule} from './interfaces/IAaveLeverageModule.sol';
import {IWETH} from '../../interfaces/IWETH.sol';
import {IExchangeIssue} from './interfaces/IExchangeIssue.sol';
import {ISetToken} from './interfaces/ISetToken.sol';
import {AggregatorV3Interface} from './interfaces/AggregatorV3Interface.sol';

/** 
* @title icETH Bridge
* @dev A smart contract responsible for buying and selling icETH with ETH etther through selling/buying from 
* a DEX or by issuing/redeeming icEth set tokens.
*/
contract IndexBridgeContract is BridgeBase {
    using SafeMath for uint256;

    error UnsafeOraclePrice();

    address immutable EXISSUE = 0xB7cc88A13586D862B97a677990de14A122b74598;
    address immutable CURVE = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address immutable WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address immutable STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address immutable ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address immutable ICETH = 0x7C07F7aBe10CE8e33DC6C5aD68FE033085256A84;
    address immutable STETH_PRICE_FEED = 0xAb55Bf4DfBf469ebfe082b7872557D1F87692Fe6;
    address immutable AAVE_LEVERAGE_MODULE = 0x251Bd1D42Df1f153D86a5BA2305FaADE4D5f51DC;
    address immutable CHAINLINK_STETH_ETH = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

    address immutable UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address immutable UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984; 

    constructor(address _rollupProcessor) BridgeBase(_rollupProcessor) {}

    receive() external payable {}

    /**
    * @notice Function that swaps between icETH and ETH.
    * @dev The flow of this functions is based on the type of input and output assets.
    *
    * @param inputAssetA - ETH to buy/issue icETH, icETH to sell/redeem icETH.
    * @param outputAssetA - icETH to buy/issue icETH, ETH to sell/redeem icETH. 
    * @param outputAssetB - ETH to buy/issue icETH, empty to sell/redeem icETH. 
    * @param totalInputValue - Total amount of ETH/icETH to be swapped for icETH/ETH
    * @param interactionNonce - Globablly unique identifier for this bridge call
    * @param auxData - Encodes flowSelector and maxSlip. See notes on the decodeAuxData 
    * function for encoding details.
    * @return outputValueA - Amount of icETH received when buying/issuing, Amount of ETH 
    * received when selling/redeeming.
    * @return outputValueB - Amount of ETH returned when issuing icETH. A portion of ETH 
    * is always returned when issuing icETH since the issuing function in ExchangeIssuance
    * requires an exact output amount rather than input. 
    */
    function convert(
        AztecTypes.AztecAsset calldata inputAssetA,
        AztecTypes.AztecAsset calldata inputAssetB,
        AztecTypes.AztecAsset calldata outputAssetA,
        AztecTypes.AztecAsset calldata outputAssetB,
        uint256 totalInputValue,
        uint256 interactionNonce,
        uint64 auxData,
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

        if (msg.sender != ROLLUP_PROCESSOR) revert ErrorLib.InvalidCaller();

        if ( // To buy/issue
            inputAssetA.assetType == AztecTypes.AztecAssetType.ETH &&
            inputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED &&
            outputAssetA.erc20Address == ICETH 
            ) 
        {

            (outputValueA, outputValueB) = getIcEth(
                totalInputValue, 
                auxData, 
                interactionNonce, 
                outputAssetB
            );

        } else if (  // To sell/redeem  
            inputAssetA.erc20Address == ICETH &&
            inputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED &&
            outputAssetA.assetType == AztecTypes.AztecAssetType.ETH &&
            outputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED 
            ) 
        {

            outputValueA = getEth(totalInputValue, auxData, interactionNonce);

        } else revert ErrorLib.InvalidInput();
        
    }

    // @dev This function always reverts since this contract has not async flow.
    function finalise(
        AztecTypes.AztecAsset calldata inputAssetA,
        AztecTypes.AztecAsset calldata inputAssetB,
        AztecTypes.AztecAsset calldata outputAssetA,
        AztecTypes.AztecAsset calldata outputAssetB,
        uint256 interactionNonce,
        uint64 auxData
    )
        external
        payable
        override
        returns (
            uint256,
            uint256,
            bool
        )
    {
        require(false);
    }

    /**
    * @dev This function either redeems icETH for ETH or sells icETH for ETH on univ3 depending
    * on the expected eth returned.
    *
    * @param totalInputValue - Total amount of icETH to be swapped/redeemed for ETH
    * @param interactionNonce - Globablly unique identifier for this bridge call
    * @param auxData - Encodes flowSelector and maxSlip. See notes on the decodeAuxData 
    * function for encoding details.
    * @return outputValueA - Amount of ETH to return to the Rollupprocessor
    */
    function getEth(
        uint256 totalInputValue,
        uint64 auxData,
        uint256 interactionNonce
    ) 
        internal 
        returns (uint256 outputValueA) 
    {
        (uint64 flowSelector, uint64 maxSlip, uint64 oracleLimit) = decodeAuxdata(auxData); 

        uint256 minAmountOut;  
        if (flowSelector == 1) //redeem icETH for ETH through the ExchangeIssuance contract
        { 
             /**
                Inputs that are too small will result in a loss of precision
                in flashloan calculations. In getAmountBasedOnRedeem() debtOWned
                and colInEth will lose precision. Dito in ExchangeIssuance.
              */
            if (totalInputValue < 1e18) revert ErrorLib.InvalidInputAmount();

            minAmountOut = getAmountBasedOnRedeem(totalInputValue, oracleLimit).mul(maxSlip).div(1e4);
    
            // Creating a SwapData structure used to specify a path in a DEX in the ExchangeIssuance contract
            uint24[] memory fee;
            address[] memory pathToEth = new address[](2); 
            pathToEth[0] = STETH;
            pathToEth[1] = ETH;

            IExchangeIssue.SwapData memory redeemData = IExchangeIssue.SwapData(
                pathToEth, 
                fee,
                CURVE, 
                IExchangeIssue.Exchange.Curve
            );

            ISetToken(ICETH).approve(address(EXISSUE), totalInputValue);
            // Redeem icETH for eth
            IExchangeIssue(EXISSUE).redeemExactSetForETH(
                ISetToken(ICETH),
                totalInputValue,
                minAmountOut,
                redeemData,
                redeemData
            );

            outputValueA = address(this).balance;
            IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueA}(interactionNonce);

        } else { //Sell icETH on univ3

            uint24 uniFee;
            if (flowSelector == 3) {
                uniFee = 3000;
            } else if (flowSelector == 5) {
                uniFee = 500;
            } else revert ErrorLib.InvalidAuxData();

            // Using univ3 TWAP Oracle to get a lower bound on returned ETH.
            minAmountOut = getAmountBasedOnTwap(totalInputValue, ICETH, WETH, uniFee, oracleLimit).mul(maxSlip).div(1e4);
            
            IERC20(ICETH).approve(UNIV3_ROUTER, totalInputValue);
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: ICETH,
                tokenOut: WETH,
                fee: uniFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: totalInputValue,
                amountOutMinimum: minAmountOut, 
                sqrtPriceLimitX96: 0
            });

            outputValueA = ISwapRouter(UNIV3_ROUTER).exactInputSingle(params);

            IWETH(WETH).withdraw(outputValueA);
            IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueA}(interactionNonce);
        }
    }

    /**
    * @dev This function either issues icETH  or buys icETH with ETH on univ3 depending
    * on the expected icETH returned.
    *
    * @param totalInputValue - Total amount of icETH to be swapped/redeem for ETH
    * @param interactionNonce - Globablly unique identifier for this bridge call
    * @param auxData - Encodes flowSelector and maxSlip. See notes on the decodeAuxData 
    * function for encoding details.
    * @return outputValueA - Amount of icETH to return to the Rollupprocessor
    */
    function getIcEth(
        uint256 totalInputValue,
        uint64 auxData,
        uint256 interactionNonce,
        AztecTypes.AztecAsset memory outputAssetB
        
    ) 
        internal 
        returns (uint256 outputValueA, uint256 outputValueB) 
    {
        (uint64 flowSelector, uint64 maxSlip, uint64 oracleLimit) = decodeAuxdata(auxData); 

        uint256 minAmountOut;
        if (flowSelector == 1 && outputAssetB.assetType == AztecTypes.AztecAssetType.ETH){ 

             /**
                Inputs that are too small will result in a loss of precision
                in flashloan calculations. In getAmountBasedOnRedeem() debtOWned
                and colInEth will lose precision. Dito in ExchangeIssuance.
              */

            if (totalInputValue < 1e18) revert ErrorLib.InvalidInputAmount();

            minAmountOut  = getAmountBasedOnIssue(totalInputValue, oracleLimit).mul(maxSlip).div(1e4);

            uint24[] memory fee;
            address[] memory pathToSt = new address[](2);
            pathToSt[0] = ETH;
            pathToSt[1] = STETH;
            IExchangeIssue.SwapData memory issueData = IExchangeIssue.SwapData(
                    pathToSt, fee, CURVE, IExchangeIssue.Exchange.Curve
            );

            IExchangeIssue(EXISSUE).issueExactSetFromETH{value: totalInputValue}(
                ISetToken(ICETH),
                minAmountOut,
                issueData,
                issueData
            );

            outputValueA = ISetToken(ICETH).balanceOf(address(this));
            outputValueB = address(this).balance;

            ISetToken(ICETH).approve(ROLLUP_PROCESSOR, outputValueA);
            IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueB}(interactionNonce);

        } else if (outputAssetB.assetType == AztecTypes.AztecAssetType.NOT_USED){

            uint24 uniFee;
            if (flowSelector == 3) {
                uniFee = 3000;
            } else if (flowSelector == 5) {
                uniFee = 500;
            } else revert ErrorLib.InvalidAuxData();
            
            // Using univ3 TWAP Oracle to get a lower bound on returned ETH.
            minAmountOut = getAmountBasedOnTwap(totalInputValue, WETH, ICETH, uniFee, oracleLimit).mul(maxSlip).div(1e4);
            IWETH(WETH).deposit{value: totalInputValue}();
            IERC20(WETH).approve(UNIV3_ROUTER, totalInputValue);

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: ICETH,
                fee: uniFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: totalInputValue,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0 
            });

            outputValueA = ISwapRouter(UNIV3_ROUTER).exactInputSingle(params);
            ISetToken(ICETH).approve(ROLLUP_PROCESSOR, outputValueA);
        } else revert ErrorLib.InvalidInput();
        
    }

    /**
    * @dev Function that calculated the output of a swap based on univ3's twap price
    * @dev Based on v3-peripher/contracts/libraries/OracleLibrary.sol modified to 
    * explicilty convert uint32 to int32 to support 0.8.x
    *
    * @param amountIn - Amount to be exchanged
    * @param baseToken - Address of tokens to be exchanged
    * @param quoteToken - Address of tokens to be recevied 
    * @return amountOut - Amount received of quoteToken
    */
    function getAmountBasedOnTwap( 
        uint256 amountIn, 
        address baseToken, 
        address quoteToken, 
        uint24 uniFee, 
        uint64 oracleLimit
        ) 
        internal 
        view
        returns (uint256 amountOut)
    { 
        address pool = IUniswapV3Factory(UNIV3_FACTORY).getPool(
            WETH,
            ICETH,
            uniFee
        );

        {
            uint32 secondsAgo = 60*10; 

            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = secondsAgo;
            secondsAgos[1] = 0;

            (int56[] memory tickCumulatives, ) = IUniswapV3PoolDerivedState(pool).observe(
                secondsAgos
            );

            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 arithmeticmeanTick = int24(tickCumulativesDelta / int32(secondsAgo)); 
            
            if (
                tickCumulativesDelta < 0 && (tickCumulativesDelta % int32(secondsAgo) != 0) 
            ) {
                arithmeticmeanTick--;
            }

            amountOut = getQuoteAtTick(
                arithmeticmeanTick,
                uint128(amountIn),
                baseToken,
                quoteToken
            );
        }

        uint256 price;
        if (baseToken == ICETH){
            price = amountOut.mul(1e18).div(amountIn);
            if (price < uint256(oracleLimit).mul(1e14)) revert UnsafeOraclePrice();
        } else {
            price = amountIn.mul(1e18).div(amountOut);
            if (price > uint256(oracleLimit).mul(1e14)) revert UnsafeOraclePrice();
        }
    }

    // From v3-peripher/contracts/libraries/OracleLibrary.sol using modified Fullmath and Tickmath for 0.8.x @audit add natspec
    function getQuoteAtTick( 
        int24 tick, 
        uint128 baseAmount,
        address baseToken,
        address quoteToken
    ) 
        internal 
        pure 
        returns (uint256 quoteAmount) 
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /**
    * @dev Calculates the amount of ETH received from redeeming icETH by taking out a  
    * flashloan of WETH to pay back debt. Chainlink oracle is used for the ETH/stETH price.
    *
    * @param setAmount - Amount of icETH to redeem 
    * @return Expcted amount of ETH returned from redeeming 
    */
    function getAmountBasedOnRedeem(
        uint256 setAmount, 
        uint64 oracleLimit
        ) 
        internal 
        returns (uint256)
    {
        ( , int256 intPrice, , , ) = AggregatorV3Interface(CHAINLINK_STETH_ETH).latestRoundData();
        uint256 price = uint256(intPrice);

        if (price < uint256(oracleLimit).mul(1e14)) revert UnsafeOraclePrice();

        IAaveLeverageModule(AAVE_LEVERAGE_MODULE).sync(ISetToken(ICETH));
        IExchangeIssue.LeveragedTokenData memory issueInfo = IExchangeIssue(EXISSUE).getLeveragedTokenData(
            ISetToken(ICETH), 
            setAmount, 
            true
        );        

        uint256 debtOwed = issueInfo.debtAmount.mul(1.0009 ether).div(1e18);
        uint256 colInEth = issueInfo.collateralAmount.mul(price).div(1e18); 

        return colInEth - debtOwed;
    }

    /**
    * @dev Calculates the amount of icETH issued based on the
    * oracle price of stETH and the cost of the flashloan.
    *
    * @param totalInputValue - Total amount of ETH used to issue icETH.
    * @param oracleLimit - The upper limit of ETH/stETH that is acceptable.
    * @return Amount of icETH issued .
    */
    function getAmountBasedOnIssue( 
        uint256 totalInputValue, 
        uint64 oracleLimit
        )
        internal 
        returns (uint256)
    {
        ( , int256 intPrice, , , ) = AggregatorV3Interface(CHAINLINK_STETH_ETH).latestRoundData();
        uint256 price = uint256(intPrice);

        if (price > uint256(oracleLimit).mul(1e14)) revert UnsafeOraclePrice();

        IAaveLeverageModule(AAVE_LEVERAGE_MODULE).sync(ISetToken(ICETH));
        IExchangeIssue.LeveragedTokenData memory data = IExchangeIssue(EXISSUE).getLeveragedTokenData(
            ISetToken(ICETH),
            1e18,
            true
        );

        uint256 costOfOneIc = (data.collateralAmount.
            mul(1.0009 ether). // Cost of flashlaon
            div(1e18).
            mul(price). // Convert to ETH 
            div(1e18) 
            )
            - data.debtAmount 
        ;

       return totalInputValue.mul(1e18).div(costOfOneIc);
    }

    /**
    * dev decode auxData into two variables 
    *
    * param encoded - encoded auxData the first 32 bytes represent flowSelector 
    * return flowSelector - Used to specify the flow of the bridge:
    *           flowSelector = 1 -> use ExchangeIssue contract to issue/redeem
    *           flowSelector = 3 -> use univ3 pool with a fee of 3000 to buy/sell
    *           flowSelector = 5 -> use univ3 pool with a fee of 500 buy/sell
    * return oracleLimit - Sanity check on Oracle, lower bound on stETH/ETH when 
    * selling/redeeming icETH for ETH. Upper bound when buying/issuing icETH with ETH. 
    * return maxSlip - Used to specific maximal difference between the expected return based
    * on Oracle data and the received amount. maxSlip uses a decimal value of 4 e.g. to set the 
    * minimum discrepency to 1%, maxSlip should be 9900.
    *
    */
    function decodeAuxdata(uint64 encoded) internal pure returns (
        uint64 flowSelector, 
        uint64 maxSlip, 
        uint64 oracleLimit
    ) {

        maxSlip = encoded >> 48;
        oracleLimit =  (encoded << 16) >> 48;
        flowSelector = (encoded << 32) >> 32;

    }
}