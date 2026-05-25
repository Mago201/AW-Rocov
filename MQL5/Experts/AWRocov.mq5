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
#property version   "0.11"
#property strict
#property description "Чистый recovery EA: замок + усреднение + частичный TP + BE-охота."
#property description "Поддерживает гармоническую и линейную схемы лота, помимо классического мартингейла."
#property description "Управляет существующей корзиной; своих сигналов на вход не подаёт."

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
input ENUM_AVG_LOT_SCHEME InpAveragingLotScheme = AVG_LOT_GEOMETRIC; // схема роста объёма
input int    InpAveragingStepPoints      = 300;        // шаг сетки (пункты)
input double InpAveragingLotMultiplier   = 1.5;        // множитель (только GEOMETRIC)
input double InpAveragingLotIncrement    = 0.5;        // приращение k для LINEAR: L_n = L_base*(1+n*k)
input int    InpMaxAveragingOrders       = 8;          // потолок числа усреднений (0 = без усреднений, сразу ПОИСК_BE)

input group "=== Частичное закрытие ==="
input double InpPartialClosePct          = 50.0;       // % закрытия (1..100)
input int    InpPartialCloseProfitPoints = 200;        // прибыль позиции (пункты) для триггера

input group "=== Выход из корзины ==="
input double InpBasketTPMoney            = 10.0;       // прибыль корзины для полного закрытия (валюта счёта)

input group "=== BE-охота (поиск безубытка) ==="
input bool   InpUseBEHunt                = true;       // переключаться в ПОИСК_BE по достижении потолка усреднений
input int    InpBEHuntStuckSeconds       = 1800;       // секунд без прогресса до forced partial close (0 = выкл)
input double InpBEHuntPartialClosePct    = 25.0;       // % закрытия худшей позиции в режиме BE
input int    InpBEHuntMinProgressPoints  = 30;         // улучшение в пунктах, считающееся «прогрессом»

input group "=== Торговля ==="
input ulong  InpDeviationPoints          = 20;         // допустимое проскальзывание (пункты)
input ENUM_LOG_LEVEL InpLogLevel         = LOG_INFO;   // уровень логов: ОТЛ/ИНФ/ПРЕ/ОШБ

input group "=== Тестовая панель (для Strategy Tester / визуального режима) ==="
input bool   InpShowTestPanel            = true;                // показывать панель кнопок
input int    InpTestPanelCorner          = CORNER_RIGHT_UPPER;  // угол графика (CORNER_*)
input int    InpTestPanelOffsetX         = 10;                  // отступ от угла, px
input int    InpTestPanelOffsetY         = 30;                  // отступ от угла, px
input double InpTestSmallLot             = 0.01;                // лот кнопок «BUY/SELL малый»
input double InpTestBigLot               = 0.10;                // лот кнопок «BUY/SELL крупный»

