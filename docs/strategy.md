# AW-Rocov v0.10 — Strategy specification

This document describes the algorithm implemented in `AWRocov.mq5`. It is
the source of truth for the state machine, triggers, and exit rules.

## 1. Scope

AW-Rocov is a **recovery-only** Expert Advisor:

- It does **not** produce entry signals.
- It picks up positions that already exist on the chart symbol (filtered by
  magic number when `InpManageOnlyOwnOrders = true`) and treats them as a
  single basket.
- Its job is to bring the basket from a floating loss back to a small,
  configurable profit target.

## 2. Concepts

- **Basket** — the set of positions matching `(symbol, magic-or-any)`. The
  basket is re-snapshot at the beginning of every tick from broker state, so
  the EA is stateless w.r.t. broker truth.
- **Net direction** — `+1` if `BUY_volume > SELL_volume`, `-1` if
  `SELL_volume > BUY_volume`, `0` if balanced.
- **Recovery direction** — captured at trigger time and pinned for the
  duration of the recovery cycle. It equals the net direction at that
  moment. Subsequent lock/averaging decisions are made relative to this.

## 3. State machine

```
            +--------+
            |  IDLE  |
            +---+----+
                |  loss >= threshold  (and basket not balanced)
                v
           +---------+
           | LOCKING |
           +----+----+
                | lock opened (or skipped on netting)
                v
        +---------------+    partial profit found
        |   AVERAGING   | -------------------------+
        +---+-------+---+                          |
            |       ^                              v
            |       |                  +--------------------+
            |       +----------------- |  PARTIAL_CLOSING   |
            |                          +--------------------+
            |  basket PnL >= TP
            v
       +-----------+
       | CLOSING_  |
       |   ALL     |
       +-----+-----+
             | all closed
             v
          +-----+
          | IDLE|
          +-----+
```

### Transitions

| From              | Condition                                             | To                |
| ----------------- | ----------------------------------------------------- | ----------------- |
| `IDLE`            | `basket non-empty AND loss >= threshold AND dir != 0` | `LOCKING`         |
| `LOCKING`         | `use_hedge_lock=false OR account is netting`          | `AVERAGING` (skip)|
| `LOCKING`         | hedge order successfully opened                       | `AVERAGING`       |
| `AVERAGING`       | `floating_pnl >= basket_tp_money`                     | `CLOSING_ALL`     |
| `AVERAGING`       | any position profit >= partial threshold              | `PARTIAL_CLOSING` |
| `AVERAGING`       | price moved `step` against last entry & cap not hit    | (stay) opens avg  |
| `PARTIAL_CLOSING` | partial close attempted (success or fail)             | `AVERAGING`       |
| `CLOSING_ALL`     | all close attempts done                               | `IDLE`            |

## 4. Trigger

The trigger fires when **either** condition holds:

- `loss >= balance × InpLossThresholdPct / 100`, with `InpLossThresholdPct > 0`
- `loss >= InpLossThresholdMoney`, with `InpLossThresholdMoney > 0`

`loss` is `-floating_pnl` (positive when in red), summed across the basket
including swap.

## 5. Lock

If `InpUseHedgeLock = true` and the account is in
`ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`, an opposite-direction order is opened
with volume `|net_volume| × InpLockVolumeMultiplier`. On netting accounts
the lock is silently skipped (with a warning log) because hedging is not
available.

## 6. Averaging

A new averaging order is added when **all** of the following hold:

- `m_avg_count < InpMaxAveragingOrders`
- price has moved at least `InpAveragingStepPoints` from `m_last_avg_price`
  in the direction adverse to the recovery (price down for long-dir, price
  up for short-dir)

The volume of the new order is `m_last_avg_volume × InpAveragingLotMultiplier`,
normalized to the symbol lot step / min / max. After a successful entry, the
"last" trackers are updated and the averaging counter is incremented.

## 7. Partial close

For every basket position the EA computes:

- `profit_points(BUY)  = (Bid - open) / point`
- `profit_points(SELL) = (open - Ask) / point`

If any position has `profit_points >= InpPartialCloseProfitPoints`, the
state machine transitions to `PARTIAL_CLOSING` and closes
`InpPartialClosePct%` of the **first** such position via
`CTrade::PositionClosePartial`. One partial close per tick is performed to
keep order activity moderate, then control returns to `AVERAGING`.

## 8. Basket exit

Whenever `floating_pnl >= InpBasketTPMoney`, the EA transitions to
`CLOSING_ALL`, iterates over the snapshot ticket list and closes each
position. Recovery context (direction, counters) is reset and the state
returns to `IDLE`. If any close fails, the next tick will pick the
remaining positions back up either as a new basket or a new recovery cycle.

## 9. Statelessness on broker truth

The engine never assumes an order it intends to open actually exists. Every
tick starts with `BasketManager::Refresh()` re-reading positions from the
terminal. The only engine-local state that survives ticks is:

- `m_state` (state machine state)
- `m_recovery_dir`
- `m_last_avg_price`, `m_last_avg_volume`, `m_avg_count`
- `m_lock_done`

If the EA is restarted mid-cycle, it will restart in `IDLE` and re-engage as
soon as the trigger condition is met again. This is intentional for v0.10:
state persistence across restarts is left to a later version.

## 10. Out of scope for v0.10

- Trend / volatility / news / time-of-day filters
- Multi-symbol baskets
- Initial entry signal generation
- Persistent engine state across restarts
- Graphical control panel
