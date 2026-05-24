//+------------------------------------------------------------------+
//|                                                       AWRocov.mq5 |
//|                                AW-Rocov: clean recovery EA (MT5) |
//|                                                                   |
//|  Strategy core: lock losing basket + averaging grid + partial TP. |
//|  This EA does NOT generate entry signals on its own. It manages   |
//|  positions that already exist (either opened manually or by other |
//|  EAs sharing the same magic) and tries to bring the basket back   |
//|  to a small profit target.                                        |
//+------------------------------------------------------------------+
#property copyright "AW-Rocov"
#property link      "https://github.com/Mago201/AW-Rocov"
#property version   "0.10"
#property strict
#property description "Clean recovery EA: lock + averaging + partial TP."
#property description "Manages an existing basket; does not open initial signals."

#include <AWRocov/Logger.mqh>
#include <AWRocov/BasketManager.mqh>
#include <AWRocov/TradeOps.mqh>
#include <AWRocov/RecoveryEngine.mqh>

//+------------------------------------------------------------------+
//|  Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Identification ==="
input ulong  InpMagic                    = 20260524;
input bool   InpManageOnlyOwnOrders      = true;       // only positions with our magic

input group "=== Trigger ==="
input double InpLossThresholdPct         = 5.0;        // floating loss as % of balance
input double InpLossThresholdMoney       = 0.0;        // floating loss in account currency (0 = off)

input group "=== Lock ==="
input bool   InpUseHedgeLock             = true;       // requires hedging account
input double InpLockVolumeMultiplier     = 1.0;        // x net basket volume

input group "=== Averaging grid ==="
input int    InpAveragingStepPoints      = 300;        // grid step
input double InpAveragingLotMultiplier   = 1.5;        // each next order = prev * mult
input int    InpMaxAveragingOrders       = 8;          // safety cap

input group "=== Partial close ==="
input double InpPartialClosePct          = 50.0;       // 1..100
input int    InpPartialCloseProfitPoints = 200;        // per-position profit trigger (points)

input group "=== Basket exit ==="
input double InpBasketTPMoney            = 10.0;       // close-all profit (account currency)

input group "=== Trade ==="
input ulong  InpDeviationPoints          = 20;
input ENUM_LOG_LEVEL InpLogLevel         = LOG_INFO;

//+------------------------------------------------------------------+
//|  Globals                                                          |
//+------------------------------------------------------------------+
CLogger          g_log;
CBasketManager   g_basket;
CTradeOps        g_ops;
CRecoveryEngine  g_engine;

//+------------------------------------------------------------------+
//|  Validation                                                       |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(InpLossThresholdPct < 0.0 || InpLossThresholdMoney < 0.0)
     { Print("Invalid loss threshold values"); return false; }
   if(InpLossThresholdPct == 0.0 && InpLossThresholdMoney == 0.0)
     { Print("At least one loss threshold (pct or money) must be > 0"); return false; }
   if(InpLockVolumeMultiplier <= 0.0)
     { Print("LockVolumeMultiplier must be > 0"); return false; }
   if(InpAveragingStepPoints <= 0)
     { Print("AveragingStepPoints must be > 0"); return false; }
   if(InpAveragingLotMultiplier <= 0.0)
     { Print("AveragingLotMultiplier must be > 0"); return false; }
   if(InpMaxAveragingOrders < 0)
     { Print("MaxAveragingOrders must be >= 0"); return false; }
   if(InpPartialClosePct <= 0.0 || InpPartialClosePct > 100.0)
     { Print("PartialClosePct must be in (0..100]"); return false; }
   if(InpPartialCloseProfitPoints <= 0)
     { Print("PartialCloseProfitPoints must be > 0"); return false; }
   if(InpBasketTPMoney <= 0.0)
     { Print("BasketTPMoney must be > 0"); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//|  Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   g_log.Init("AWRocov", InpLogLevel);

   if(!g_ops.Init(_Symbol, InpMagic, InpDeviationPoints, GetPointer(g_log)))
     {
      g_log.Error("TradeOps init failed");
      return INIT_FAILED;
     }

   g_basket.Init(_Symbol, InpMagic, InpManageOnlyOwnOrders, GetPointer(g_log));

   SRecoveryConfig cfg;
   cfg.loss_threshold_pct          = InpLossThresholdPct;
   cfg.loss_threshold_money        = InpLossThresholdMoney;
   cfg.use_hedge_lock              = InpUseHedgeLock;
   cfg.lock_volume_multiplier      = InpLockVolumeMultiplier;
   cfg.averaging_step_points       = InpAveragingStepPoints;
   cfg.averaging_lot_multiplier    = InpAveragingLotMultiplier;
   cfg.max_averaging_orders        = InpMaxAveragingOrders;
   cfg.partial_close_pct           = InpPartialClosePct;
   cfg.partial_close_profit_points = InpPartialCloseProfitPoints;
   cfg.basket_tp_money             = InpBasketTPMoney;

   if(!g_engine.Init(_Symbol, cfg,
                     GetPointer(g_log),
                     GetPointer(g_basket),
                     GetPointer(g_ops)))
     {
      g_log.Error("Engine init failed");
      return INIT_FAILED;
     }

   g_log.Info(StringFormat("AWRocov v0.10 ready on %s magic=%I64u",
                           _Symbol, InpMagic));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
   g_log.Info(StringFormat("deinit reason=%d", reason));
  }

//+------------------------------------------------------------------+
//|  Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   g_engine.Tick();
   UpdateStatusComment();
  }

//+------------------------------------------------------------------+
//|  Status overlay                                                   |
//+------------------------------------------------------------------+
void UpdateStatusComment()
  {
   const SBasketStats st = g_basket.Stats();
   string s = StringFormat(
      "AWRocov v0.10 | %s | magic=%I64u\n"
      "state: %-16s   recovery_dir: %+d   lock: %s\n"
      "basket: BUY %d (%.2f lots @ %.5f) | SELL %d (%.2f lots @ %.5f)\n"
      "floating PnL: %.2f   avg orders: %d/%d",
      _Symbol, InpMagic,
      g_engine.StateString(), g_engine.RecoveryDir(),
      g_engine.LockOpened() ? "yes" : "no",
      st.buy_count,  st.buy_volume,  st.buy_avg_price,
      st.sell_count, st.sell_volume, st.sell_avg_price,
      st.floating_pnl,
      g_engine.AveragingCount(), InpMaxAveragingOrders);
   Comment(s);
  }
//+------------------------------------------------------------------+