//+------------------------------------------------------------------+
//|  Глобальные объекты                                               |
//+------------------------------------------------------------------+
CLogger          g_log;
CBasketManager   g_basket;
CTradeOps        g_ops;
CRecoveryEngine  g_engine;
CTestPanel       g_panel;

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
   if(InpAveragingLotIncrement < 0.0)
     { Print("InpAveragingLotIncrement должен быть >= 0"); return false; }
   if(InpMaxAveragingOrders < 0)
     { Print("InpMaxAveragingOrders должен быть >= 0"); return false; }
   if(InpPartialClosePct <= 0.0 || InpPartialClosePct > 100.0)
     { Print("InpPartialClosePct должен быть в (0..100]"); return false; }
   if(InpPartialCloseProfitPoints <= 0)
     { Print("InpPartialCloseProfitPoints должен быть > 0"); return false; }
   if(InpBasketTPMoney <= 0.0)
     { Print("InpBasketTPMoney должен быть > 0"); return false; }
   if(InpBEHuntStuckSeconds < 0)
     { Print("InpBEHuntStuckSeconds должен быть >= 0"); return false; }
   if(InpBEHuntPartialClosePct <= 0.0 || InpBEHuntPartialClosePct > 100.0)
     { Print("InpBEHuntPartialClosePct должен быть в (0..100]"); return false; }
   if(InpBEHuntMinProgressPoints < 0)
     { Print("InpBEHuntMinProgressPoints должен быть >= 0"); return false; }
   // Если усреднения отключены потолком 0, BE-охота должна быть включена,
   // иначе после ЛОКИРОВАНИЯ движок зависнет в УСРЕДНЕНИИ ничего не делая.
   if(InpMaxAveragingOrders == 0 && !InpUseBEHunt)
     { Print("InpMaxAveragingOrders=0 требует включённой BE-охоты"); return false; }
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
   cfg.avg_lot_scheme              = InpAveragingLotScheme;
   cfg.averaging_step_points       = InpAveragingStepPoints;
   cfg.averaging_lot_multiplier    = InpAveragingLotMultiplier;
   cfg.averaging_lot_increment     = InpAveragingLotIncrement;
   cfg.max_averaging_orders        = InpMaxAveragingOrders;
   cfg.partial_close_pct           = InpPartialClosePct;
   cfg.partial_close_profit_points = InpPartialCloseProfitPoints;
   cfg.basket_tp_money             = InpBasketTPMoney;
   cfg.use_be_hunt                 = InpUseBEHunt;
   cfg.be_hunt_stuck_seconds       = InpBEHuntStuckSeconds;
   cfg.be_hunt_partial_pct         = InpBEHuntPartialClosePct;
   cfg.be_hunt_min_progress_points = InpBEHuntMinProgressPoints;

   if(!g_engine.Init(_Symbol, cfg,
                     GetPointer(g_log),
                     GetPointer(g_basket),
                     GetPointer(g_ops)))
     {
      g_log.Error("инициализация движка не удалась");
      return INIT_FAILED;
     }

   // Тестовая панель (только для визуального режима тестера / графика).
   // На headless-прогонах ObjectCreate просто создаст объекты, которые
   // никто не увидит и которые не повлияют на торговлю — это нормально.
   if(InpShowTestPanel)
     {
      g_panel.Init(ChartID(), "AWRocov_btn_",
                   GetPointer(g_log),
                   InpTestPanelCorner,
                   InpTestPanelOffsetX,
                   InpTestPanelOffsetY);
      g_panel.Create();
     }

   g_log.Info(StringFormat("AWRocov v0.11 запущен на %s magic=%I64u",
                           _Symbol, InpMagic));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_panel.Destroy();
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
//|  Открыть тестовую позицию по нажатию кнопки                       |
//+------------------------------------------------------------------+
void TestOpen(const ENUM_ORDER_TYPE side, const double lot)
  {
   ulong t = g_ops.OpenMarket(side, lot, "AWRocov:test");
   if(t == 0)
      g_log.Error(StringFormat("тест-открытие не удалось side=%s lot=%.2f",
                               side == ORDER_TYPE_BUY ? "BUY" : "SELL", lot));
   else
      g_log.Info(StringFormat("тест-открытие ok ticket=%I64u side=%s lot=%.2f",
                              t, side == ORDER_TYPE_BUY ? "BUY" : "SELL", lot));
  }

