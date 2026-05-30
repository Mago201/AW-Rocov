//+------------------------------------------------------------------+
//|                                                     AWScalper.mq5 |
//|                          AW-Rocov: скальпер с мартингейлом (MT5)  |
//|                                                                   |
//|  В ОТЛИЧИЕ от AWRocov.mq5 (чистый recovery без входов), этот EA    |
//|  САМ генерирует входные сигналы и торгует по одной позиции за раз: |
//|     тренд-фильтр EMA + откат RSI + адаптивные TP/SL по ATR,        |
//|     с мартингейлом по числу подряд убыточных сделок.              |
//|                                                                   |
//|  Заточен под XAUUSD M1/M5. Имеет предохранители: потолок шагов     |
//|  мартина, кэп лота, фильтр спреда и аварийный стоп по просадке.    |
//|                                                                   |
//|  ВНИМАНИЕ: мартингейл несёт «хвостовой» риск обнуления депозита.   |
//|  Тестируйте только на ДЕМО, пока не поймёте взаимодействие         |
//|  параметров и поведение на затяжных трендах против позиции.        |
//+------------------------------------------------------------------+
#property copyright "AW-Rocov"
#property link      "https://github.com/Mago201/AW-Rocov"
#property version   "0.1"
#property strict
#property description "Скальпер для XAUUSD M1/M5: EMA-тренд + RSI-откат + ATR-таргеты."
#property description "Классический мартингейл по числу подряд убыточных сделок (3 схемы лота)."
#property description "Предохранители: кэп лота, потолок шагов, фильтр спреда, аварийный стоп по просадке."

#include <AWRocov/Logger.mqh>
#include <AWRocov/TradeOps.mqh>
#include <AWRocov/SignalEngine.mqh>
#include <AWRocov/ScalperEngine.mqh>

//+------------------------------------------------------------------+
//|  Параметры                                                        |
//+------------------------------------------------------------------+
input group "=== Идентификация ==="
input ulong           InpMagic              = 20260530;       // Magic-номер
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_M5;      // рабочий ТФ (M1/M5)

input group "=== Сигнал: тренд (EMA) ==="
input int    InpEmaFastPeriod  = 21;       // период быстрой EMA
input int    InpEmaSlowPeriod  = 50;       // период медленной EMA

input group "=== Сигнал: откат (RSI) ==="
input int    InpRsiPeriod      = 14;       // период RSI
input double InpRsiBuyLevel    = 40.0;     // RSI <= уровня в аптренде => BUY
input double InpRsiSellLevel   = 60.0;     // RSI >= уровня в даунтренде => SELL

input group "=== Таргеты (TP/SL) ==="
input bool   InpUseATRTargets  = true;     // TP/SL по ATR (иначе фикс. пункты)
input int    InpAtrPeriod      = 14;       // период ATR
input double InpAtrTpMult       = 1.0;     // множитель ATR для TP (скальп)
input double InpAtrSlMult       = 1.8;     // множитель ATR для SL
input int    InpTpPoints        = 150;     // фикс. TP (пункты), если ATR выкл
input int    InpSlPoints        = 280;     // фикс. SL (пункты), если ATR выкл

input group "=== Мартингейл ==="
input double           InpBaseLot        = 0.01;            // базовый лот (шаг 0)
input ENUM_MART_SCHEME InpMartScheme     = MART_GEOMETRIC;  // схема роста лота по шагу
input double           InpMartMultiplier = 1.5;             // множитель (GEOMETRIC)
input double           InpMartIncrement  = 0.5;             // приращение k (LINEAR)
input int              InpMaxMartSteps   = 6;               // потолок шагов мартина
input bool             InpResetAfterMax  = true;            // сброс шага в 0 после потолка
input double           InpMaxLot         = 5.0;             // абсолютный кэп лота (0 = без кэпа)

