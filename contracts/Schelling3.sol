pragma solidity 0.5.10;
pragma experimental ABIEncoderV2;
import "./SimpleToken.sol";
import "./Incentives.sol";
import "./lib/SharedStructs.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./lib/Random.sol";
import "./lib/Constants.sol";
import "openzeppelin-solidity/contracts/cryptography/MerkleProof.sol";

// WARNING IN development
// Must Vote price rounded to 2 decimals *100 and must be above 0
// e.g. if ethusd is 169.99 vote 16999
// invalid vote cannot be revealed and you will get penalty
// node == staker
// TODO Priority list
// nobody proposes, nobody disputes, extending dispute period
// staker wants to vote but cant because below minimum. how to handle? should he be penalized? how much waiting time?

// new algo
//give reward and penalty in state 1 not state 2. because someone may defect in state 2 and leave in next epoch state 1
//calculate penalty in state 1 and distribute reward in state 2
//state 2 divide reward to those who committed in state 1 and distribute. if they dont participate, too bad.
// newvariables. global rewardpool.
contract Schelling3 {
    using SafeMath for uint256;

    mapping (address => uint256) public nodeIds;
    mapping (uint256 => SharedStructs.Node) public nodes;
    //epoch->stakerid->commitment
    mapping (uint256 => mapping (uint256 => bytes32)) public commitments;
    //epoch->stakerid->assetid->vote
    mapping (uint256 => mapping (uint256 =>  mapping (uint256 => SharedStructs.Vote))) public votes;
    // epoch -> asset -> stakeWeight
    mapping (uint256 =>  mapping (uint256 => uint256)) public totalStakeRevealed;

    mapping (uint256 => SharedStructs.Block) public blocks;
    //epoch->assetid->voteValue->weight
    mapping (uint256 => mapping (uint256 =>  mapping (uint256 => uint256))) public voteWeights;
    //epoch->address->dispute->assetid
    mapping (uint256 => mapping (address => SharedStructs.Dispute)) public disputes;
    //epoch -> numProposedBlocks
    // mapping (uint256 => uint256) public numProposedBlocks;
    //epoch -> proposalNumber -> block
    mapping (uint256 => SharedStructs.Block[]) public proposedBlocks;
    address public schAddress;

    uint256 public numNodes = 0;
    uint256 public totalStake = 0;

    uint256 public EPOCH;
    uint256 public STATE;
    uint256 public rewardPool = 0;
    uint256 public stakeGettingReward = 0;

    // Constants public c = Constants(0, 1, 2, 3, 1, 10000, 99, 100, 1000, 5, 5, 99, 1, 1);
//
    constructor (address _schAddress) public {
        schAddress = _schAddress;
    }

    modifier checkEpoch (uint256 epoch) {
        require(epoch == getEpoch(), "incorrect epoch");
        _;
    }

    modifier checkState (uint256 state) {
        require(state == getState(), "incorrect state");
        _;
    }

    //for some reasom, getter for block doesnt return medians array. so using this for now
    function getBlock (uint256 epoch, uint256 proposalIndex) public view
    returns(uint256, uint256[] memory medians, uint256, uint256) {
        // uint256 proposerId;
        // uint256[] medians;
        // uint256 iteration;
        // uint256 biggestStake;
        Block memory _block;
        if (proposalIndex > 0) {
            _block = proposedBlocks[epoch][proposalIndex - 1];
        } else {
            _block = blocks[epoch];
        }
        medians = _block.medians;
        return(_block.proposerId, medians, _block.iteration, _block.biggestStake);
    }

    event Staked(uint256 nodeId, uint256 amount);

    // stake during commit state only
    // we check epoch during every transaction to avoid withholding and rebroadcasting attacks
    function stake (uint256 epoch, uint256 amount) public checkEpoch(epoch) checkState(Constants.commit()) {
        SimpleToken sch = SimpleToken(schAddress);
         //not allowed during reveal period
        require(getState() != Constants.reveal());
        require(amount >= Constants.minStake(), "staked amount is less than minimum stake required");
        require(sch.transferFrom(msg.sender, address(this), amount), "sch transfer failed");
        uint256 nodeId = nodeIds[msg.sender];
        if (nodeId == 0) {
            numNodes = numNodes.add(1);
            nodes[numNodes] = SharedStructs.Node(numNodes, amount, epoch, 0, 0, epoch.add(Constants.unstakeLockPeriod()), 0);
            nodeId = numNodes;
            nodeIds[msg.sender] = nodeId;
        } else {
            require(nodes[nodeId].stake > 0,
                    "adding stake is not possible after withdrawal/slash. Please use a new address");
            nodes[nodeId].stake = nodes[nodeId].stake.add(amount);
        }
        totalStake = totalStake.add(amount);
        emit Staked(nodeId, amount);
    }

    event Unstaked(uint256 nodeId);

    // staker must call unstake() and continue voting for Constants.WITHDRAW_LOCK_PERIOD
    //after which she can call withdraw() to finally Withdraw
    function unstake (uint256 epoch) public checkEpoch(epoch) {
        require(getState() != 1); //not allowed during reveal period
        uint256 nodeId = nodeIds[msg.sender];
        Node storage node = nodes[nodeId];
        require(node.id != 0);
        require(node.stake > 0, "Nonpositive stake");
        require(node.unstakeAfter <= epoch && node.unstakeAfter != 0);
        node.unstakeAfter = 0;
        node.withdrawAfter = epoch.add(Constants.withdrawLockPeriod());
        emit Unstaked(nodeId);
    }

    event Withdrew(uint256 nodeId, uint256 amount);

    function withdraw (uint256 epoch) public checkEpoch(epoch) checkState(Constants.commit()) {
        uint256 nodeId = nodeIds[msg.sender];
        SharedStructs.Node storage node = nodes[nodeId];
        require(node.id != 0, "node doesnt exist");
        require(node.epochLastRevealed == epoch.sub(1), "Didnt reveal in last epoch");
        require(node.unstakeAfter == 0, "Did not unstake");
        require((node.withdrawAfter <= epoch) && node.withdrawAfter != 0, "Withdraw epoch not reached");
        require(commitments[epoch][nodeId] == 0x0, "already commited this epoch. Cant withdraw");
        givePenalties(node, epoch);
        require(node.stake > 0, "Nonpositive Stake");
        SimpleToken sch = SimpleToken(schAddress);
        totalStake = totalStake.sub(nodes[nodeId].stake);
        nodes[nodeId].stake = 0;
        emit Withdrew(nodeId, nodes[nodeId].stake);
        require(sch.transfer(msg.sender, nodes[nodeId].stake));
    }

    event Committed(uint256 epoch, uint256 nodeId, bytes32 commitment);
    //
    event Y(uint256 y);
    //
    // // what was the eth/usd rate at the beginning of this epoch?

    function commit (uint256 epoch, bytes32 commitment) public checkEpoch(epoch) checkState(Constants.commit()) {
        uint256 nodeId = nodeIds[msg.sender];
        require(commitments[epoch][nodeId] == 0x0, "already commited");
        SharedStructs.Node storage thisStaker = nodes[nodeId];
        if (blocks[epoch - 1].proposerId == 0 && proposedBlocks[epoch - 1].length > 0) {
            for (uint8 i=0; i < proposedBlocks[epoch - 1].length; i++) {
                if (proposedBlocks[epoch - 1][i].valid) {
                    blocks[epoch - 1] = proposedBlocks[epoch - 1][i];
                    giveBlockReward(blocks[epoch - 1].proposerId);
                }
            }
        }
        uint256 y = givePenalties(thisStaker, epoch);
        emit Y(y);
        if (thisStaker.stake >= Constants.minStake()) {
            commitments[epoch][nodeId] = commitment;
            thisStaker.epochLastCommitted = epoch;
            emit Committed(epoch, nodeId, commitment);
        }
    }

    event Revealed(uint256 epoch, uint256 nodeId, uint256 value, uint256 stake);

    function reveal (uint256 epoch, bytes32 root, uint256[] memory values,
                    bytes32[][] memory proofs, bytes32 secret, address stakerAddress)
    public
    checkEpoch(epoch) {
        uint256 thisNodeId = nodeIds[stakerAddress];
        require(thisNodeId > 0, "SharedStructs.Node does not exist");
        SharedStructs.Node storage thisStaker = nodes[thisNodeId];
        require(commitments[epoch][thisNodeId] != 0x0, "not commited or already revealed");
        // require(value > 0, "voted non positive value");
        require(keccak256(abi.encodePacked(epoch, root, secret)) == commitments[epoch][thisNodeId],
                "incorrect secret/value");
        //if revealing self
        if (msg.sender == stakerAddress) {

            require(getState() == Constants.reveal(), "Not reveal state");
            require(thisStaker.stake > 0, "nonpositive stake");
            giveRewards(thisStaker, epoch);
            for (uint256 i = 0; i < values.length; i++) {
                require(MerkleProof.verify(proofs[i], root, keccak256(abi.encodePacked(values[i]))));

                votes[epoch][thisNodeId][i] = SharedStructs.Vote(values[i], thisStaker.stake);
                voteWeights[epoch][i][values[i]] = voteWeights[epoch][i][values[i]].add(thisStaker.stake);
                totalStakeRevealed[epoch][i] = totalStakeRevealed[epoch][i].add(thisStaker.stake);

            }


            commitments[epoch][thisNodeId] = 0x0;
            thisStaker.epochLastRevealed = epoch;
            // emit Revealed(epoch, thisNodeId, value, thisStaker.stake);
        } else {
            //bounty hunter revealing someone else's secret in commit state
            require(getState() == Constants.commit(), "Not commit state");
            commitments[epoch][thisNodeId] = 0x0;
            slash(thisNodeId, msg.sender);
        }
    }

    function isElectedProposer(uint256 iteration, uint256 biggestStakerId, uint256 nodeId) public view returns(bool) {
        // rand = 0 -> totalStake-1
        //add +1 since prng returns 0 to max-1 and node start from 1
        if ((Random.prng(10, numNodes, keccak256(abi.encode(iteration))).add(1)) != nodeId) return(false);
        bytes32 randHash = Random.prngHash(10, keccak256(abi.encode(nodeId, iteration)));
        uint256 rand = uint256(randHash).mod(2**32);
        uint256 biggestStake = nodes[biggestStakerId].stake;
        if (rand.mul(biggestStake) > nodes[nodeId].stake.mul(2**32)) return(false);
        return(true);
    }

    event Proposed(uint256 epoch,
                    uint256 nodeId,
                    uint256[] medians,
                    uint256 iteration,
                    uint256 biggestStakerId);

    // elected proposer proposes block. we use a probabilistic method to elect stakers weighted by stake
    // protocol works like this. select a staker pseudorandomly (not weighted by anything)
    // (todo what if it is below min stake)
    // that staker then tosses a biased coin. bias = hisStake/biggestStake. if its heads, he can propose block
    // end of iteration. try next iteration
    // note that only one staker or no stakers selected in each iteration.
    // stakers elected in higher iterations can also propose hoping that
    // stakers with lower iteration do not propose for some reason
    function propose (uint256 epoch,
                    uint256[] memory medians,
                    uint256 iteration,
                    uint256 biggestStakerId) public checkEpoch(epoch) checkState(Constants.propose()) {
        uint256 proposerId = nodeIds[msg.sender];
        // SimpleToken sch = SimpleToken(schAddress);
        require(isElectedProposer(iteration, biggestStakerId, proposerId), "not elected");
        require(nodes[proposerId].stake >= Constants.minStake(), "stake below minimum stake");

        // check if someone already proposed
        // if (blocks[epoch].proposerId != 0) {
        //     if (blocks[epoch].proposerId == proposerId) {
        //         revert("Already Proposed");
        //     }
        //     // if (nodes[biggestStakerId].stake == blocks[epoch].biggestStake &&
        //     //     proposedBlocks[epoch].length >= Constants.maxAltBlocks()) {
        //     //
        //     //     require(proposedBlocks[epoch][4].iteration > iteration,
        //     //             "iteration not smaller than last elected staker");
        //     // } else
        //     if (nodes[biggestStakerId].stake < blocks[epoch].biggestStake) {
        //         revert("biggest stakers stake not bigger than as proposed by existing elected staker ");
        //     }
        // }
        // blocks[epoch]
        uint256 pushAt = insertAppropriately(epoch, SharedStructs.Block(proposerId,
                                        medians,
                                        iteration,
                                        nodes[biggestStakerId].stake,
                                        true));
        emit Y(pushAt);
        // mint and give block reward
        // if (Constants.blockReward() > 0) {
        //     nodes[proposerId].stake = nodes[proposerId].stake.add(Constants.blockReward());
        //     totalStake = totalStake.add(Constants.blockReward());
        //     require(sch.mint(address(this), Constants.blockReward()));
        // }
        emit Proposed(epoch, proposerId, medians, iteration, biggestStakerId);
    }

    //anyone can give sorted votes in batches in dispute state
    function giveSorted (uint256 epoch, uint256 assetId, uint256[] memory sorted) public
    checkEpoch(epoch) checkState(Constants.dispute()) {
        uint256 medianWeight = totalStakeRevealed[epoch][assetId].div(2);
        //accWeight = accumulatedWeight
        uint256 accWeight = disputes[epoch][msg.sender].accWeight;
        uint256 lastVisited = disputes[epoch][msg.sender].lastVisited;
        if (disputes[epoch][msg.sender].accWeight == 0) {
            disputes[epoch][msg.sender].assetId = assetId;
        } else {
            require(disputes[epoch][msg.sender].assetId == assetId, "AssetId not matching");
        }
        for (uint256 i = 0; i < sorted.length; i++) {
            require(sorted[i] > lastVisited, "sorted[i] is not greater than lastVisited");
            lastVisited = sorted[i];
            accWeight = accWeight.add(voteWeights[epoch][assetId][sorted[i]]);
            //set  median, if conditions meet
            if (disputes[epoch][msg.sender].median == 0 && accWeight > medianWeight) {
                disputes[epoch][msg.sender].median = sorted[i];
            }
            //TODO verify how much gas required for below operations and update this value
            if (gasleft() < 10000) break;
        }
        disputes[epoch][msg.sender].lastVisited = lastVisited;
        disputes[epoch][msg.sender].accWeight = accWeight;
    }

    // //todo test
    // //if any mistake made during giveSorted, resetDispute and start again
    function resetDispute (uint256 epoch) public checkEpoch(epoch) checkState(Constants.dispute()) {
        disputes[epoch][msg.sender] = SharedStructs.Dispute(0, 0, 0, 0);
    }

    function finalizeDispute (uint256 epoch, uint256 blockId)
    public checkEpoch(epoch) checkState(Constants.dispute()) {
        uint256 assetId = disputes[epoch][msg.sender].assetId;
        require(disputes[epoch][msg.sender].accWeight == totalStakeRevealed[epoch][assetId]);
        uint256 median = disputes[epoch][msg.sender].median;
        // uint256 bountyHunterId = nodeIds[msg.sender];
        uint256 proposerId = proposedBlocks[epoch][blockId].proposerId;

        require(median > 0);
        if (proposedBlocks[epoch][blockId].medians[assetId] != median) {
            // blocks[epoch] = SharedStructs.Block(bountyHunterId, median,
                                    // 0, 0);
            // emit Proposed(epoch, proposerId, median, 0, 0);
            proposedBlocks[epoch][blockId].valid = false;
            slash(proposerId, msg.sender);
        } else {
            revert("Proposed Alternate block is identical to proposed block");
        }
    }

    // WARNING TODO FOR TESTING ONLY. REMOVE IN PROD
    function setEpoch (uint256 epoch) public { EPOCH = epoch;}

    function setState (uint256 state) public { STATE = state;}

    // dummy function to forcibly increase block number in ganache
    function dum () public {true;}
    // END TESTING FUNCTIONS

    function getEpoch () public view returns(uint256) {
        return(EPOCH);
        return(block.number.div(Constants.epochLength()));
    }

    function getState () public view returns(uint256) {
        return (STATE);
        uint256 state = (block.number.div(Constants.epochLength()/Constants.numStates()));
        return (state.mod(Constants.numStates()));
    }

    //return price from last epoch
    function getPrice(uint256 assetId) public view returns (uint256) {
        uint256 epoch = getEpoch();
        return(blocks[epoch-1].medians[assetId]);
    }

    //proposedblocks[epoch] = [SharedStructs.Block.iteration]

    function insertAppropriately(uint256 epoch, SharedStructs.Block memory _block) internal returns(uint256) {
        // uint256 iteration = _block.iteration;
        if (proposedBlocks[epoch].length == 0) {
            proposedBlocks[epoch].push(_block);
            return(0);
        }
        // SharedStructs.Block[] memory temp = proposedBlocks[epoch];
        // delete (proposedBlocks[epoch]);
        // bool pushed = false;
        // bool empty = true;
        uint256 pushAt = proposedBlocks[epoch].length;
        for (uint256 i = 0; i < proposedBlocks[epoch].length; i++) {
            if (proposedBlocks[epoch][i].biggestStake < _block.biggestStake) {
                pushAt = i;
                break;
            }
            if (proposedBlocks[epoch][i].iteration > _block.iteration) {
                pushAt = i;
                break;
            }
        }

        proposedBlocks[epoch].push(_block);
        for (uint256 j = proposedBlocks[epoch].length - 1; j > (pushAt); j--) {
            proposedBlocks[epoch][j] = proposedBlocks[epoch][j - 1];
        }
        // if (pushAt < proposedBlocks[epoch].length) {

        proposedBlocks[epoch][pushAt] = _block;
        // }
        // if (pushed == false && temp.length < Constants.maxAltBlocks()) {
        //     proposedBlocks[epoch].push(_block);
        // }
        if (proposedBlocks[epoch].length > Constants.maxAltBlocks()) {
            delete (proposedBlocks[epoch][proposedBlocks[epoch].length - 1]);
        }
        return(pushAt);
    }

    function slash (uint256 id, address bountyHunter) internal {
        SimpleToken sch = SimpleToken(schAddress);
        uint256 halfStake = nodes[id].stake.div(2);
        nodes[id].stake = 0;
        if (halfStake > 1) {
            totalStake = totalStake.sub(halfStake);
            require(sch.transfer(bountyHunter, halfStake), "failed to transfer bounty");
        }
    }
    // function stakeTransfer(uint256 fromId, address to, uint256 amount) internal{
    //     // uint256 fromId = nodeIds[from];
    //     require(fromId!=0);
    //     require(nodes[fromId].stake >= amount);
    //     uint256 toId = nodeIds[to];
    //     nodes[fromId].stake = nodes[fromId].stake - amount;
    //     if (toId == 0) {
    //         numNodes = numNodes + 1;
    //         nodes[numNodes] = Node(numNodes, amount, 0, 0, 0);
    //         nodeIds[to] = numNodes;
    //     } else {
    //         nodes[toId].stake = nodes[toId].stake + amount;
    //     }
    // }

}