//+------------------------------------------------------------------+
//|  Обработчик кнопок панели                                         |
//|  Маршрутизирует CHARTEVENT_OBJECT_CLICK через g_panel.OnEvent()   |
//|  и вызывает либо движок, либо g_ops для тестового открытия.       |
//+------------------------------------------------------------------+
void OnChartEvent(const int      id,
                  const long    &lparam,
                  const double  &dparam,
                  const string  &sparam)
  {
   ENUM_PANEL_BUTTON btn = g_panel.OnEvent(id, lparam, dparam, sparam);
   switch(btn)
     {
      case PANEL_BTN_NONE: return;

      // Тестовые позиции открываются мимо движка — это «фикстуры»
      // для подготовки сценария. Дальнейшая судьба этой корзины
      // решается уже автоматом или ручными командами.
      case PANEL_BTN_BUY_SMALL:  TestOpen(ORDER_TYPE_BUY,  InpTestSmallLot); break;
      case PANEL_BTN_SELL_SMALL: TestOpen(ORDER_TYPE_SELL, InpTestSmallLot); break;
      case PANEL_BTN_BUY_BIG:    TestOpen(ORDER_TYPE_BUY,  InpTestBigLot);   break;
      case PANEL_BTN_SELL_BIG:   TestOpen(ORDER_TYPE_SELL, InpTestBigLot);   break;

      // Команды движку — взводим request-флаг, реальный переход
      // произойдёт в начале следующего Tick().
      case PANEL_BTN_CLOSE_ALL:     g_engine.RequestCloseAll();     break;
      case PANEL_BTN_RESET:         g_engine.RequestReset();        break;
      case PANEL_BTN_FORCE_TRIGGER: g_engine.RequestForceTrigger(); break;
      case PANEL_BTN_FORCE_BE_HUNT: g_engine.RequestForceBEHunt();  break;

      // Пауза — единственная команда, обрабатываемая мгновенно;
      // подпись кнопки тоже меняется сразу, чтобы оператор видел
      // фактическое состояние без ожидания тика.
      case PANEL_BTN_PAUSE_TOGGLE:
         g_engine.TogglePause();
         g_panel.SetPauseCaption(g_engine.IsPaused());
         g_log.Info(g_engine.IsPaused() ? "ПАУЗА вкл" : "ПАУЗА выкл");
         break;
     }
   ChartRedraw();
   UpdateStatusComment();
  }

//+------------------------------------------------------------------+
//|  Статусная плашка на графике                                      |
//+------------------------------------------------------------------+
void UpdateStatusComment()
  {
   const SBasketStats st = g_basket.Stats();
   double be       = g_basket.BreakEvenPrice();
   double dist_pts = g_basket.DistanceToBreakEvenPoints();

   string be_line;
   if(be > 0.0)
      be_line = StringFormat("BE: %.5f   расстояние: %.0f пт", be, dist_pts);
   else
      be_line = "BE: — (V_net=0, корзина в полном замке)";

   string be_hunt_line = "";
   if(g_engine.BEHuntActive())
     {
      datetime prog = g_engine.BEHuntProgressAt();
      int idle = (prog > 0) ? (int)(TimeCurrent() - prog) : 0;
      be_hunt_line = StringFormat(
         "\nBE-охота: forced_close=%d   простой=%d сек   лучшая дист=%.0f пт",
         g_engine.BEHuntPartials(), idle, g_engine.BEHuntBestDist());
     }

   string s = StringFormat(
      "AWRocov v0.11 | %s | magic=%I64u%s\n"
      "состояние: %-15s   направление: %+d   замок: %s   схема: %s\n"
      "корзина: BUY %d (%.2f лот @ %.5f) | SELL %d (%.2f лот @ %.5f)\n"
      "плавающий PnL: %.2f   усреднений: %d/%d\n"
      "%s%s",
      _Symbol, InpMagic,
      g_engine.IsPaused() ? "   [ПАУЗА]" : "",
      g_engine.StateString(), g_engine.RecoveryDir(),
      g_engine.LockOpened() ? "да" : "нет",
      g_engine.SchemeString(),
      st.buy_count,  st.buy_volume,  st.buy_avg_price,
      st.sell_count, st.sell_volume, st.sell_avg_price,
      st.floating_pnl,
      g_engine.AveragingCount(), InpMaxAveragingOrders,
      be_line, be_hunt_line);
   Comment(s);
  }
//+------------------------------------------------------------------+