input group "=== Трейлинг ==="
input bool   InpUseTrailing       = false;  // включить трейлинг-стоп
input int    InpTrailStartPoints  = 200;    // прибыль (пункты) для старта трейлинга
input int    InpTrailStepPoints   = 120;    // дистанция трейлинг-стопа (пункты)

input group "=== Фильтры входа ==="
input int    InpMaxSpreadPoints   = 60;     // макс. спред для входа (пункты, 0 = выкл)
input bool   InpOneTradePerBar    = true;   // не более одной попытки входа на бар

input group "=== Торговое окно (часы сервера) ==="
input bool   InpUseSession        = false;  // включить торговое окно
input int    InpSessionStartHour  = 7;      // начало окна (час)
input int    InpSessionEndHour    = 21;     // конец окна (час; == start => 24ч)

input group "=== Предохранители ==="
input double InpMaxDrawdownStopPct = 30.0;  // просадка эквити (%) -> закрыть всё и встать (0 = выкл)

input group "=== Усреднение (мартингейл-сетка) ==="
input bool   InpUseAveraging      = false;  // ВКЛ режим усреднения (вместо 1 позиции со SL/TP)
input bool   InpGridStepUseATR    = false;  // шаг сетки по ATR (иначе фикс. пункты)
input int    InpGridStepPoints    = 300;    // шаг сетки (пункты) при выключенном ATR
input double InpGridStepAtrMult   = 1.5;    // множитель ATR для шага сетки
input int    InpMaxAveragingOrders = 10;    // макс. ордеров в корзине
input double InpBasketTpMoney     = 0.0;    // профит корзины в валюте счёта (>0 => приоритет)
input int    InpBasketTpPoints    = 100;    // профит корзины (пункты от средней), если money=0

input group "=== Торговля / логи ==="
input ulong  InpDeviationPoints   = 30;          // допустимое проскальзывание (пункты)
input ENUM_LOG_LEVEL InpLogLevel  = LOG_INFO;    // уровень логов: ОТЛ/ИНФ/ПРЕ/ОШБ

//+------------------------------------------------------------------+
//|  Глобальные объекты                                               |
//+------------------------------------------------------------------+
CLogger        g_log;
CTradeOps      g_ops;
CSignalEngine  g_signal;
CScalperEngine g_engine;

