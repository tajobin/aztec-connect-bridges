// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity >=0.6.10 <=0.8.10;
pragma experimental ABIEncoderV2;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IVault, IAsset, PoolSpecialization} from './interfaces/IVault.sol';
import {IPool} from './interfaces/IPool.sol';
import {ITranche} from './interfaces/ITranche.sol';
import {IERC20Permit, IERC20} from '../../interfaces/IERC20Permit.sol';
import {IWrappedPosition} from './interfaces/IWrappedPosition.sol';
import {IRollupProcessor} from '../../interfaces/IRollupProcessor.sol';

import {IDefiBridge} from '../../interfaces/IDefiBridge.sol';

import {AztecTypes} from '../../aztec/AztecTypes.sol';

import { console } from '../../test/console.sol';

contract ElementBridge is IDefiBridge {

    error INVALID_TRANCHE();
    error INVALID_WRAPPED_POSITION();
    error INVALID_POOL();
    error INVALID_CALLER();
    error ASSET_IDS_NOT_EQUAL();
    error ASSET_NOT_ERC20();
    error INTERACTION_ALREADY_EXISTS();
    error POOL_NOT_FOUND();
    error UNKNOWN_NONCE();
    error BRIDGE_NOT_READY();
    error ALREADY_FINALISED();
    error TRANCHE_POSITION_MISMATCH();
    error TRANCHE_UNDERLYING_MISMATCH();
    error POOL_UNDERLYING_MISMATCH();
    error POOL_EXPIRY_MISMATCH();
    error VAULT_ADDRESS_VERIFICATION_FAILED();
    error VAULT_ADDRESS_MISMATCH();

    // capture the minimum info required to recall a deposit
    struct Interaction {
        uint256 quantityPT;
        address trancheAddress;
        uint64 expiry;
        bool finalised;
        bool failed;
    }

    // minimum info required to execute a deposit
    struct Pool {
        bytes32 poolId;
        address trancheAddress;
        address poolAddress;
        address wrappedPositionAddress;
    }

    // info pertaining to the funds we have in a given tranche
    struct TrancheAccount {
        uint256 quantityTokensHeld;
        uint256 quantityAssetRedeemed;
        uint256 quantityAssetRemaining;
        uint32 numDeposits;
        uint32 numFinalised;
        bool redemptionFailed;
    }

    // Tranche factory address for Tranche contract address derivation
    address private immutable trancheFactory;
    // Tranche bytecode hash for Tranche contract address derivation.
    // This is constant as long as Tranche does not implement non-constant constructor arguments.
    bytes32 private immutable trancheBytecodeHash; // = 0xf481a073666136ab1f5e93b296e84df58092065256d0db23b2d22b62c68e978d;

    // cache of all of our pending Defi interactions. keyed on nonce
    mapping(uint256 => Interaction) public interactions;

    mapping(address => uint64[]) public assetToExpirys;

    // cache of all pools we are able to interact with
    mapping(uint256 => Pool) public pools;

    // cahce of all of our tranche accounts
    mapping(address => TrancheAccount) private trancheAccounts;

    // the aztec rollup processor contract
    address public immutable rollupProcessor;

    // the balancer contract
    address private immutable balancerAddress;

    uint64[] private heap;
    mapping(uint64 => uint256[]) private expiryToNonce;

    // 48 hours in seconds, usd for calculating speeedbump expiries
    uint256 internal constant _FORTY_EIGHT_HOURS = 172800;

    uint256 internal constant MAX_INT = 2**256 - 1;

    // the amount of gas that we need to have available for a redemption finalise
    // the amount of gas that we need to have available for a non-redemption finalise
    uint256 private immutable GAS_REQUIRED_FOR_REDEMPTION_FINALISE;
    uint256 private immutable GAS_REQUIRED_FOR_NON_REDEMPTION_FINALISE;

    event Convert(uint256 indexed nonce, uint256 totalInputValue);

    event Finalise(uint256 indexed nonce, bool success, string message);

    event PoolAdded(address poolAddress, address wrappedPositionAddress, uint64 expiry);

    constructor(
        address _rollupProcessor,
        address _trancheFactory,
        bytes32 _trancheBytecodeHash,
        address _balancerVaultAddress,
        uint256 _gasForRedemptionFinalise,
        uint256 _gasForNonRedemptionFinalise
    ) {
        rollupProcessor = _rollupProcessor;
        trancheFactory = _trancheFactory;
        trancheBytecodeHash = _trancheBytecodeHash;
        balancerAddress = _balancerVaultAddress;
        GAS_REQUIRED_FOR_REDEMPTION_FINALISE = _gasForRedemptionFinalise;
        GAS_REQUIRED_FOR_NON_REDEMPTION_FINALISE = _gasForNonRedemptionFinalise;
    }

    function getAssetExpiries(address asset) public view returns (uint64[] memory assetExpiries) {
        return assetToExpirys[asset];
    }

    // this function allows for the dynamic addition of new asset/expiry combinations as they come online
    function registerConvergentPoolAddress(
        address _convergentPool,
        address _wrappedPosition,
        uint64 _expiry
    ) external {
        // stores a mapping between tranche address and pool.
        // required to look up the swap info on balancer
        checkAndStorePoolSpecification(_wrappedPosition, _expiry, _convergentPool);
    }

    /// @dev This internal function produces the deterministic create2
    ///      address of the Tranche contract from a wrapped position contract and expiration
    /// @param _position The wrapped position contract address
    /// @param _expiration The expiration time of the tranche as a uint256
    /// @return The derived Tranche contract
    function deriveTranche(address _position, uint256 _expiration) internal view virtual returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_position, _expiration));
        bytes32 addressBytes = keccak256(abi.encodePacked(bytes1(0xff), trancheFactory, salt, trancheBytecodeHash));
        return address(uint160(uint256(addressBytes)));
    }

    struct PoolSpec {
        uint256 poolExpiry;
        bytes32 poolId;
        address underlyingAsset;
        address trancheAddress;
        address tranchePosition;
        address trancheUnderlying;
        address poolUnderlying;
        address poolVaultAddress;
    }

    // function to validate a pool specification
    // do the wrapped position address, the pool address and the expiry cross reference with one another
    function checkAndStorePoolSpecification(
        address wrappedPositionAddress,
        uint64 expiry,
        address poolAddress
    ) internal {
        PoolSpec memory poolSpec;
        IWrappedPosition wrappedPosition = IWrappedPosition(wrappedPositionAddress);
        // this underlying asset should be the real asset i.e. DAI stablecoin etc
        try wrappedPosition.token() returns (IERC20 wrappedPositionToken) {
            poolSpec.underlyingAsset = address(wrappedPositionToken);
        } catch {
            revert INVALID_WRAPPED_POSITION();
        }
        // this should be the address of the Element tranche for the asset/expiry pair
        poolSpec.trancheAddress = deriveTranche(wrappedPositionAddress, expiry);
        // get the wrapped position held in the tranche to cross check against that provided
        ITranche tranche = ITranche(poolSpec.trancheAddress);
        try tranche.position() returns (IERC20 tranchePositionToken) {
            poolSpec.tranchePosition = address(tranchePositionToken);
        } catch {
            revert INVALID_TRANCHE();
        }
        // get the underlying held in the tranche to cross check against that provided
        try tranche.underlying() returns (IERC20 trancheUnderlying) {
            poolSpec.trancheUnderlying = address(trancheUnderlying);
        } catch {
            revert INVALID_TRANCHE();
        }

        if (poolSpec.tranchePosition != wrappedPositionAddress) {
            revert TRANCHE_POSITION_MISMATCH();
        }
        if (poolSpec.trancheUnderlying != poolSpec.underlyingAsset) {
            revert TRANCHE_UNDERLYING_MISMATCH();
        }
        // get the pool underlying to cross check against that provided
        IPool pool = IPool(poolAddress);
        try pool.underlying() returns (IERC20 poolUnderlying) {
            poolSpec.poolUnderlying = address(poolUnderlying);
        } catch {
            revert INVALID_POOL();
        }
        // get the pool expiry to cross check against that provided
        try pool.expiration() returns (uint256 poolExpiry) {
            poolSpec.poolExpiry = poolExpiry;
        } catch {
            revert INVALID_POOL();
        }
        // get the vault associated with the pool
        try pool.getVault() returns (IVault poolVault) {
            poolSpec.poolVaultAddress = address(poolVault);
        } catch {
            revert INVALID_POOL();
        }
        // get the pool id associated with the pool
        try pool.getPoolId() returns (bytes32 poolId) {
            poolSpec.poolId = poolId;
        } catch {
            revert INVALID_POOL();
        }
        if (poolSpec.poolUnderlying != poolSpec.underlyingAsset) {
            revert POOL_UNDERLYING_MISMATCH();
        }
        if (poolSpec.poolExpiry != expiry) {
            revert POOL_EXPIRY_MISMATCH();
        }
        //verify that the vault address is equal to our balancer address
        if (poolSpec.poolVaultAddress != balancerAddress) {
            revert VAULT_ADDRESS_VERIFICATION_FAILED();
        }

        // retrieve the pool address for the given pool id from balancer
        // then test it against that given to us
        IVault balancerVault = IVault(balancerAddress);
        (address balancersPoolAddress, ) = balancerVault.getPool(poolSpec.poolId);
        if (poolAddress != balancersPoolAddress) {
            revert VAULT_ADDRESS_MISMATCH();
        }

        // we store the pool information against a hash of the asset and expiry
        uint256 assetExpiryHash = hashAssetAndExpiry(poolSpec.underlyingAsset, expiry);
        pools[assetExpiryHash] = Pool(poolSpec.poolId, poolSpec.trancheAddress, poolAddress, wrappedPositionAddress);
        uint64[] storage expiriesForAsset = assetToExpirys[poolSpec.underlyingAsset];
        uint256 expiryIndex = 0;
        while (expiryIndex < expiriesForAsset.length && expiriesForAsset[expiryIndex] != expiry) {
            ++expiryIndex;
        }
        if (expiryIndex == expiriesForAsset.length) {
            expiriesForAsset.push(expiry);
        }
        
        // initialising the expiry -> nonce mapping here like this reduces a chunk of gas later when we start to add interactions for this expiry
        uint256[] storage nonces = expiryToNonce[expiry];
        if (nonces.length == 0) {
            expiryToNonce[expiry].push(MAX_INT);
        }
        emit PoolAdded(poolAddress, wrappedPositionAddress, expiry);
    }

    function hashAssetAndExpiry(address asset, uint64 expiry) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(asset, uint256(expiry))));
    }

    // convert the input asset to the output asset
    // serves as the 'on ramp' to the interaction
    function convert(
        AztecTypes.AztecAsset calldata inputAssetA,
        AztecTypes.AztecAsset calldata,
        AztecTypes.AztecAsset calldata outputAssetA,
        AztecTypes.AztecAsset calldata,
        uint256 totalInputValue,
        uint256 interactionNonce,
        uint64 auxData,
        address rollupBeneficiary
    )
        external
        payable
        override
        returns (
            uint256 outputValueA,
            uint256 outputValueB,
            bool isAsync
        )
    {
        // ### INITIALIZATION AND SANITY CHECKS
        if (msg.sender != rollupProcessor) {
            revert INVALID_CALLER();
        }
        if (inputAssetA.id != outputAssetA.id) {
            revert ASSET_IDS_NOT_EQUAL();
        }
        if (inputAssetA.assetType != AztecTypes.AztecAssetType.ERC20) {
            revert ASSET_NOT_ERC20();
        }
        if (interactions[interactionNonce].expiry != 0) {
            revert INTERACTION_ALREADY_EXISTS();
        }
        
        // operation is asynchronous
        isAsync = true;
        // retrieve the appropriate pool for this interaction and verify that it exists
        Pool storage pool = pools[hashAssetAndExpiry(inputAssetA.erc20Address, auxData)];
        if (pool.trancheAddress == address(0)) {
            revert POOL_NOT_FOUND();
        }
        // approve the transfer of tokens to the balancer address
        ERC20(inputAssetA.erc20Address).approve(balancerAddress, totalInputValue);
        // execute the swap on balancer
        address inputAsset = inputAssetA.erc20Address;

        uint256 principalTokensAmount = IVault(balancerAddress).swap(
            IVault.SingleSwap({
                poolId: pool.poolId,
                kind: IVault.SwapKind.GIVEN_IN,
                assetIn: IAsset(inputAsset),
                assetOut: IAsset(pool.trancheAddress),
                amount: totalInputValue,
                userData: '0x00'
            }),
            IVault.FundManagement({
                sender: address(this), // the bridge has already received the tokens from the rollup so it owns totalInputValue of inputAssetA
                fromInternalBalance: false,
                recipient: payable(address(this)),
                toInternalBalance: false
            }),
            totalInputValue, // discuss with ELement on the likely slippage for a large trade e.g $1M Dai
            block.timestamp
        );
        // store the tranche that underpins our interaction, the expiry and the number of received tokens against the nonce
        interactions[interactionNonce] = Interaction(principalTokensAmount, pool.trancheAddress, auxData, false, false);
        // add the nonce and expiry to our expiry heap
        addNonceAndExpiry(interactionNonce, auxData);
        // increase our tranche account
        TrancheAccount storage trancheAccount = trancheAccounts[pool.trancheAddress];
        trancheAccount.numDeposits++;
        trancheAccount.quantityTokensHeld += principalTokensAmount;
        emit Convert(interactionNonce, totalInputValue);

        bool continueFinalising = true;
        while (continueFinalising) {
            // check the heap to see if we can finalise an expired transaction
            (bool expiryAvailable, bool requiresRedemption, uint64 expiry, uint256 nonce) = checkNextExpiry();
            continueFinalising = expiryAvailable && gasleft() >= (requiresRedemption ? GAS_REQUIRED_FOR_REDEMPTION_FINALISE : GAS_REQUIRED_FOR_NON_REDEMPTION_FINALISE);
            if (continueFinalising) {
                // another position is available for finalising, inform the rollup contract
                IRollupProcessor(rollupProcessor).processAsyncDefiInteraction(nonce);
            }
        }
    }

    // serves as the 'off ramp' for the transaction
    // converts the principal tokens back to the underlying asset
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
            uint256 outputValueA,
            uint256 outputValueB,
            bool interactionCompleted
        )
    {
        if (msg.sender != rollupProcessor) {
            revert INVALID_CALLER();
        }
        // retrieve the interaction and verify it's ready for finalising
        Interaction storage interaction = interactions[interactionNonce];
        if (interaction.expiry == 0) {
            revert UNKNOWN_NONCE();
        }
        if (interaction.expiry > block.timestamp) {
            revert BRIDGE_NOT_READY();
        }
        if (interaction.finalised) {
            revert ALREADY_FINALISED();
        }

        TrancheAccount storage trancheAccount = trancheAccounts[interaction.trancheAddress];
        if (trancheAccount.quantityTokensHeld == 0) {
            // shouldn't be possible!!
            setInteractionAsFailure(interaction, interactionNonce, 'INTERNAL_ERROR');
            return (0, 0, false);
        }

        if (trancheAccount.quantityAssetRedeemed == 0) {
            // tranche not redeemed, we need to withdraw the principal
            // convert the tokens back to underlying using the tranche
            ITranche tranche = ITranche(interaction.trancheAddress);
            try tranche.withdrawPrincipal(trancheAccount.quantityTokensHeld, address(this)) returns (uint256 valueRedeemed) {
                trancheAccount.quantityAssetRedeemed = valueRedeemed;
                trancheAccount.quantityAssetRemaining = valueRedeemed;
                trancheAccount.redemptionFailed = false;
            } catch Error(string memory errorMessage) {
                setInteractionAsFailure(interaction, interactionNonce, errorMessage);
                trancheAccount.redemptionFailed = true;
                popInteraction(interaction, interactionNonce);
                return (0, 0, false);
            } catch {
                setInteractionAsFailure(interaction, interactionNonce, 'UNKNOWN_ERROR');
                trancheAccount.redemptionFailed = true;
                popInteraction(interaction, interactionNonce);
                return (0, 0, false);
            }
        }

        // at this point, the tranche must have been redeemed and we can allocate proportionately to this interaction
        uint256 amountToAllocate = (trancheAccount.quantityAssetRedeemed * interaction.quantityPT) / trancheAccount.quantityTokensHeld;
        uint256 remainingFinalises = trancheAccount.numDeposits - trancheAccount.numFinalised;
        if (remainingFinalises == 1 || amountToAllocate > trancheAccount.quantityAssetRemaining) {
            // if there are no more interactions to finalise after this then allocate all the remaining
            // or, if we managed to allocate more than the amount remaining
            amountToAllocate = trancheAccount.quantityAssetRemaining;
        }
        trancheAccount.quantityAssetRemaining -= amountToAllocate;
        trancheAccount.numFinalised++;

        // approve the transfer of funds back to the rollup contract
        ERC20(outputAssetA.erc20Address).approve(rollupProcessor, amountToAllocate);
        interaction.finalised = true;
        popInteraction(interaction, interactionNonce);
        outputValueA = amountToAllocate;
        interactionCompleted = true;
        emit Finalise(interactionNonce, interactionCompleted, '');
    }

    function setInteractionAsFailure(
        Interaction storage interaction,
        uint256 interactionNonce,
        string memory message
    ) internal {
        interaction.failed = true;
        emit Finalise(interactionNonce, false, message);
    }

    // add an interaction nonce and expiry to the expiry heap
    function addNonceAndExpiry(uint256 nonce, uint64 expiry) internal returns (bool expiryAdded) {
        // get the set of nonces already against this expiry
        // check for the MAX_INT placeholder nonce that exists to reduce gas costs at this point in the code
        uint256[] storage nonces = expiryToNonce[expiry];
        if (nonces.length == 1 && nonces[0] == MAX_INT) {
            nonces[0] = nonce;
        } else {
            nonces.push(nonce);
        }
        // is this the first time this expiry has been requested?
        // if so then add it to our expiry heap
        if (nonces.length == 1) {
            addToHeap(expiry);
            expiryAdded = true;
        }
    }

    // move an expiry up through the heap to the correct position
    function siftUp(uint256 index) internal {
        uint64 value = heap[index];
        while (index > 0) {
            uint256 parentIndex = index / 2;
            if (heap[parentIndex] <= value) {
                break;
            }
            heap[index] = heap[parentIndex]; // update
            index = index / 2;
        }
        heap[index] = value;
    }

    // add a new expiry to the heap
    function addToHeap(uint64 expiry) internal {
        // standard min-heap insertion
        // push to the end of the heap and sift up.
        // there is a high probability that the expiry being added will remain where it is
        // so this operation will end up being O(1)
        heap.push(expiry); // write
        uint256 index = heap.length - 1;
        siftUp(index);
    }

    // remove the root expiry from the heap
    function popFromHeap() internal {
        // if the heap is empty then nothing to do
        if (heap.length == 0) {
            return;
        }
        // read the value in the last position and shrink the array by 1
        uint64 last = heap[heap.length - 1];
        heap.pop();
        // now sift down but no need to swap parent and child nodes
        // we just write the child value into the parent each time
        // then once we no longer have any smaller children, we write the 'last' value into place
        // requires a total of O(logN) updates
        uint256 index = 0;
        while (index < heap.length) {
            // get the indices of the child values
            uint256 leftChildIndex = (index * 2) + 1;
            uint256 rightChildIndex = leftChildIndex + 1;
            uint256 swapIndex = index;
            uint64 smallestValue = last;

            // identify the smallest child, first check the left
            if (leftChildIndex < heap.length && heap[leftChildIndex] < smallestValue) {
                swapIndex = leftChildIndex;
                smallestValue = heap[leftChildIndex];
            }
            // then check the right
            if (rightChildIndex < heap.length && heap[rightChildIndex] < smallestValue) {
                swapIndex = rightChildIndex;
            }
            // if neither child was smaller then nothing more to do
            if (swapIndex == index) {
                heap[index] = smallestValue;
                break;
            }
            // take the value from the smallest child and write in into our slot
            heap[index] = heap[swapIndex];
            index = swapIndex;
        }
    }

    // clean an interaction from the heap
    // optimised to remove the last interaction for the earliest expiry but will work in all cases (just at the expense of gas)
    function popInteraction(Interaction storage interaction, uint256 interactionNonce) internal returns (bool expiryRemoved) {
        uint256[] storage nonces = expiryToNonce[interaction.expiry];
        if (nonces.length == 0) {
            return (false);
        }
        uint256 index = nonces.length - 1;
        while (index > 0 && nonces[index] != interactionNonce) {
            --index;
        }
        if (nonces[index] != interactionNonce) {
            return (false);
        }
        if (index != nonces.length - 1) {
            nonces[index] = nonces[nonces.length - 1];
        }
        nonces.pop();

        // if there are no more nonces left for this expiry then remove it from the heap
        if (nonces.length == 0) {
            removeExpiryFromHeap(interaction.expiry);
            delete expiryToNonce[interaction.expiry];
            return (true);
        }
    }

    // will remove an expiry from the min-heap
    function removeExpiryFromHeap(uint64 expiry) internal {
        uint256 index = 0;
        while (index < heap.length && heap[index] != expiry) {
            ++index;
        }
        if (index == heap.length) {
            return;
        }
        if (index != 0) {
            heap[index] = 0;
            siftUp(index);
        }
        popFromHeap();
    }

    // fast lookup to determine if we have an interaction that can be finalised
    function checkNextExpiry()
        internal
        returns (
            bool expiryAvailable,
            bool requiresRedemption,
            uint64 expiry,
            uint256 nonce
        )
    {
        // do we have any expiries and if so is the earliest expiry now expired
        if (heap.length == 0) {
            return (false, false, 0, 0);
        }
        uint64 nextExpiry = heap[0];
        if (nextExpiry > block.timestamp) {
            // oldest expiry is still not expired
            return (false, false, 0, 0);
        }
        // we have some expired interactions
        uint256[] storage nonces = expiryToNonce[nextExpiry];
        while (nonces.length > 0) {
            uint256 nextNonce = nonces[nonces.length - 1];
            if (nextNonce == MAX_INT) {
                // this shouldn't happen, this value is the placeholder for reducing gas costs on convert
                // we just need to pop and continue
                nonces.pop();
                continue;
            }
            Interaction storage interaction = interactions[nextNonce];
            if (interaction.expiry == 0 || interaction.finalised) {
                // this shouldn't happen, suggests the interaction has been finalised already but not removed from the expiry heap
                // remove the nonce and continue searching
                nonces.pop();
                continue;
            }
            // we have valid interaction for the next expiry, check if it can be finalised
            (bool canBeFinalised, bool interactionRequiresRedemption, string memory message) = interactionCanBeFinalised(interaction);
            if (!canBeFinalised) {
                // can't be finalised, add to failures and pop from nonces
                setInteractionAsFailure(interaction, nextNonce, message);
                nonces.pop();
                continue;
            }
            return (true, interactionRequiresRedemption, nextExpiry, nextNonce);
        }

        // if we are here then we have run out of nonces for this expiry so pop from the heap
        popFromHeap();
    }

    function interactionCanBeFinalised(Interaction storage interaction) internal returns (bool canBeFinalised, bool requiresRedemption, string memory message) {
        TrancheAccount storage trancheAccount = trancheAccounts[interaction.trancheAddress];
        if (trancheAccount.quantityTokensHeld == 0) {
            // shouldn't happen, suggests we don't have an account for this tranche!
            return (false, false, 'INTERNAL_ERROR');
        }
        if (trancheAccount.redemptionFailed == true) {
            return (false, false, 'TRANCHE_REDEMPTION_FAILED');
        }
        // determine if the tranche has already been redeemed
        if (trancheAccount.quantityAssetRedeemed > 0) {
            // tranche was previously redeemed
            if (trancheAccount.quantityAssetRemaining == 0) {
                // this is a problem. we have already allocated out all of the redeemed assets!
                return (false, false, 'INTERNAL_ERROR');
            }
            // this interaction can be finalised. we don't need to redeem the tranche, we just need to allocate the redeemed asset
            return (true, false, '');
        }
        // tranche hasn't been redeemed, now check to see if we can redeem it
        ITranche tranche = ITranche(interaction.trancheAddress);
        uint256 speedbump = tranche.speedbump();
        if (speedbump != 0) {
            uint256 newExpiry = speedbump + _FORTY_EIGHT_HOURS;
            if (newExpiry > block.timestamp) {
                // a speedbump is in force for this tranche and it is beyond the current time
                trancheAccount.redemptionFailed = true;
                return (false, false, 'SPEEDBUMP');
            }
        }
        address wpAddress = address(tranche.position());
        IWrappedPosition wrappedPosition = IWrappedPosition(wpAddress);
        address underlyingAddress = address(wrappedPosition.token());
        address yearnVaultAddress = address(wrappedPosition.vault());
        uint256 vaultQuantity = ERC20(underlyingAddress).balanceOf(yearnVaultAddress);
        if (trancheAccount.quantityTokensHeld > vaultQuantity) {
            trancheAccount.redemptionFailed = true;
            return (false, false, 'VAULT_BALANCE');
        }
        // at this point, we will need to redeem the tranche which should be possible
        return (true, true, '');
    }
}
