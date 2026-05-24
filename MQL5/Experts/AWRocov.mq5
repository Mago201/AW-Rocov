//+------------------------------------------------------------------+
//|                                                       AWRocov.mq5 |
//|                                AW-Rocov: чистый recovery EA (MT5) |
//|                                                                   |
//|  Ядро стратегии: замок убыточной корзины + сетка усреднения       |
//|  + частичный TP. Этот EA НЕ генерирует входные сигналы. Он        |
//|  управляет уже существующими позициями (открытыми вручную или     |
//|  другими EA с тем же magic) и пытается вернуть корзину к          |
//|  небольшой плановой прибыли.                                      |
//+------------------------------------------------------------------+
#property copyright "AW-Rocov"
#property link      "https://github.com/Mago201/AW-Rocov"
#property version   "0.10"
#property strict
#property description "Чистый recovery EA: замок + усреднение + частичный TP."
#property description "Управляет существующей корзиной; своих сигналов на вход не подаёт."

#include <AWRocov/Logger.mqh>
#include <AWRocov/BasketManager.mqh>
#include <AWRocov/TradeOps.mqh>
#include <AWRocov/RecoveryEngine.mqh>

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
input double InpBasketTPMoney            = 10.0;       // прибыль корзины для полного закрытия (валюта счёта)

input group "=== Торговля ==="
input ulong  InpDeviationPoints          = 20;         // допустимое проскальзывание (пункты)
input ENUM_LOG_LEVEL InpLogLevel         = LOG_INFO;   // уровень логов: ОТЛ/ИНФ/ПРЕ/ОШБ

//+------------------------------------------------------------------+
//|  Глобальные объекты                                               |
//+------------------------------------------------------------------+
CLogger          g_log;
CBasketManager   g_basket;
CTradeOps        g_ops;
CRecoveryEngine  g_engine;

//+------------------------------------------------------------------+
//|  Валидация параметров                                             |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(InpLossThresholdPct < 0.0 || InpLossThresholdMoney < 0.0)
     { Print("Некорректные пороги убытка"); return false; }
   if(InpLossThresholdPct == 0.0 && InpLossThresholdMoney == 0.0)
     { Print("Хотя бы один порог убытка (% или деньги) должен быть > 0"); return false; }
   if(InpLockVolumeMultiplier <= 0.0)
     { Print("InpLockVolumeMultiplier должен быть > 0"); return false; }
   if(InpAveragingStepPoints <= 0)
     { Print("InpAveragingStepPoints должен быть > 0"); return false; }
   if(InpAveragingLotMultiplier <= 0.0)
     { Print("InpAveragingLotMultiplier должен быть > 0"); return false; }
   if(InpMaxAveragingOrders < 0)
     { Print("InpMaxAveragingOrders должен быть >= 0"); return false; }
   if(InpPartialClosePct <= 0.0 || InpPartialClosePct > 100.0)
     { Print("InpPartialClosePct должен быть в (0..100]"); return false; }
   if(InpPartialCloseProfitPoints <= 0)
     { Print("InpPartialCloseProfitPoints должен быть > 0"); return false; }
   if(InpBasketTPMoney <= 0.0)
     { Print("InpBasketTPMoney должен быть > 0"); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//|  Инициализация / деинициализация                                  |
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
     {
      g_log.Error("инициализация движка не удалась");
      return INIT_FAILED;
     }

   g_log.Info(StringFormat("AWRocov v0.10 запущен на %s magic=%I64u",
                           _Symbol, InpMagic));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
   g_log.Info(StringFormat("деинициализация причина=%d", reason));
  }

//+------------------------------------------------------------------+
//|  Тик                                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   g_engine.Tick();
   UpdateStatusComment();
  }

//+------------------------------------------------------------------+
//|  Статусная плашка на графике                                      |
//+------------------------------------------------------------------+
void UpdateStatusComment()
  {
   const SBasketStats st = g_basket.Stats();
   string s = StringFormat(
      "AWRocov v0.10 | %s | magic=%I64u\n"
      "состояние: %-18s   направление: %+d   замок: %s\n"
      "корзина: BUY %d (%.2f лот @ %.5f) | SELL %d (%.2f лот @ %.5f)\n"
      "плавающий PnL: %.2f   усреднений: %d/%d",
      _Symbol, InpMagic,
      g_engine.StateString(), g_engine.RecoveryDir(),
      g_engine.LockOpened() ? "да" : "нет",
      st.buy_count,  st.buy_volume,  st.buy_avg_price,
      st.sell_count, st.sell_volume, st.sell_avg_price,
      st.floating_pnl,
      g_engine.AveragingCount(), InpMaxAveragingOrders);
   Comment(s);
  }
//+------------------------------------------------------------------+