//+------------------------------------------------------------------+
//|  Валидация параметров                                             |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(InpTimeframe != PERIOD_M1 && InpTimeframe != PERIOD_M5)
      Print("ПРЕДУПРЕЖДЕНИЕ: EA рассчитан на M1/M5; выбран ", EnumToString(InpTimeframe));

   if(InpEmaFastPeriod <= 0 || InpEmaSlowPeriod <= 0)
     { Print("Периоды EMA должны быть > 0"); return false; }
   if(InpEmaFastPeriod >= InpEmaSlowPeriod)
     { Print("InpEmaFastPeriod должен быть < InpEmaSlowPeriod"); return false; }
   if(InpRsiPeriod <= 0)
     { Print("InpRsiPeriod должен быть > 0"); return false; }
   if(InpRsiBuyLevel <= 0.0 || InpRsiBuyLevel >= 100.0 ||
      InpRsiSellLevel <= 0.0 || InpRsiSellLevel >= 100.0)
     { Print("Уровни RSI должны быть в (0..100)"); return false; }
   if(InpRsiBuyLevel >= InpRsiSellLevel)
     { Print("InpRsiBuyLevel должен быть < InpRsiSellLevel"); return false; }
   if(InpAtrPeriod <= 0)
     { Print("InpAtrPeriod должен быть > 0"); return false; }
   if(InpUseATRTargets && (InpAtrTpMult <= 0.0 || InpAtrSlMult <= 0.0))
     { Print("Множители ATR должны быть > 0"); return false; }
   if(!InpUseATRTargets && (InpTpPoints <= 0 || InpSlPoints <= 0))
     { Print("Фикс. TP/SL (пункты) должны быть > 0"); return false; }
   if(InpBaseLot <= 0.0)
     { Print("InpBaseLot должен быть > 0"); return false; }
   if(InpMartScheme == MART_GEOMETRIC && InpMartMultiplier <= 1.0)
      Print("ПРЕДУПРЕЖДЕНИЕ: множитель <= 1.0 для GEOMETRIC не наращивает лот");
   if(InpMartScheme == MART_LINEAR && InpMartIncrement < 0.0)
     { Print("InpMartIncrement должен быть >= 0"); return false; }
   if(InpMaxMartSteps < 0)
     { Print("InpMaxMartSteps должен быть >= 0"); return false; }
   if(InpMaxLot < 0.0)
     { Print("InpMaxLot должен быть >= 0"); return false; }
   if(InpUseTrailing && (InpTrailStartPoints <= 0 || InpTrailStepPoints <= 0))
     { Print("Параметры трейлинга должны быть > 0"); return false; }
   if(InpMaxSpreadPoints < 0)
     { Print("InpMaxSpreadPoints должен быть >= 0"); return false; }
   if(InpUseSession &&
      (InpSessionStartHour < 0 || InpSessionStartHour > 23 ||
       InpSessionEndHour   < 0 || InpSessionEndHour   > 23))
     { Print("Часы сессии должны быть в [0..23]"); return false; }
   if(InpMaxDrawdownStopPct < 0.0 || InpMaxDrawdownStopPct >= 100.0)
     { Print("InpMaxDrawdownStopPct должен быть в [0..100)"); return false; }

   if(InpUseAveraging)
     {
      if(InpGridStepUseATR && InpGridStepAtrMult <= 0.0)
        { Print("InpGridStepAtrMult должен быть > 0"); return false; }
      if(!InpGridStepUseATR && InpGridStepPoints <= 0)
        { Print("InpGridStepPoints должен быть > 0"); return false; }
      if(InpMaxAveragingOrders < 1)
        { Print("InpMaxAveragingOrders должен быть >= 1"); return false; }
      if(InpBasketTpMoney <= 0.0 && InpBasketTpPoints <= 0)
        { Print("Задайте профит-таргет корзины: InpBasketTpMoney или InpBasketTpPoints"); return false; }
      if(InpUseTrailing)
         Print("ПРЕДУПРЕЖДЕНИЕ: трейлинг игнорируется в режиме усреднения (выход всей корзиной)");
     }
   return true;
  }

