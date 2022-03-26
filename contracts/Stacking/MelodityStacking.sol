// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "../StackingPanda.sol";
import "../PRNG.sol";
import "./StackingReceipt.sol";

/**
	@author Emanuele (ebalo) Balsamo
	@custom:security-contact security@melodity.org
 */
contract MelodityStacking is ERC721Holder, Ownable, Pausable, ReentrancyGuard {
	address constant public _DO_INC_MULTISIG_WALLET = 0x01Af10f1343C05855955418bb99302A6CF71aCB8;
	uint256 constant public _PERCENTAGE_SCALE = 10 ** 20;
	uint256 constant public _EPOCH_DURATION = 1 hours;

	/// Max fee if withdraw occurr before withdrawFeePeriod days
	uint256 constant public _MAX_FEE_PERCENTAGE = 10 ether;
	/// Min fee if withdraw occurr before withdrawFeePeriod days
	uint256 constant public _MIN_FEE_PERCENTAGE = 0.1 ether;

	/**
		@param startingTime Era starting time
		@param eraDuration Era duration (in seconds)
		@param rewardScaleFactor Factor that the current reward will be
		 		multiplied to at the end of the current era
		@param eraScaleFactor Factor that the current era duration will be
				multiplied to at the end of the current era
	 */
	struct EraInfo {
		uint256 startingTime;
		uint256 eraDuration;
		uint256 rewardScaleFactor;
		uint256 eraScaleFactor;
		uint256 rewardFactorPerEpoch;
	}

	/**
		@param rewardPool Amount of MELD yet to distribute from this stacking contract
		@param receiptValue Receipt token value
		@param lastReceiptUpdateTime Last update time of the receipt value
		@param eraDuration First era duration misured in seconds
		@param genesisEraDuration Contract genesis timestamp, used to start eras calculation
		@param genesisRewardScaleFactor Contract genesis reward scaling factor
		@param genesisEraScaleFactor Contract genesis era scaling factor
		@param lastComputedEra Index of the last computed era in the eraInfos array
	 */
	struct PoolInfo {
		uint256 rewardPool;
		uint256 receiptValue;
		uint256 lastReceiptUpdateTime;
		uint256 genesisEraDuration;
		uint256 genesisTime;
		uint256 genesisRewardScaleFactor;
		uint256 genesisEraScaleFactor;
		uint256 genesisRewardFactorPerEpoch;
		bool exhausting;
		bool dismissed;
		uint256 lastComputedEra;
	}

	/**
		@param feePercentage Currently applied fee percentage for early withdraw
		@param feeReceiver Address where the fees gets sent
		@param withdrawFeePeriod Number of days or hours that a deposit is considered to 
				under the withdraw with fee period
		@param feeReceiverPercentage Share of the fee that goes to the feeReceiver
		@param feeMaintainerPercentage Share of the fee that goes to the _DO_INC_MULTISIG_WALLET
		@param feeReceiverMinPercent Minimum percentage that can be given to the feeReceiver
		@param feeMaintainerMinPercent Minimum percentage that can be given to the _DO_INC_MULTISIG_WALLET
	 */
	struct FeeInfo {
		uint256 feePercentage;
		address feeReceiver;
		uint256 withdrawFeePeriod;
		uint256 feeReceiverPercentage;
		uint256 feeMaintainerPercentage;
		uint256 feeReceiverMinPercent;
		uint256 feeMaintainerMinPercent;
	}

	/**
		@param stackedAmount Amount of receipt received during the stacking deposit, in order to withdraw the NFT this
				value *MUST* be zero
		@param nftId NFT identifier
	 */
	struct StackedNFT {
		uint256 stackedAmount;
		uint256 nftId;
	}

	/**
		+-------------------+ 
	 	|  Stacking values  |
	 	+-------------------+
		@notice funds must be sent to this address in order to actually start rewarding
				users

		@dev poolInfo: pool information container
		@dev eraInfos: array of EraInfo where startingTime, endingTime, rewardPerEpoch
				and eraDuration gets defined in a per era basis
		@dev stackersLastDeposit: stacker last executed deposit, reset at each deposit
		@dev stackedNFTs: Association between an address and its stacked NFTs
		@dev depositorNFT: Association between an NFT identifier and the depositor address
	*/
	PoolInfo public poolInfo;
	FeeInfo public feeInfo;
	EraInfo[] public eraInfos;
	mapping(address => uint256) private stackersLastDeposit;
	mapping(address => uint256) private stackersHigherDeposit;
	mapping(address => StackedNFT[]) public stackedNFTs;
	mapping(uint256 => address) public depositorNFT;

    ERC20 public melodity;
	StackingReceipt public stackingReceipt;
    PRNG public prng;
	StackingPanda public stackingPanda;

	event Deposit(address indexed account, uint256 amount, uint256 receiptAmount);
	event NFTDeposit(address indexed account, uint256 nftId, uint256 nftPositionIndex);
	event ReceiptValueUpdate(uint256 value);
	event Withdraw(address indexed account, uint256 amount, uint256 receiptAmount);
	event NFTWithdraw(address indexed account, uint256 nftId);
	event FeePaid(uint256 amount, uint256 receiptAmount);
	event RewardPoolIncreased(uint256 insertedAmount);
	event PoolExhausting(uint256 amountLeft);
	event PoolRefilled(uint256 amountLeft);
	event EraDurationUpdate(uint256 oldDuration, uint256 newDuration);
	event RewardScalingFactorUpdate(uint256 oldFactor, uint256 newFactor);
	event EraScalingFactorUpdate(uint256 oldFactor, uint256 newFactor);
	event EarlyWithdrawFeeUpdate(uint256 oldFactor, uint256 newFactor);
	event FeeReceiverUpdate(address _old, address _new);
	event WithdrawPeriodUpdate(uint256 oldPeriod, uint256 newPeriod);
	event DaoFeeSharedUpdate(uint256 oldShare, uint256 newShare);
	event MaintainerFeeSharedUpdate(uint256 oldShare, uint256 newShare);
	event PoolDismissed();

	/**
		Initialize the values of the stacking contract

		@param _prng The masterchef generator contract address,
			it deploies other contracts
		@param _melodity Melodity ERC20 contract address
	 */
    constructor(address _prng, address _stackingPanda, address _melodity, address _dao, uint8 _erasToGenerate) {
		prng = PRNG(_prng);
		stackingPanda = StackingPanda(_stackingPanda);
		melodity = ERC20(_melodity);
		stackingReceipt = new StackingReceipt("Melodity stacking receipt", "sMELD");
		
		poolInfo = PoolInfo({
			rewardPool: 20_000_000 ether,
			receiptValue: 1 ether,
			lastReceiptUpdateTime: block.timestamp,
			genesisEraDuration: 720 * _EPOCH_DURATION,
			genesisTime: block.timestamp,
			genesisRewardScaleFactor: 79 ether,
			genesisEraScaleFactor: 107 ether,
			genesisRewardFactorPerEpoch: 0.001 ether,
			exhausting: false,
			dismissed: false,
			lastComputedEra: 0
		});

		feeInfo = FeeInfo({
			feePercentage: 10 ether,
			feeReceiver: _dao,
			withdrawFeePeriod: 7 days,
			feeReceiverPercentage: 5 ether,
			feeMaintainerPercentage: 95 ether,
			feeReceiverMinPercent: 5 ether,
			feeMaintainerMinPercent: 25 ether
		});

		_triggerErasInfoRefresh(_erasToGenerate);
    }

	function getEraInfosLength() public view returns(uint256) {
		return eraInfos.length;
	}

	function getNewEraInfo(uint256 k) private view returns(EraInfo memory) {
		// get the genesis value or the last one available.
		// NOTE: as this is a modification of existing values the last available value before
		// 		the curren one is stored as the (k-1)-th element of the eraInfos array
		uint256 lastTimestamp = k == 0 ? poolInfo.genesisTime : eraInfos[k - 1].startingTime + eraInfos[k - 1].eraDuration;
		uint256 lastEraDuration = k == 0 ? poolInfo.genesisEraDuration : eraInfos[k - 1].eraDuration;
		uint256 lastEraScalingFactor = k == 0 ? poolInfo.genesisEraScaleFactor : eraInfos[k - 1].eraScaleFactor;
		uint256 lastRewardScalingFactor = k == 0 ? poolInfo.genesisRewardScaleFactor : eraInfos[k - 1].rewardScaleFactor;
		uint256 lastEpochRewardFactor = k == 0 ? poolInfo.genesisRewardFactorPerEpoch : eraInfos[k - 1].rewardFactorPerEpoch;

		uint256 newEraDuration = k != 0 ? lastEraDuration * lastEraScalingFactor / _PERCENTAGE_SCALE : poolInfo.genesisEraDuration;

		return EraInfo({
			// new eras starts always the second after the ending of the previous
			// if era-1 ends at sec 1234 era-2 will start at sec 1235
			startingTime: lastTimestamp + 1,
			eraDuration: newEraDuration,
			rewardScaleFactor: lastRewardScalingFactor,
			eraScaleFactor: lastEraScalingFactor,
			rewardFactorPerEpoch: k != 0 ? lastEpochRewardFactor * lastRewardScalingFactor / _PERCENTAGE_SCALE : poolInfo.genesisRewardFactorPerEpoch
		});
	}

	/**
		Trigger the regeneration of _erasToGenerate (at most 128) eras from the current
		one.
		The regenerated eras will use the latest defined eraScaleFactor and rewardScaleFactor
		to compute the eras duration and reward.
		Playing around with the number of eras and the scaling factor caller by this method can
		(re-)generate an arbitrary number of eras (not already started) increasing or decreasing 
		their rewardScaleFactor and eraScaleFactor

		@notice This method overwrites the next era definition first, then moves adding new eras
		@param _erasToGenerate Number of eras to (re-)generate
	 */
	function _triggerErasInfoRefresh(uint8 _erasToGenerate) private {
		// 9
		uint256 existingEraInfoCount = eraInfos.length;
		uint256 i;
		uint256 k;

		// - 0: 0 < 1 ? true
		// - 1: 1 < 1 ? false
		while(i < _erasToGenerate) {
			// check if exists some era infos, if they exists check if the k-th era is already started
			// if it is already started it cannot be edited and we won't consider it actually increasing 
			// k
			// - 0: 9 > 0 ? true & 1646996113 < 1648269466 ? true => pass
			// - 0: 9 > 1 ? true & 1649588114 < 1648269466 ? false
			if(existingEraInfoCount > k && eraInfos[k].startingTime <= block.timestamp) {
				k++;
			}
			// if the era is not yet started we can modify its values
			// - 0: 9 > 1 ? true & 1649588114 > 1648269466 ? true => pass
			else if(existingEraInfoCount > k && eraInfos[k].startingTime > block.timestamp) {
				// - 0: k = 1 & {
					// 	startingTime: 1649588114,
					// 	eraDuration: 2047680,
					// 	rewardScaleFactor: 79000000000000000000,
					// 	eraScaleFactor: 107000000000000000000,
					// 	rewardFactorPerEpoch: 790000000000000
				// }
				eraInfos[k] = getNewEraInfo(k);

				// as an era was just updated increase the i counter
				i++;
				// in order to move to the next era or start creating a new one we also need to increase
				// k counter
				k++;
			}
			// start generating new eras info if the number of existing eras is equal to the last computed
			else if(existingEraInfoCount == k) {
				eraInfos.push(getNewEraInfo(k));

				// as an era was just created increase the i counter
				i++;
				// in order to move to the next era and start creating a new one we also need to increase
				// k counter and the existingErasInfos counter
				existingEraInfoCount = eraInfos.length;
				k++;
			}
		}
	}

	/**
		Deposit the provided MELD into the stacking pool

		@param _amount Amount of MELD that will be stacked
	 */
	function deposit(uint256 _amount) public nonReentrant whenNotPaused returns(uint256) {
		return _deposit(_amount);
	}

	/**
		Deposit the provided MELD into the stacking pool

		@notice private function to avoid reentrancy guard triggering

		@param _amount Amount of MELD that will be stacked
	 */
	function _deposit(uint256 _amount) private returns(uint256) {
		prng.seedRotate();

		require(_amount > 0, "Unable to deposit null amount");

		refreshReceiptValue();

		// transfer the funds from the sender to the stacking contract, the contract balance will
		// increase but the reward pool will not
		melodity.transferFrom(msg.sender, address(this), _amount);

		// weighted stake last time
		// NOTE: prev_date = 0 => balance = 0, equation reduces to block.timestamp
		uint256 prev_date = stackersLastDeposit[msg.sender];
		uint256 balance = stackingReceipt.balanceOf(msg.sender);
		stackersLastDeposit[msg.sender] = (balance + _amount) > 0 ?
			prev_date + (block.timestamp - prev_date) * (_amount / (balance + _amount)) :
			prev_date;

		// mint the stacking receipt to the depositor
		uint256 receiptAmount = _amount * 1 ether / poolInfo.receiptValue;
		stackingReceipt.mint(msg.sender, receiptAmount);

		emit Deposit(msg.sender, _amount, receiptAmount);

		return receiptAmount;
	}

	/**
		Deposit the provided MELD into the stacking pool.
		This method deposits also the provided NFT into the stacking pool and mints the bonus receipts
		to the stacker

		@param _amount Amount of MELD that will be stacked
		@param _nftId NFT identifier that will be stacked with the funds
	 */
	function depositWithNFT(uint256 _amount, uint256 _nftId) public nonReentrant whenNotPaused {
		prng.seedRotate();

		// withdraw the nft from the sender
		stackingPanda.safeTransferFrom(msg.sender, address(this), _nftId);
		StackingPanda.Metadata memory metadata = stackingPanda.getMetadata(_nftId);

		// make a standard deposit with the funds
		uint256 receipt = _deposit(_amount);

		// compute and mint the stacking receipt of the bonus given by the NFT
		uint256 bonusAmount = _amount * metadata.bonus.meldToMeld / _PERCENTAGE_SCALE;
		uint256 receiptAmount = bonusAmount * 1 ether / poolInfo.receiptValue;
		stackingReceipt.mint(msg.sender, receiptAmount);
		
		// In order to withdraw the nft the stacked amount for the given NFT *MUST* be zero
		stackedNFTs[msg.sender].push(StackedNFT({
			stackedAmount: receipt + receiptAmount,
			nftId: _nftId
		}));
		depositorNFT[_nftId] = msg.sender;

		emit NFTDeposit(msg.sender, _nftId, stackedNFTs[msg.sender].length -1);
	}

	/**
		Withdraw the receipt from the pool

		@param _amount Receipt amount to reconvert to MELD
	 */
	function withdraw(uint256 _amount) public nonReentrant {
		return _withdraw(_amount);
    }

	/**
		Withdraw the receipt from the pool

		@notice private function to avoid reentrancy guard triggering

		@param _amount Receipt amount to reconvert to MELD
	 */
	function _withdraw(uint256 _amount) private {
		prng.seedRotate();

        require(_amount > 0, "Nothing to withdraw");

		refreshReceiptValue();

		// burn the receipt from the sender address
        stackingReceipt.burnFrom(msg.sender, _amount);

		uint256 meldToWithdraw = _amount * poolInfo.receiptValue / 1 ether;

		// reduce the reward pool
		poolInfo.rewardPool -= meldToWithdraw - _amount;
		_checkIfExhausting();

		uint256 lastAction = stackersLastDeposit[msg.sender];
		uint256 _now = block.timestamp;

		// check if the last deposit was done at least feeInfo.withdrawFeePeriod seconds
		// in the past, if it was then the user has no fee to pay for the withdraw
		// proceed with a direct transfer of the balance needed
		if(lastAction < _now && lastAction + feeInfo.withdrawFeePeriod < _now) {
			melodity.transfer(msg.sender, meldToWithdraw);
			emit Withdraw(msg.sender, meldToWithdraw, _amount);
		}
		// user have to pay withdraw fee
		else {
			uint256 fee = meldToWithdraw * feeInfo.feePercentage / _PERCENTAGE_SCALE;
			// deduct fee from the amount to withdraw
			meldToWithdraw -= fee;

			// split fee with dao and maintainer
			uint256 daoFee = fee * feeInfo.feeReceiverPercentage / _PERCENTAGE_SCALE;
			uint256 maintainerFee = fee - daoFee;

			melodity.transfer(feeInfo.feeReceiver, daoFee);
			melodity.transfer(_DO_INC_MULTISIG_WALLET, maintainerFee);
			emit FeePaid(fee, fee * poolInfo.receiptValue);

			melodity.transfer(msg.sender, meldToWithdraw);
			emit Withdraw(msg.sender, meldToWithdraw, _amount);
		}
    }

	/**
		Withdraw the receipt and the deposited NFT (if possible) from the stacking pool

		@notice Withdrawing an amount higher then the deposited one and having more than
				one NFT stacked may lead to the permanent lock of the NFT in the contract.
				The NFT may be retrieved re-providing the funds for stacking and withdrawing
				the required amount of funds using this method

		@param _amount Receipt amount to reconvert to MELD
		@param _index Index of the stackedNFTs array whose NFT will be recovered if possible
	 */
	function withdrawWithNFT(uint256 _amount, uint256 _index) public nonReentrant {
		prng.seedRotate();
		
		require(stackedNFTs[msg.sender].length > _index, "Index out of bound");

		// run the standard withdraw
		_withdraw(_amount);

		StackedNFT storage stackedNFT = stackedNFTs[msg.sender][_index];

		// if the amount withdrawn is greater or equal to the stacked amount than allow the
		// withdraw of the NFT
		// ALERT: withdrawing an amount higher then the deposited one and having more than
		//		one NFT stacked may lead to the permanent lock of the NFT in the contract.
		//		The NFT may be retrieved re-providing the funds for stacking and withdrawing
		//		the required amount of funds using this method
		if(_amount >= stackedNFT.stackedAmount) {
			// avoid overflow with 1 nft only, swap the element and the latest one only
			// if the array has more than one element
			if(stackedNFTs[msg.sender].length -1 > 0) {
				stackedNFTs[msg.sender][_index] = stackedNFTs[msg.sender][stackedNFTs[msg.sender].length - 1];
			}
			// remove the element from the array
			stackedNFTs[msg.sender].pop();
			depositorNFT[stackedNFT.nftId] = address(0);

			// refund the NFT to the original owner
			stackingPanda.safeTransferFrom(address(this), msg.sender, stackedNFT.nftId);
			emit NFTWithdraw(msg.sender, stackedNFT.nftId);
		}
		// otherwise simply reduce the stacked amount by the withdrawn amount
		else {
			stackedNFT.stackedAmount -= _amount;
		}
	}

	/**
		Checks if the reward pool is less then 1mln MELD, if it is mark the pool
		as exhausting and emit the PoolExhausting event
	 */
	function _checkIfExhausting() private {
		if(poolInfo.rewardPool < 1_000_000 ether) {
			poolInfo.exhausting = true;
			emit PoolExhausting(poolInfo.rewardPool);
		}
	}

	/**
		Update the receipt value if necessary

		@notice This method *MUST* never be marked as nonReentrant as if no valid era was found it
				calls itself back after the generation of 2 new era infos
	 */
	function refreshReceiptValuePaginated(uint256 max_cicles) public {
		prng.seedRotate();

		// 1648268987
		uint256 _now = block.timestamp;
		// 1646996112
		uint256 lastUpdateTime = poolInfo.lastReceiptUpdateTime;
		// pass
		require(lastUpdateTime < _now, "Receipt value already update in this transaction");

		poolInfo.lastReceiptUpdateTime = block.timestamp;

		uint256 eraEndingTime;
		bool validEraFound = true;
		// 10
		uint256 length = eraInfos.length;

		// In case _now exceeds the last era info ending time validEraFound would be true this will avoid the creation
		// of new era infos leading to pool locking and price not updating anymore
		// 9
		uint256 last_index = eraInfos.length - 1;
		// 1678043047 + 4765280
		uint256 last_era_ending_time = eraInfos[last_index].startingTime + eraInfos[last_index].eraDuration;
		// false
		if(_now > last_era_ending_time) {
			validEraFound = false;
		}

		// No valid era exists this mean that the following era data were not generated yet, 
		// estimate the number of required eras then generate them
		// always enters as the default value will always be false, at least an era will always be generated
		if(!validEraFound) {
			// estimate needed era infos and always add 1
			uint256 eras_to_generate = 1;
			while(_now > last_era_ending_time) {
				EraInfo memory ei = getNewEraInfo(last_index);
				last_era_ending_time = ei.startingTime + ei.eraDuration;
				last_index++;
			}
			eras_to_generate += last_index - eraInfos.length;
			
			// to check
			_triggerErasInfoRefresh(uint8(eras_to_generate));
		}

		// set a max cap of cicles to do, if the cap exceeds the eras computed than use length as max cap
		// 2
		uint256 proposed_length = poolInfo.lastComputedEra + max_cicles;
		// 2
		length = proposed_length > length ? length : proposed_length;

		// i = 0
		for(uint256 i = poolInfo.lastComputedEra; i < length; i++) {
			// - 0: 1646996113 + 2592000
			eraEndingTime = eraInfos[i].startingTime + eraInfos[i].eraDuration;

			// check if the lastUpdateTime is inside the currently checking era
			// - 0: 1646996113 < 1646996112 ? false & ...
			if(eraInfos[i].startingTime <= lastUpdateTime && lastUpdateTime <= eraEndingTime) {
				// check if _now is in the same era of the lastUpdateTime, if it is then use _now to recompute the receipt value
				if(eraInfos[i].startingTime <= _now && _now <= eraEndingTime) {
					// NOTE: here some epochs may get lost as lastUpdateTime will almost never be equal to the exact epoch
					// 		update time, in order to avoid this error we compute the difference from the lastUpdateTime
					//		and the difference from the start of this era, as the two value will differ most of the times
					//		we compute the real number of epoch from the last fully completed one
					uint256 diff = (_now - lastUpdateTime) / _EPOCH_DURATION;

					// recompute the receipt value missingFullEpochs times
					while(diff > 0) {
						poolInfo.receiptValue += poolInfo.receiptValue * eraInfos[i].rewardFactorPerEpoch / _PERCENTAGE_SCALE;
						diff--;
					}
					poolInfo.lastReceiptUpdateTime = lastUpdateTime + diff * _EPOCH_DURATION;
					poolInfo.lastComputedEra = i;

					// as _now was into the given era, we can stop the current loop here
					break;
				}
				// if it is in a different era then proceed using the eraEndingTime to compute the number of epochs left to
				// include in the current era and then proceed with the next value
				else {
					// NOTE: here some epochs may get lost as lastUpdateTime will almost never be equal to the exact epoch
					// 		update time, in order to avoid this error we compute the difference from the lastUpdateTime
					//		and the difference from the start of this era, as the two value will differ most of the times
					//		we compute the real number of epoch from the last fully completed one
					uint256 diffFromEpochStartAlignment = _EPOCH_DURATION - (eraEndingTime % _EPOCH_DURATION);
					uint256 realEpochStartTime = eraEndingTime - diffFromEpochStartAlignment;
					uint256 diff = (eraEndingTime - lastUpdateTime) / _EPOCH_DURATION;

					// recompute the receipt value missingFullEpochs times
					while(diff > 0) {
						poolInfo.receiptValue += poolInfo.receiptValue * eraInfos[i].rewardFactorPerEpoch / _PERCENTAGE_SCALE;
						diff--;
					}
					poolInfo.lastReceiptUpdateTime = realEpochStartTime;
					poolInfo.lastComputedEra = i;

					// as accessing the next era info using index+1 can throw an index out of bound the
					// next era starting time is computed based on the curren era
					lastUpdateTime = eraInfos[i].startingTime + eraInfos[i].eraDuration + 1;
				}
			}
		}

		emit ReceiptValueUpdate(poolInfo.receiptValue);
	}

	/**
		Update the receipt value if necessary

		@notice This method *MUST* never be marked as nonReentrant as if no valid era was found it
				calls itself back after the generation of 2 new era infos
	 */
	function refreshReceiptValue() public {
		refreshReceiptValuePaginated(2);
	}

	/**
		Retrieve the current era index in the eraInfos array

		@return Index of the current era
	 */
	function getCurrentEraIndex() public view returns(uint256) {
		uint256 _now = block.timestamp;
		uint256 eraEndingTime;
		for(uint256 i; i < eraInfos.length; i++) {
			eraEndingTime = eraInfos[i].startingTime + eraInfos[i].eraDuration;
			if(eraInfos[i].startingTime <= _now && _now <= eraEndingTime) {
				return i;
			}
		}
		return 0;
	}

	/**
		Returns the ordinal number of the current era

		@return Number of era passed
	 */
	function getCurrentEra() public view returns(uint256) {
		return getCurrentEraIndex() + 1;
	}

	/**
		Returns the number of epoch passed from the start of the pool

		@return Number or epoch passed
	 */
	function getEpochPassed() public view returns(uint256) {
		uint256 _now = block.timestamp;
		uint256 lastUpdateTime = poolInfo.lastReceiptUpdateTime;
		uint256 currentEra = getCurrentEraIndex();
		uint256 passedEpoch;
		uint256 eraEndingTime;

		// loop through previous eras
		for(uint256 i; i < currentEra; i++) {
			eraEndingTime = eraInfos[i].startingTime + eraInfos[i].eraDuration;
			passedEpoch += (eraInfos[i].startingTime - eraEndingTime) / _EPOCH_DURATION;
		}

		uint256 diffSinceLastUpdate = _now - lastUpdateTime;
		uint256 epochsSinceLastUpdate = diffSinceLastUpdate / _EPOCH_DURATION;

		uint256 diffSinceEraStart = _now - eraInfos[currentEra].startingTime;
		uint256 epochsSinceEraStart = diffSinceEraStart / _EPOCH_DURATION;

		uint256 missingFullEpochs = epochsSinceLastUpdate;

		if(epochsSinceEraStart > epochsSinceLastUpdate) {
			missingFullEpochs = epochsSinceEraStart - epochsSinceLastUpdate;
		}

		return passedEpoch + missingFullEpochs;
	}

	/**
		Increase the reward pool of this contract of _amount.
		Funds gets withdrawn from the caller address

		@param _amount MELD to insert into the reward pool
	 */
	function increaseRewardPool(uint256 _amount) public onlyOwner nonReentrant {
		prng.seedRotate();

		require(_amount > 0, "Unable to deposit null amount");

		melodity.transferFrom(msg.sender, address(this), _amount);
		poolInfo.rewardPool += _amount;

		if(poolInfo.rewardPool >= 1_000_000 ether) {
			poolInfo.exhausting = false;
			emit PoolRefilled(poolInfo.rewardPool);
		}

		emit RewardPoolIncreased(_amount);
	}

	/**
		Trigger the refresh of _eraAmount era infos

		@param _eraAmount Number of eras to refresh
	 */
	function refreshErasInfo(uint8 _eraAmount) public onlyOwner nonReentrant {
		prng.seedRotate();
		
		_triggerErasInfoRefresh(_eraAmount);
	}

	/**
		Update the reward scaling factor

		@notice The update factor is given as a percentage with high precision (18 decimal positions)
				Consider 100 ether = 100%

		@param _factor Percentage of the reward scaling factor
		@param _erasToRefresh Number of eras to refresh immediately starting from the next one
	 */
	function updateRewardScaleFactor(uint256 _factor, uint8 _erasToRefresh) public onlyOwner nonReentrant {
		prng.seedRotate();

		uint256 eraIndex = getCurrentEraIndex();
		EraInfo storage eraInfo = eraInfos[eraIndex];
		uint256 old = eraInfo.rewardScaleFactor;
		eraInfo.rewardScaleFactor = _factor;
		_triggerErasInfoRefresh(_erasToRefresh);
		emit RewardScalingFactorUpdate(old, eraInfo.rewardScaleFactor);
	}

	/**
		Update the era scaling factor

		@notice The update factor is given as a percentage with high precision (18 decimal positions)
				Consider 100 ether = 100%

		@param _factor Percentage of the era scaling factor
		@param _erasToRefresh Number of eras to refresh immediately starting from the next one
	 */
	function updateEraScaleFactor(uint256 _factor, uint8 _erasToRefresh) public onlyOwner nonReentrant {
		prng.seedRotate();

		uint256 eraIndex = getCurrentEraIndex();
		EraInfo storage eraInfo = eraInfos[eraIndex];
		uint256 old = eraInfo.eraScaleFactor;
		eraInfo.eraScaleFactor = _factor;
		_triggerErasInfoRefresh(_erasToRefresh);
		emit EraScalingFactorUpdate(old, eraInfo.eraScaleFactor);
	}
	
	/**
		Update the fee percentage applied to users withdrawing funds earlier

		@notice The update factor is given as a percentage with high precision (18 decimal positions)
				Consider 100 ether = 100%
		@notice The factor must be a value between feeInfo.minFeePercentage and feeInfo.maxFeePercentage

		@param _percent Percentage of the fee
	 */
	function updateEarlyWithdrawFeePercent(uint256 _percent) public onlyOwner nonReentrant {
		prng.seedRotate();
		
		require(_percent >= _MIN_FEE_PERCENTAGE, "Early withdraw fee too low");
		require(_percent <= _MAX_FEE_PERCENTAGE, "Early withdraw fee too high");

		uint256 old = feeInfo.feePercentage;
		feeInfo.feePercentage = _percent;
		emit EarlyWithdrawFeeUpdate(old, feeInfo.feePercentage);
	}

	/**
		Update the fee receiver (where all dao's fee are sent)

		@notice This address should always be the dao's address

		@param _dao Address of the fee receiver
	 */
	function updateFeeReceiverAddress(address _dao) public onlyOwner nonReentrant {
		prng.seedRotate();
		
		require(_dao != address(0), "Provided address is invalid");

		address old = feeInfo.feeReceiver;
		feeInfo.feeReceiver = _dao;
		emit FeeReceiverUpdate(old, feeInfo.feeReceiver);
	}

	/**
		Update the withdraw period that a deposit is considered to be early

		@notice The period must be a value between 1 and 7 days

		@param _period Number or days or hours of the fee period
		@param _isDay Whether the provided period is in hours or in days
	 */
	function updateWithdrawFeePeriod(uint256 _period, bool _isDay) public onlyOwner nonReentrant {
		prng.seedRotate();
		
		if(_isDay) {
			// days (max 7 days, min 1 day)
			require(_period <= 7, "Withdraw period too long");
			require(_period >= 1, "Withdraw period too short");
			uint256 old = feeInfo.withdrawFeePeriod;
			uint256 day = 1 days;
			feeInfo.withdrawFeePeriod = _period * day;
			emit WithdrawPeriodUpdate(old, feeInfo.withdrawFeePeriod);
		}
		else {
			// hours (max 7 days, min 1 day)
			require(_period <= 168, "Withdraw period too long");
			require(_period >= 24, "Withdraw period too short");
			uint256 old = feeInfo.withdrawFeePeriod;
			uint256 hour = 1 hours;
			feeInfo.withdrawFeePeriod = _period * hour;
			emit WithdrawPeriodUpdate(old, feeInfo.withdrawFeePeriod);
		}
	}

	/**
		Update the share of the fee that is sent to the dao

		@notice The update factor is given as a percentage with high precision (18 decimal positions)
				Consider 100 ether = 100%
		@notice The percentage must be a value between feeInfo.feeReceiverMinPercent and 
				100 ether - feeInfo.feeMaintainerMinPercent

		@param _percent Percentage of the fee to send to the dao
	 */
	function updateDaoFeePercentage(uint256 _percent) public onlyOwner nonReentrant {
		prng.seedRotate();
		
		require(_percent >= feeInfo.feeReceiverMinPercent, "Dao's fee share too low");
		require(_percent <= 100 ether - feeInfo.feeMaintainerMinPercent, "Dao's fee share too high");

		uint256 old = feeInfo.feeReceiverPercentage;
		feeInfo.feeReceiverPercentage = _percent;
		feeInfo.feeMaintainerPercentage = 100 ether - _percent;
		emit DaoFeeSharedUpdate(old, feeInfo.feeReceiverPercentage);
		emit MaintainerFeeSharedUpdate(100 ether - old, feeInfo.feeMaintainerPercentage);
	}

	/**
		Update the fee percentage applied to users withdrawing funds earlier

		@notice The update factor is given as a percentage with high precision (18 decimal positions)
				Consider 100 ether = 100%
		@notice The percentage must be a value between feeInfo.feeMaintainerMinPercent and 
				100 ether - feeInfo.feeReceiverMinPercent

		@param _percent Percentage of the fee to send to the maintainers
	 */
	function updateMaintainerFeePercentage(uint256 _percent) public onlyOwner nonReentrant {
		prng.seedRotate();
		
		require(_percent >= feeInfo.feeMaintainerMinPercent, "Maintainer's fee share too low");
		require(_percent <= 100 ether - feeInfo.feeReceiverMinPercent, "Maintainer's fee share too high");

		uint256 old = feeInfo.feeMaintainerPercentage;
		feeInfo.feeMaintainerPercentage = _percent;
		feeInfo.feeReceiverPercentage = 100 ether - _percent;
		emit MaintainerFeeSharedUpdate(old, feeInfo.feeMaintainerPercentage);
		emit DaoFeeSharedUpdate(100 ether - old, feeInfo.feeReceiverPercentage);
	}

	/**
		Pause the stacking pool
	 */
	function pause() public whenNotPaused nonReentrant onlyOwner {
		prng.seedRotate();
		
		_pause();
	}

	/**
		Resume the stacking pool
	 */
	function resume() public whenPaused nonReentrant onlyOwner {
		prng.seedRotate();
		
		_unpause();
	}

	/**
		Allow dismission of the stacking pool once it is exhausting.
		The pool must be paused in order to lock the users from depositing but allow them to withdraw their funds.
		The dismission call can be launched only once all the stacking receipt gets reconverted back to MELD.

		@notice As evil users may want to leave their funds in the stacking pool to exhaust the pool balance 
				(even if practically impossible). The DAO can set the reward scaling factor to 0 actually stopping
				any reward for newer eras.
	 */
	function dismissionWithdraw() public whenPaused nonReentrant onlyOwner {
		prng.seedRotate();
		
		require(!poolInfo.dismissed, "Pool already dismissed");
		require(poolInfo.exhausting, "Dismission enabled only once the stacking pool is exhausting");
		require(stackingReceipt.totalSupply() == 0, "Unable to dismit the stacking pool as there are still circulating receipt");

		address addr;
		uint256 index;
		// refund all stacking pandas to their original owners if still locked in the pool
		for(uint8 i; i < 100; i++) {
			// if the depositor address is not the null address then the NFT is deposited into the pool
			addr = depositorNFT[i];
			if(addr != address(0)) {
				// reset index to zero if needed
				index = 0;

				// if more than one nft was stacked search the array for the one with the given id
				if(stackedNFTs[addr].length > 1) {
					for(; index < stackedNFTs[addr].length; index++) {
						// if the NFT identifier match exit the loop
						if(stackedNFTs[addr][index].nftId == i) {
							break;
						}
					}

					// swap the nft position with the last one
					stackedNFTs[addr][index] = stackedNFTs[addr][stackedNFTs[addr].length - 1];
					index = stackedNFTs[addr].length - 1;
				}

				// refund the NFT and reduce the size of the array
				stackingPanda.safeTransferFrom(address(this), addr, stackedNFTs[addr][index].nftId);
				stackedNFTs[addr].pop();
			}
		}

		// send all the remaining funds in the reward pool to the DAO
		melodity.transfer(feeInfo.feeReceiver, melodity.balanceOf(address(this)));

		// update the value at the end allowing this method to be called again if any error occurrs
		// the nonReentrant modifier anyway avoids any reentrancy attack
		poolInfo.dismissed = true;

		emit PoolDismissed();
	}
}