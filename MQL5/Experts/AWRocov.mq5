//+------------------------------------------------------------------+
//|                                                       AWRocov.mq5 |
//|                                AW-Rocov: чистый recovery EA (MT5) |
//+------------------------------------------------------------------+
#property copyright "AW-Rocov"
#property link      "https://github.com/Mago201/AW-Rocov"
#property version   "0.13"
#property strict
#property description "Чистый recovery EA: замок + усреднение + частичный TP."
#property description "Управляет существующей корзиной + панель ручных кнопок BUY/SELL/CLOSE."

#include <AWRocov/Logger.mqh>
#include <AWRocov/BasketManager.mqh>
#include <AWRocov/TradeOps.mqh>
#include <AWRocov/RecoveryEngine.mqh>
#include <AWRocov/Panel.mqh>

//+------------------------------------------------------------------+
//|  Параметры                                                        |
//+------------------------------------------------------------------+
input group "=== Идентификация ==="
input ulong  InpMagic                    = 20260524;   // Magic-номер
input bool   InpManageOnlyOwnOrders      = true;       // только позиции с этим magic

input group "=== Триггер ==="
input double InpLossThresholdPct         = 5.0;        // плавающий убыток в % от баланса
input double InpLossThresholdMoney       = 0.0;        // плавающий убыток в валюте счёта (0 = выкл)

input group "=== Замок ==="
input bool   InpUseHedgeLock             = true;       // требует hedging-счёт
input double InpLockVolumeMultiplier     = 1.0;        // объём замка = |нетто| × множитель

input group "=== Сетка усреднения ==="
input int    InpAveragingStepPoints      = 300;        // шаг сетки (пункты)
input double InpAveragingLotMultiplier   = 1.5;        // каждый следующий = предыдущий × множитель
input int    InpMaxAveragingOrders       = 8;          // потолок числа усреднений

input group "=== Частичное закрытие ==="
input double InpPartialClosePct          = 50.0;       // % закрытия (1..100)
input int    InpPartialCloseProfitPoints = 200;        // прибыль позиции (пункты) для триггера

input group "=== Выход из корзины ==="
input double InpBasketTPMoney            = 10.0;       // прибыль корзины для полного закрытия

input group "=== Торговля ==="
input ulong  InpDeviationPoints          = 30;         // допустимое проскальзывание (пункты)
input ENUM_LOG_LEVEL InpLogLevel         = LOG_INFO;   // уровень логов

input group "=== Ручная панель ==="
input bool   InpShowManualPanel          = true;       // показывать кнопки на графике
input double InpManualLot                = 0.01;       // лот для ручных BUY/SELL
input int    InpPanelOriginY             = 80;         // отступ панели от низа графика (пикс.)

//+------------------------------------------------------------------+
//|  Глобальные объекты                                               |
//+------------------------------------------------------------------+
CLogger          g_log;
CBasketManager   g_basket;
CTradeOps        g_ops;
CRecoveryEngine  g_engine;
CManualPanel     g_panel;

// Очередь действий из панели: клик ставит флаг, OnTick исполняет.
ENUM_PANEL_ACTION g_pending_action = PANEL_ACTION_NONE;

// Диагностика
int      g_click_counter   = 0;
string   g_last_click_name = "(нет)";
datetime g_last_click_time = 0;
string   g_last_action_msg = "—";