//+------------------------------------------------------------------+
//|  Инициализация / деинициализация                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   g_log.Init("AWScalper", InpLogLevel);

   if(!g_ops.Init(_Symbol, InpMagic, InpDeviationPoints, GetPointer(g_log)))
     {
      g_log.Error("инициализация TradeOps не удалась");
      return INIT_FAILED;
     }

   SSignalConfig scfg;
   scfg.ema_fast_period = InpEmaFastPeriod;
   scfg.ema_slow_period = InpEmaSlowPeriod;
   scfg.rsi_period      = InpRsiPeriod;
   scfg.rsi_buy_level   = InpRsiBuyLevel;
   scfg.rsi_sell_level  = InpRsiSellLevel;
   scfg.atr_period      = InpAtrPeriod;
   scfg.signal_shift    = 1;   // последний закрытый бар

   if(!g_signal.Init(_Symbol, InpTimeframe, scfg, GetPointer(g_log)))
     {
      g_log.Error("инициализация SignalEngine не удалась");
      return INIT_FAILED;
     }

   SScalperConfig cfg;
   cfg.base_lot           = InpBaseLot;
   cfg.mart_scheme        = InpMartScheme;
   cfg.mart_multiplier    = InpMartMultiplier;
   cfg.mart_increment     = InpMartIncrement;
   cfg.max_mart_steps     = InpMaxMartSteps;
   cfg.reset_after_max    = InpResetAfterMax;
   cfg.max_lot            = InpMaxLot;
   cfg.use_atr_targets    = InpUseATRTargets;
   cfg.atr_tp_mult        = InpAtrTpMult;
   cfg.atr_sl_mult        = InpAtrSlMult;
   cfg.tp_points          = InpTpPoints;
   cfg.sl_points          = InpSlPoints;
   cfg.use_trailing       = InpUseTrailing;
   cfg.trail_start_points = InpTrailStartPoints;
   cfg.trail_step_points  = InpTrailStepPoints;
   cfg.max_spread_points  = InpMaxSpreadPoints;
   cfg.one_trade_per_bar  = InpOneTradePerBar;
   cfg.use_session        = InpUseSession;
   cfg.session_start_hour = InpSessionStartHour;
   cfg.session_end_hour   = InpSessionEndHour;
   cfg.max_dd_stop_pct    = InpMaxDrawdownStopPct;

   cfg.use_averaging      = InpUseAveraging;
   cfg.grid_step_use_atr  = InpGridStepUseATR;
   cfg.grid_step_points   = InpGridStepPoints;
   cfg.grid_step_atr_mult = InpGridStepAtrMult;
   cfg.max_avg_orders     = InpMaxAveragingOrders;
   cfg.basket_tp_money    = InpBasketTpMoney;
   cfg.basket_tp_points   = InpBasketTpPoints;

   if(!g_engine.Init(_Symbol, InpTimeframe, InpMagic, cfg,
                     GetPointer(g_log),
                     GetPointer(g_ops),
                     GetPointer(g_signal)))
     {
      g_log.Error("инициализация ScalperEngine не удалась");
      return INIT_FAILED;
     }

   g_log.Info(StringFormat("AWScalper v0.1 запущен на %s %s magic=%I64u",
                           _Symbol, EnumToString(InpTimeframe), InpMagic));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_signal.Release();
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
//|  Статусная плашка                                                 |
//+------------------------------------------------------------------+
void UpdateStatusComment()
  {
   int    trend = g_signal.TrendDirection();
   double rsi   = g_signal.CurrentRSI();
   string trend_s = (trend > 0) ? "ВВЕРХ" : (trend < 0 ? "ВНИЗ" : "флэт");
   long   spread  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   int closed = g_engine.TradesClosed();
   double winrate = (closed > 0) ? (100.0 * g_engine.Wins() / closed) : 0.0;

   string halt_line = g_engine.Halted()
                      ? "\n*** АВАРИЙНЫЙ СТОП: торговля остановлена по просадке ***"
                      : "";

   string mode_line;
   if(g_engine.IsAveraging())
     {
      int    bdir = g_engine.BasketDir();
      string bdir_s = (bdir > 0) ? "BUY" : (bdir < 0 ? "SELL" : "—");
      mode_line = StringFormat(
         "режим: УСРЕДНЕНИЕ   корзина: %s ордеров=%d   PnL=%.2f\n"
         "след. лот долива=%.2f   схема=%s",
         bdir_s, g_engine.AvgOrders(), g_engine.BasketPnL(),
         g_engine.NextLot(), g_engine.SchemeString());
     }
   else
     {
      mode_line = StringFormat(
         "режим: последовательный   мартин: шаг=%d   след. лот=%.2f   схема=%s",
         g_engine.MartStep(), g_engine.NextLot(), g_engine.SchemeString());
     }

   string s = StringFormat(
      "AWScalper v0.1 | %s %s | magic=%I64u\n"
      "тренд: %s   RSI: %.1f   спред: %d пт\n"
      "%s\n"
      "сделок: открыто=%d закрыто=%d   W/L=%d/%d   винрейт=%.1f%%\n"
      "последний результат: %.2f   пик эквити: %.2f%s",
      _Symbol, EnumToString(InpTimeframe), InpMagic,
      trend_s, rsi, (int)spread,
      mode_line,
      g_engine.TradesOpened(), closed,
      g_engine.Wins(), g_engine.Losses(), winrate,
      g_engine.LastRealized(), g_engine.EquityPeak(),
      halt_line);
   Comment(s);
  }
//+------------------------------------------------------------------+
