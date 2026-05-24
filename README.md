# AW-Rocov

Clean, original implementation of a recovery-style Expert Advisor for
**MetaTrader 5 (MQL5)**. The EA does not generate entry signals on its own —
it manages an existing basket of positions and tries to bring it back to a
small profit target using three classical building blocks:

1. **Lock** — open an opposite-direction hedge to freeze the floating loss
   (requires a hedging account).
2. **Averaging grid** — add orders in the recovery direction with a
   configurable point step and lot multiplier.
3. **Partial Take Profit** — close pieces of profitable positions on the way
   to break-even, reducing exposure as price moves favorably.

> This is an independent implementation of a publicly described concept.
> It is **not** a clone, decompile, or derivative of any commercial product.

---

## Repository layout

```
AW-Rocov/
├── README.md
├── docs/
│   └── strategy.md                — algorithm and state machine details
└── MQL5/
    ├── Experts/
    │   └── AWRocov.mq5            — main EA (inputs + OnInit/OnTick)
    └── Include/AWRocov/
        ├── Logger.mqh             — leveled logger
        ├── TradeOps.mqh           — CTrade wrapper + normalization
        ├── BasketManager.mqh      — basket aggregation snapshot
        └── RecoveryEngine.mqh     — finite state machine
```

The `MQL5/` folder mirrors the MetaTrader 5 data folder structure, so you can
drop it directly into your terminal's `MQL5/` directory.

## Install

1. Open MetaTrader 5 → `File` → `Open Data Folder`.
2. Copy `MQL5/Experts/AWRocov.mq5` to `MQL5/Experts/`.
3. Copy the `MQL5/Include/AWRocov/` folder to `MQL5/Include/AWRocov/`.
4. In MetaEditor, open `AWRocov.mq5` and press `F7` (Compile).
5. Attach `AWRocov` to a chart.

## Inputs (defaults)

| Group        | Input                          | Default     | Meaning                                          |
| ------------ | ------------------------------ | ----------- | ------------------------------------------------ |
| Identity     | `InpMagic`                     | `20260524`  | Magic number used to filter own positions        |
| Identity     | `InpManageOnlyOwnOrders`       | `true`      | If `false`, the EA also picks up symbol orders   |
| Trigger      | `InpLossThresholdPct`          | `5.0`       | Floating loss as % of balance to engage          |
| Trigger      | `InpLossThresholdMoney`        | `0.0`       | Floating loss in account currency (0 = off)      |
| Lock         | `InpUseHedgeLock`              | `true`      | Open opposite hedge on engage                    |
| Lock         | `InpLockVolumeMultiplier`      | `1.0`       | Lock volume = `|net_volume| × multiplier`        |
| Averaging    | `InpAveragingStepPoints`       | `300`       | Distance between grid orders (points)            |
| Averaging    | `InpAveragingLotMultiplier`    | `1.5`       | Each next order = previous × multiplier          |
| Averaging    | `InpMaxAveragingOrders`        | `8`         | Hard cap on grid orders                          |
| Partial TP   | `InpPartialClosePct`           | `50.0`      | Percent of position to close per partial         |
| Partial TP   | `InpPartialCloseProfitPoints`  | `200`       | Per-position profit (points) to trigger partial  |
| Basket exit  | `InpBasketTPMoney`             | `10.0`      | Close-all profit threshold (account currency)    |
| Trade        | `InpDeviationPoints`           | `20`        | Slippage in points                               |
| Trade        | `InpLogLevel`                  | `LOG_INFO`  | DBG / INF / WRN / ERR                            |

## Status

This is **v0.10** — the minimal "Чистый AW" baseline:

- ✅ Lock + averaging grid + partial close + basket TP
- ✅ State machine with explicit transitions, fully derived from broker state
- ✅ Hedging-account detection (auto-disables lock on netting accounts with a warning)
- ❌ No GUI panel (status is shown via chart `Comment()`)
- ❌ No news / time / multi-symbol filters
- ❌ No initial entry signals — bring your own

## Disclaimer

Recovery / averaging strategies carry significant tail risk. Use only on a
demo account until you fully understand the parameter interactions.
This software is provided "as is", without warranty of any kind.
