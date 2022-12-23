// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.9;

import "./interfaces/IPoolFactory.sol";
import "./interfaces/IPoolMaster.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./libraries/Decimal.sol";
import "./BaseStrategy.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Strategy is BaseStrategy {
  using SafeERC20 for IERC20;
  using SafeERC20 for IPoolMaster;
  using Address for address;
  using SafeMath for uint256;
  using Decimal for uint256;

  address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  uint256 private constant DEPOSIT_THRESHOLD = 10;

  IPoolFactory public poolFactory;

  address public cpool;

  IPoolMaster[] public masters;

  address public router;

  constructor(
    address _vault,
    address _factory,
    address _router
  ) BaseStrategy(_vault) {
    require(_factory != address(0), "CBZ");

    poolFactory = IPoolFactory(_factory);
    // Check if Currency want is supported.
    require(poolFactory.currencyAllowed(address(want)), "CNS");

    cpool = poolFactory.cpool();
    router = _router;
  }

  function name() external view override returns (string memory) {
    return "StrategyClearPoolUSDC";
  }

  function estimatedTotalAssets() public view override returns (uint256) {
    uint256 total = _balance(want);
    uint256 length = masters.length;
    IPoolMaster[] memory _masters = masters;

    for (uint256 i; i < length; i++) {
      IPoolMaster master = _masters[i];
      uint256 rate = master.getCurrentExchangeRate();
      uint256 bal = master.balanceOf(address(this));
      uint256 wantAmount = bal.mulDecimal(rate);

      total = total.add(wantAmount);
    }

    return total;
  }

  function prepareReturn(uint256 _debtOutstanding)
    internal
    override
    returns (
      uint256 _profit,
      uint256 _loss,
      uint256 _debtPayment
    )
  {
    // TODO: Do stuff here to free up any returns back into `want`
    // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
    // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

    // Get total debt, total assets (want+idle)
    uint256 totalDebt = vault.strategies(address(this)).totalDebt;
    uint256 totalAssets = estimatedTotalAssets();

    _profit = totalAssets > totalDebt ? totalAssets - totalDebt : 0; // no underflow

    // To withdraw = profit from lending + _debtOutstanding
    uint256 toFree = _debtOutstanding.add(_profit);

    uint256 freed;
    (freed, _loss) = liquidatePosition(toFree);

    _debtPayment = _debtOutstanding >= freed ? freed : _debtOutstanding; // min

    // net out PnL
    if (_profit > _loss) {
        _profit = _profit - _loss; // no underflow
        _loss = 0;
    } else {
        _loss = _loss - _profit; // no underflow
        _profit = 0;
    }
  }

  function adjustPosition(uint256 _debtOutstanding) internal override {
    // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
    // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
  }

  function liquidatePosition(uint256 _amountNeeded)
    internal
    override
    returns (uint256 _liquidatedAmount, uint256 _loss)
  {
    // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
    // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
    // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

    uint256 wantBal = _balance(want);

    if (_amountNeeded > wantBal) {
      uint256 toWithdraw = _amountNeeded - wantBal; // no underflow
      uint256 withdrawn = _redeem(toWithdraw);
      if (withdrawn < toWithdraw) {
        _loss = toWithdraw - withdrawn; // no underflow
      }
    }

    _liquidatedAmount = _amountNeeded.sub(_loss);
  }

  function liquidateAllPositions() internal override returns (uint256 amountFreed) {
    _redeem(uint256(int(-1)));
    amountFreed = _balance(want);
  }

  // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

  function prepareMigration(address _newStrategy) internal override {
    for (uint256 i = 0; i < masters.length; i++) {
      IPoolMaster master = masters[i];
      uint256 bal = master.balanceOf(address(this));
      if (bal != 0)
        master.safeTransfer(_newStrategy, bal);
    }
  }

  // Override this to add all tokens/tokenized positions this contract manages
  // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
  // NOTE: Do *not* include `want`, already included in `sweep` below
  //
  // Example:
  //
  //    function protectedTokens() internal override view returns (address[] memory) {
  //      address[] memory protected = new address[](3);
  //      protected[0] = tokenA;
  //      protected[1] = tokenB;
  //      protected[2] = tokenC;
  //      return protected;
  //    }
  function protectedTokens()
    internal
    view
    override
    returns (address[] memory)
  {
    IPoolMaster[] memory _masters = masters;
    uint256 i;
    uint256 length = _masters.length;
    address[] memory protected = new address[](2 + length);

    for (; i < length; i++) {
        protected[i] = address(_masters[i]);
    }
    protected[i] = address(this);
    protected[1 + i] = cpool;

    return protected;
  }

  /**
   * @notice
   *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
   *  to `want` (using the native decimal characteristics of `want`).
   * @dev
   *  Care must be taken when working with decimals to assure that the conversion
   *  is compatible. As an example:
   *
   *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
   *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
   *
   * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
   * @return The amount in `want` of `_amtInEth` converted to `want`
   **/
  function ethToWant(uint256 _amtInWei)
    public
    view
    virtual
    override
    returns (uint256)
  {
    if (_amtInWei == 0) {
      return 0;
    }
    address _wantAddress = address(want);
    if (_wantAddress == WETH) {
      return _amtInWei;
    }
    address[] memory path = _getPath(WETH, _wantAddress);
    uint256[] memory amounts = IUniswapV2Router(router).getAmountsOut(_amtInWei, path);
    return amounts[amounts.length - 1];
  }

  function provide(IPoolMaster[] memory _pools, uint256[] memory _amounts) external onlyVaultManagers {
    uint256 length = _pools.length;
    require(0 != length && length == _amounts.length, "LNM");

    for (uint256 i; i < length; i++)
      _provide(_pools[i], _amounts[i]);
  }

  function redeem(IPoolMaster[] memory _pools, uint256[] memory _amounts) external onlyVaultManagers {
    uint256 length = _pools.length;
    require(0 != length && length == _amounts.length, "LNM");

    for (uint256 i; i < length; i++)
      _redeem(_pools[i], _amounts[i]);
  }

  function _addPool(IPoolMaster _pool)
    internal
    returns (bool)
  {
    uint256 length = masters.length;
    IPoolMaster[] memory _masters = masters;

    for (uint256 i; i < length; i++) {
      if (_pool == _masters[i]) return false;
    }

    masters.push(_pool);
    return true;
  }

  function _removePool(IPoolMaster _pool)
    internal
    returns (bool)
  {
    uint256 length = masters.length;
    IPoolMaster[] memory _masters = masters;

    for (uint256 i; i < length; i++) {
      if (_pool == _masters[i]) {
        masters[i] = _masters[length - 1];
        masters.pop();
        return true;
      }
    }

    return false;
  }

  function _provide(IPoolMaster _pool, uint256 _wantAmount) internal {
    require(
      poolFactory.isPool(address(_pool)),
      "NAP"
    );
    IPoolMaster.State state = _pool.state();
    require(
      state == IPoolMaster.State.Active ||
      state == IPoolMaster.State.Warning ||
      state == IPoolMaster.State.ProvisionalDefault,
      "PIA"
    );
    uint256 wantBal = _balance(want);

    if (_wantAmount > wantBal) _wantAmount = wantBal;

    if (_wantAmount <= DEPOSIT_THRESHOLD) return;

    _pool.provide(_wantAmount);
    _addPool(_pool);
  }

  function _redeem(uint256 _tokensToWithdraw) internal returns (uint256 wantRedeemed) {
    uint256 length = masters.length;
    IPoolMaster[] memory _masters = masters;

    for (uint256 i; i < length; i++) {
      uint256 tokensWithdrawed = _redeem(_masters[i], _tokensToWithdraw);
      wantRedeemed = wantRedeemed.add(tokensWithdrawed);

      if (tokensWithdrawed >= _tokensToWithdraw)
        break;
        
      _tokensToWithdraw = _tokensToWithdraw - tokensWithdrawed; // no underflow
    }
  }

  function _redeem(IPoolMaster _pool, uint256 _tokensToWithdraw)
    internal
    returns (uint256 wantRedeemed)
  {
    require(
      poolFactory.isPool(address(_pool)),
      "NAP"
    );
    uint256 wantAvailable = _availabeFromPool(_pool);

    if (_tokensToWithdraw >= wantAvailable) {
      _removePool(_pool);
      _tokensToWithdraw = wantAvailable;
    }

    _pool.redeemCurrency(_tokensToWithdraw);
    return _tokensToWithdraw;
  }

  function _availabeFromPool(IPoolMaster _pool)
    internal
    returns (uint256 wantAvailable)
  {
    uint256 rate = _pool.getCurrentExchangeRate();
    uint256 bal = _pool.balanceOf(address(this));
    uint256 wantAmount = bal.mulDecimal(rate);
    uint256 poolAmount = _pool.availableToWithdraw();

    wantAvailable = wantAmount > poolAmount ? poolAmount : wantAmount;
  }

  function _getPath(address assetIn, address assetOut)
    internal
    view
    returns (address[] memory path)
  {
    if (assetIn == WETH || assetOut == WETH) {
      path = new address[](2);
      path[0] = assetIn;
      path[1] = assetOut;
    } else {
      path = new address[](3);
      path[0] = assetIn;
      path[1] = WETH;
      path[2] = assetOut;
    }
  }

  function _balance(IERC20 token) internal view returns (uint256) {
    return token.balanceOf(address(this));
  }
}