//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(InpLossThresholdPct < 0.0 || InpLossThresholdMoney < 0.0)
     { Print("Некорректные пороги убытка"); return false; }
   if(InpLossThresholdPct == 0.0 && InpLossThresholdMoney == 0.0)
     { Print("Хотя бы один порог убытка должен быть > 0"); return false; }
   if(InpLockVolumeMultiplier <= 0.0)        { Print("InpLockVolumeMultiplier > 0"); return false; }
   if(InpAveragingStepPoints  <= 0)          { Print("InpAveragingStepPoints > 0"); return false; }
   if(InpAveragingLotMultiplier <= 0.0)      { Print("InpAveragingLotMultiplier > 0"); return false; }
   if(InpMaxAveragingOrders < 0)             { Print("InpMaxAveragingOrders >= 0"); return false; }
   if(InpPartialClosePct <= 0.0 || InpPartialClosePct > 100.0)
                                             { Print("InpPartialClosePct in (0..100]"); return false; }
   if(InpPartialCloseProfitPoints <= 0)      { Print("InpPartialCloseProfitPoints > 0"); return false; }
   if(InpBasketTPMoney <= 0.0)               { Print("InpBasketTPMoney > 0"); return false; }
   if(InpManualLot <= 0.0)                   { Print("InpManualLot > 0"); return false; }
   if(InpPanelOriginY < 0)                   { Print("InpPanelOriginY >= 0"); return false; }
   return true;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   g_log.Init("AWRocov", InpLogLevel);

   if(!g_ops.Init(_Symbol, InpMagic, InpDeviationPoints, GetPointer(g_log)))
     {
      g_log.Error("инициализация TradeOps не удалась");
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
     { g_log.Error("инициализация движка не удалась"); return INIT_FAILED; }

   bool in_optimization = (bool)MQLInfoInteger(MQL_OPTIMIZATION);
   bool show_panel      = InpShowManualPanel && !in_optimization;

   g_panel.Init(InpManualLot, InpPanelOriginY, GetPointer(g_log));
   if(show_panel) g_panel.Show();

   if((bool)MQLInfoInteger(MQL_TESTER) && !(bool)MQLInfoInteger(MQL_VISUAL_MODE)
      && InpShowManualPanel && !in_optimization)
      g_log.Warn("тестер БЕЗ Visual Mode — клики кнопок не доходят");

   g_log.Info(StringFormat("AWRocov v0.13 запущен на %s magic=%I64u panel=%s "
                           "term_trade=%s mql_trade=%s acc_trade=%s",
                           _Symbol, InpMagic,
                           show_panel ? "да" : "нет",
                           (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "да" : "нет",
                           (bool)MQLInfoInteger(MQL_TRADE_ALLOWED) ? "да" : "нет",
                           (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ? "да" : "нет"));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_panel.Destroy();
   Comment("");
   g_log.Info(StringFormat("деинициализация причина=%d", reason));
  }

//+------------------------------------------------------------------+
//|  Клик по объекту графика                                          |
//+------------------------------------------------------------------+
void OnChartEvent(const int       id,
                  const long     &lparam,
                  const double   &dparam,
                  const string   &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   // Голый Print — попадает в журнал НЕЗАВИСИМО от уровня логирования.
   PrintFormat("[AWRocov] *** CLICK *** sparam=%s", sparam);

   g_click_counter++;
   g_last_click_name = sparam;
   g_last_click_time = TimeCurrent();

   ENUM_PANEL_ACTION act = g_panel.ActionFromClick(sparam);
   if(act != PANEL_ACTION_NONE)
     {
      g_pending_action = act;
      g_last_action_msg = StringFormat("в очереди: %s", g_panel.ActionName(act));
      g_log.Info("ставим в очередь: " + g_panel.ActionName(act));

      // Сбросить визуально нажатую кнопку
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw(0);
     }
  }

//+------------------------------------------------------------------+
//|  Обработать действие из очереди (вызывается из OnTick)            |
//+------------------------------------------------------------------+
void ProcessPendingAction()
  {
   if(g_pending_action == PANEL_ACTION_NONE)
      return;

   ENUM_PANEL_ACTION act = g_pending_action;
   g_pending_action = PANEL_ACTION_NONE;

   switch(act)
     {
      case PANEL_ACTION_BUY:
        {
         ulong t = g_ops.OpenMarket(ORDER_TYPE_BUY, InpManualLot, "AWRocov:manual_buy");
         g_last_action_msg = StringFormat("BUY %.2f -> ticket=%I64u", InpManualLot, t);
         break;
        }
      case PANEL_ACTION_SELL:
        {
         ulong t = g_ops.OpenMarket(ORDER_TYPE_SELL, InpManualLot, "AWRocov:manual_sell");
         g_last_action_msg = StringFormat("SELL %.2f -> ticket=%I64u", InpManualLot, t);
         break;
        }
      case PANEL_ACTION_CLOSE:
        {
         g_basket.Refresh();
         int n = g_basket.TicketsCount();
         int closed = 0;
         for(int i = 0; i < n; i++)
            if(g_ops.ClosePosition(g_basket.TicketAt(i))) closed++;
         g_last_action_msg = StringFormat("CLOSE %d/%d", closed, n);
         break;
        }
      default: break;
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ProcessPendingAction();
   g_engine.Tick();
   UpdateStatusComment();
  }

//+------------------------------------------------------------------+
void UpdateStatusComment()
  {
   const SBasketStats st = g_basket.Stats();
   string s = StringFormat(
      "AWRocov v0.13 | %s | magic=%I64u\n"
      "состояние: %-18s   направление: %+d   замок: %s\n"
      "корзина: BUY %d (%.2f лот @ %.5f) | SELL %d (%.2f лот @ %.5f)\n"
      "плавающий PnL: %.2f   усреднений: %d/%d\n"
      "клики: %d   последний: %s @ %s\n"
      "последнее действие: %s",
      _Symbol, InpMagic,
      g_engine.StateString(), g_engine.RecoveryDir(),
      g_engine.LockOpened() ? "да" : "нет",
      st.buy_count,  st.buy_volume,  st.buy_avg_price,
      st.sell_count, st.sell_volume, st.sell_avg_price,
      st.floating_pnl,
      g_engine.AveragingCount(), InpMaxAveragingOrders,
      g_click_counter, g_last_click_name,
      g_last_click_time == 0 ? "—" : TimeToString(g_last_click_time, TIME_SECONDS),
      g_last_action_msg);
   Comment(s);
  }
//+------------------------------------------------------------------+
