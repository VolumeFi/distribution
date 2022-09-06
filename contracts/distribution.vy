# @version 0.3.6

rewards_token: public(address)
staking_token: public(address)
period_finish: public(uint256)
reward_rate: public(uint256)
rewards_duration: public(uint256)
last_update_time: public(uint256)
reward_per_token_stored: public(uint256)
rewards_distribution: public(address)
owner: public(address)
user_reward_per_token_paid: public(HashMap[address, uint256])
rewards: public(HashMap[address, uint256])

totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])

interface ERC20:
    def balanceOf(_account: address) -> uint256: view

event Staked:
    user: indexed(address)
    amount: uint256

event Withdrawn:
    user: indexed(address)
    amount: uint256

event RewardPaid:
    user: indexed(address)
    reward: uint256

event RewardAdded:
    reward: uint256

event RewardsDistributionUpdated:
    new_rewards_distribution: address

event Recovered:
    token: address
    amount: uint256

event RewardsDurationUpdated:
    new_duration: uint256

@external
def __init__(_owner: address, _rewards_distribution: address, _rewards_token: address, _staking_token: address, _rewards_duration: uint256, _uniswapRemove: address):
    self.owner = _owner
    self.rewards_token = _rewards_token
    self.staking_token = _staking_token
    self.rewards_distribution = _rewards_distribution
    self.rewards_duration = _rewards_duration

# VIEW FUNCTIONS
@internal
@view
def _last_time_reward_applicable() -> uint256:
    _period_finish: uint256 = self.period_finish
    if block.timestamp > _period_finish:
        return _period_finish
    else:
        return block.timestamp

@external
@view
def last_time_reward_applicable() -> uint256:
    return self._last_time_reward_applicable()

@internal
@view
def _reward_per_token() -> uint256:
    _total_supply: uint256 = self.totalSupply
    if _total_supply == 0:
        return self.reward_per_token_stored
    return self.reward_per_token_stored + unsafe_div((self._last_time_reward_applicable() - self.last_update_time) * self.reward_rate * 10 ** 18, _total_supply)

@external
@view
def reward_per_token() -> uint256:
    return self._reward_per_token()

@internal
@view
def _earned(account: address) -> uint256:
    return unsafe_div((self.balanceOf[account] * (self._reward_per_token() - self.user_reward_per_token_paid[account])), 10 ** 18) + self.rewards[account]

@external
@view
def earned(account: address) -> uint256:
    return self._earned(account)

@external
@view
def get_reward_for_duration() -> uint256:
    return self.reward_rate * self.rewards_duration

@internal
def _safe_transfer_from(_token: address, _from: address, _to: address, _value: uint256):
    _response: Bytes[32] = raw_call(
        _token,
        _abi_encode(_from, _to, _value, method_id=method_id("transferFrom(address,address,uint256)")),
        max_outsize=32
    )  # dev: failed transferFrom
    if len(_response) > 0:
        assert convert(_response, bool), "TransferFrom failed"  # dev: failed transferFrom

@internal
def _update_reward(account: address):
    self.reward_per_token_stored = self._reward_per_token()
    self.last_update_time = self._last_time_reward_applicable()
    if account != ZERO_ADDRESS:
        self.rewards[account] = self._earned(account)
        self.user_reward_per_token_paid[account] = self.reward_per_token_stored

# User functions
@external
@nonreentrant('lock')
def stake(amount: uint256):
    assert amount > 0, "Cannot stake 0"
    self._update_reward(msg.sender)
    self.totalSupply += amount
    self.balanceOf[msg.sender] = unsafe_add(self.balanceOf[msg.sender], amount)
    self._safe_transfer_from(self.staking_token, msg.sender, self, amount)
    log Staked(msg.sender, amount)

@internal
def _safe_transfer(_token: address, _to: address, _value: uint256):
    _response: Bytes[32] = raw_call(
        _token,
        _abi_encode(_to, _value, method_id=method_id("transfer(address,uint256)")),
        max_outsize=32
    )  # dev: failed transfer
    if len(_response) > 0:
        assert convert(_response, bool), "Transfer failed"  # dev: failed transfer

@internal
def _withdraw(amount: uint256):
    assert amount > 0, "Cannot withdraw 0"
    assert block.timestamp >= self.period_finish, "Not finished yet"
    self._update_reward(msg.sender)
    self.totalSupply = unsafe_sub(self.totalSupply, amount)
    self.balanceOf[msg.sender] -= amount
    self._safe_transfer(self.staking_token, msg.sender, amount)
    log Withdrawn(msg.sender, amount)

@external
@nonreentrant('lock')
def withdraw(amount: uint256):
    self._withdraw(amount)

@internal
def _get_reward(sender: address):
    self._update_reward(sender)
    reward: uint256 = self.rewards[sender]
    if reward > 0:
        self.rewards[sender] = 0
        self._safe_transfer(self.rewards_token, sender, reward)
        log RewardPaid(sender, reward)

@external
@nonreentrant('lock')
def get_reward():
    self._get_reward(msg.sender)

@external
@nonreentrant('lock')
def exit():
    self._withdraw(self.balanceOf[msg.sender])
    self._get_reward(msg.sender)

# Restricted Functions
@external
def notify_reward_amount(reward: uint256):
    assert msg.sender == self.rewards_distribution, "Not RewardsDistribution"
    self._update_reward(ZERO_ADDRESS)
    _period_finish: uint256 = self.period_finish
    _rewards_duration: uint256 = self.rewards_duration
    if block.timestamp >= _period_finish:
        self.reward_rate = reward / _rewards_duration
    else:
        self.reward_rate = (reward + (_period_finish - block.timestamp) * self.reward_rate) / _rewards_duration
    
    _balance: uint256 = ERC20(self.rewards_token).balanceOf(self)
    assert self.reward_rate <= _balance / _rewards_duration, "Reward too high"
    self.last_update_time = block.timestamp
    self.period_finish = block.timestamp + _rewards_duration
    log RewardAdded(reward)

@external
def update_rewards_distribution(new_rewards_distribution: address):
    _rewards_distribution: address = self.rewards_distribution
    assert msg.sender == _rewards_distribution, "Not RewardsDistribution"
    assert _rewards_distribution != new_rewards_distribution, "Same address"
    self.rewards_distribution = new_rewards_distribution
    log RewardsDistributionUpdated(new_rewards_distribution)

@external
def recover_erc20(token: address, amount: uint256):
    _owner: address = self.owner
    assert msg.sender == _owner, "Not owner"
    assert token != self.staking_token, "Cannot withdraw staking token"
    if token == ZERO_ADDRESS:
        send(msg.sender, amount)
    else:
        self._safe_transfer(token, _owner, amount)
    log Recovered(token, amount)

@external
def set_rewards_duration(_rewards_duration: uint256):
    assert msg.sender == self.owner, "Not owner"
    assert block.timestamp > self.period_finish, "Not finished yet"
    self.rewards_duration = _rewards_duration
    log RewardsDurationUpdated(_rewards_duration)
