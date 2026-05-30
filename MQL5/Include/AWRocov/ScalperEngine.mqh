//+------------------------------------------------------------------+
//|  ScalperEngine.mqh                                                |
//|  Торговый цикл скальпера с мартингейлом и предохранителями.       |
//|                                                                   |
//|  Принцип работы (одна позиция за раз):                            |
//|    ┌──────────────────────────────────────────────────────────┐  |
//|    │ нет позиции → новый бар → фильтры (спред/сессия) пройдены  │  |
//|    │            → сигнал != 0 → открыть сделку с SL/TP          │  |
//|    │ есть позиция → (опц.) трейлинг, ждём срабатывания SL/TP    │  |
//|    │ позиция закрылась → читаем реализованный PnL из истории:    │  |
//|    │     прибыль/0  → сброс шага мартина (step = 0)             │  |
//|    │     убыток     → step++ (с потолком max_steps)            │  |
//|    └──────────────────────────────────────────────────────────┘  |
//|                                                                   |
//|  Размер лота определяется НОМЕРОМ ШАГА (= число подряд убыточных  |
//|  сделок) по выбранной схеме — это и есть «регрессия по количеству |
//|  открытых ордеров»:                                              |
//|    GEOMETRIC: L = base × mult^step      (классический мартингейл) |
//|    LINEAR   : L = base × (1 + step×k)    (мягкий рост)            |
//|    HARMONIC : L = base / (step + 1)      (анти-мартингейл/убывание)|
//|                                                                   |
//|  Предохранители (даже если «просадка не важна»):                  |
//|    • потолок шагов мартина (max_mart_steps) + опц. сброс          |
//|    • абсолютный кэп лота (max_lot)                                |
//|    • фильтр спреда (важно для золота — спред «гуляет»)            |
//|    • аварийный стоп: закрыть всё и встать при просадке эквити > X% |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_SCALPERENGINE_MQH__
#define __AWROCOV_SCALPERENGINE_MQH__

#include "Logger.mqh"
#include "TradeOps.mqh"
#include "SignalEngine.mqh"
#include "BasketManager.mqh"

//--- Схема роста объёма по номеру шага мартингейла.
enum ENUM_MART_SCHEME
  {
   MART_GEOMETRIC = 0,   // L = base × mult^step   (классический мартингейл)
   MART_LINEAR    = 1,   // L = base × (1 + step×k)
   MART_HARMONIC  = 2    // L = base / (step + 1)  (убывающий, «регрессия вниз»)
  };

struct SScalperConfig
  {
   //--- Лот и мартингейл
   double            base_lot;            // базовый лот (шаг 0)
   ENUM_MART_SCHEME  mart_scheme;         // схема роста лота по шагу
   double            mart_multiplier;     // множитель (GEOMETRIC)
   double            mart_increment;      // приращение k (LINEAR)
   int               max_mart_steps;      // потолок шагов мартина
   bool              reset_after_max;     // сброс шага в 0 после достижения потолка
   double            max_lot;             // абсолютный кэп лота (0 = без кэпа)

   //--- Автолот от баланса -----------------------------------------
   //    Базовый лот = (balance / auto_lot_balance_per) * auto_lot_step.
   //    Схема «0.01 / 100» => auto_lot_step=0.01, auto_lot_balance_per=100:
   //    0.01 лота на каждые 100 единиц баланса.
   bool              use_auto_lot;        // считать базовый лот от баланса
   double            auto_lot_step;       // лот на одну «порцию» баланса
   double            auto_lot_balance_per;// размер «порции» баланса

   //--- Таргеты
   bool              use_atr_targets;     // TP/SL = ATR × множитель
   double            atr_tp_mult;         // множитель ATR для TP
   double            atr_sl_mult;         // множитель ATR для SL
   int               tp_points;           // фиксированный TP (пункты), если ATR выкл
   int               sl_points;           // фиксированный SL (пункты), если ATR выкл

   //--- Трейлинг
   bool              use_trailing;        // включить трейлинг-стоп
   int               trail_start_points;  // прибыль (пункты) для старта трейлинга
   int               trail_step_points;   // дистанция трейлинг-стопа (пункты)

   //--- Фильтры входа
   int               max_spread_points;   // не входить при спреде выше (0 = выкл)
   bool              one_trade_per_bar;   // не более одной попытки входа на бар

   //--- Фильтр сессии (часы сервера 0..23)
   bool              use_session;         // включить торговое окно
   int               session_start_hour;  // начало окна
   int               session_end_hour;    // конец окна (== start => 24ч)

   //--- Аварийный стоп
   double            max_dd_stop_pct;     // просадка эквити (%) -> закрыть всё и встать (0 = выкл)

   //--- Усреднение (мартингейл-сетка) ------------------------------
   //    Когда use_averaging = true, движок работает НЕ как
   //    «1 позиция со SL/TP», а как корзина: цена идёт против —
   //    доливаем ордер той же стороны, лот растёт по ЧИСЛУ ордеров
   //    (LotForStep(номер_ордера)), выходим всей корзиной в плюс.
   bool              use_averaging;       // включить режим усреднения
   bool              grid_step_use_atr;   // шаг сетки в ATR (иначе фикс. пункты)
   int               grid_step_points;    // шаг сетки (пункты) при grid_step_use_atr=false
   double            grid_step_atr_mult;  // множитель ATR для шага сетки
   int               max_avg_orders;      // макс. число ордеров в корзине
   double            basket_tp_money;     // профит корзины в валюте счёта для закрытия (>0 => приоритет)
   int               basket_tp_points;    // профит корзины (пункты от средней) для закрытия (если money=0)
  };

class CScalperEngine
  {
private:
   CLogger          *m_log;
   CTradeOps        *m_ops;
   CSignalEngine    *m_signal;
   SScalperConfig    m_cfg;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   ulong             m_magic;

   //--- Состояние
   int               m_mart_step;         // текущий шаг мартина (число подряд убытков)
   bool              m_had_position;      // была ли своя позиция на прошлом тике
   ulong             m_cur_ticket;        // тикет текущей позиции (если есть)
   datetime          m_last_open_time;    // время открытия последней сделки
   datetime          m_last_bar_time;     // время бара последней попытки входа
   bool              m_halted;            // аварийная остановка
   double            m_equity_peak;       // пик эквити для расчёта просадки

   //--- Статистика (для плашки)
   int               m_trades_opened;
   int               m_trades_closed;
   int               m_wins;
   int               m_losses;
   double            m_last_realized;

   //--- Состояние корзины (режим усреднения) ------------------------
   CBasketManager    m_basket;            // снапшот корзины
   int               m_basket_dir;        // направление корзины: +1 BUY / -1 SELL / 0 нет
   double            m_last_add_price;    // цена последнего открытого ордера корзины
   datetime          m_basket_open_time;  // время открытия первого ордера корзины

   //--- Найти свою позицию по символу+magic (0, если нет). ----------
   ulong             FindOwnPosition() const
     {
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         return ticket;
        }
      return 0;
     }

   //--- Реализованный PnL по выходным сделкам с момента from_time. ---
   //    Работает и на hedging, и на netting: суммируем DEAL_ENTRY_OUT
   //    (и INOUT) по нашему символу/magic за окно [from_time .. сейчас].
   double            RealizedSince(datetime from_time) const
     {
      if(from_time <= 0) from_time = TimeCurrent() - 86400;
      if(!HistorySelect(from_time - 1, TimeCurrent() + 1))
         return 0.0;

      double sum = 0.0;
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
        {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0) continue;
         if(HistoryDealGetString(dt, DEAL_SYMBOL) != m_symbol) continue;
         if((ulong)HistoryDealGetInteger(dt, DEAL_MAGIC) != m_magic) continue;
         long entry = HistoryDealGetInteger(dt, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
         sum += HistoryDealGetDouble(dt, DEAL_PROFIT)
              + HistoryDealGetDouble(dt, DEAL_SWAP)
              + HistoryDealGetDouble(dt, DEAL_COMMISSION);
        }
      return sum;
     }

   //--- Лот для заданного шага мартина по выбранной схеме. ----------
   double            LotForStep(int step) const
     {
      if(step < 0) step = 0;
      double base = EffectiveBaseLot();
      double lot = base;
      switch(m_cfg.mart_scheme)
        {
         case MART_GEOMETRIC:
            lot = base * MathPow(m_cfg.mart_multiplier, (double)step);
            break;
         case MART_LINEAR:
            lot = base * (1.0 + (double)step * m_cfg.mart_increment);
            break;
         case MART_HARMONIC:
            lot = base / (double)(step + 1);
            break;
        }
      if(m_cfg.max_lot > 0.0 && lot > m_cfg.max_lot)
         lot = m_cfg.max_lot;
      return lot;
     }

   //--- Базовый лот: фиксированный или авто от баланса. -------------
   //    Авто: (balance / balance_per) * step. Пример «0.01/100»:
   //    баланс 100 => 0.01, баланс 1000 => 0.10.
   double            EffectiveBaseLot() const
     {
      if(!m_cfg.use_auto_lot)
         return m_cfg.base_lot;
      double per = (m_cfg.auto_lot_balance_per > 0.0) ? m_cfg.auto_lot_balance_per : 100.0;
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double lot = (balance / per) * m_cfg.auto_lot_step;
      if(lot <= 0.0) lot = m_cfg.auto_lot_step;
      return lot;
     }

   //--- Рассчитать TP/SL в пунктах (ATR или фикс) с учётом stops level.
   void              ComputeTargets(int &tp_pts, int &sl_pts)
     {
      if(m_cfg.use_atr_targets)
        {
         double atr_pts = m_signal.GetATRPoints();
         tp_pts = (int)MathRound(atr_pts * m_cfg.atr_tp_mult);
         sl_pts = (int)MathRound(atr_pts * m_cfg.atr_sl_mult);
        }
      else
        {
         tp_pts = m_cfg.tp_points;
         sl_pts = m_cfg.sl_points;
        }

      // Уважаем минимальную дистанцию стопов брокера.
      int stops = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      if(tp_pts > 0 && tp_pts <= stops) tp_pts = stops + 1;
      if(sl_pts > 0 && sl_pts <= stops) sl_pts = stops + 1;
     }

   //--- Открыть скальп-сделку в направлении dir (+1 BUY / -1 SELL). --
   void              OpenScalp(int dir)
     {
      double lot = LotForStep(m_mart_step);
      int tp_pts, sl_pts;
      ComputeTargets(tp_pts, sl_pts);

      double point = m_ops.Point();
      if(point <= 0.0)
        {
         if(m_log) m_log.Warn("OpenScalp: point<=0, пропуск");
         return;
        }

      ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double price = (dir > 0) ? m_ops.Ask() : m_ops.Bid();
      double sl = 0.0, tp = 0.0;
      if(dir > 0)
        {
         sl = (sl_pts > 0) ? price - sl_pts * point : 0.0;
         tp = (tp_pts > 0) ? price + tp_pts * point : 0.0;
        }
      else
        {
         sl = (sl_pts > 0) ? price + sl_pts * point : 0.0;
         tp = (tp_pts > 0) ? price - tp_pts * point : 0.0;
        }

      ulong order = m_ops.OpenMarketSLTP(type, lot, sl, tp, "AWScalper");
      if(order == 0)
        {
         if(m_log) m_log.Error("OpenScalp: не удалось открыть сделку");
         return;
        }

      m_last_open_time = TimeCurrent();
      m_had_position   = true;
      m_trades_opened++;
      if(m_log)
         m_log.Info(StringFormat(
            "вход %s лот=%.2f шаг_мартина=%d TP=%dпт SL=%dпт",
            (dir > 0) ? "BUY" : "SELL", lot, m_mart_step, tp_pts, sl_pts));
     }

   //--- Обработка закрытия позиции: обновляем шаг мартина по PnL. ----
   void              OnPositionClosed(double realized)
     {
      m_last_realized = realized;
      m_trades_closed++;

      if(realized >= 0.0)
        {
         if(realized > 0.0) m_wins++;
         m_mart_step = 0;
         if(m_log)
            m_log.Info(StringFormat("сделка закрыта (%.2f) -> сброс мартина, шаг=0", realized));
        }
      else
        {
         m_losses++;
         if(m_mart_step < m_cfg.max_mart_steps)
           {
            m_mart_step++;
           }
         else
           {
            if(m_cfg.reset_after_max)
              {
               if(m_log)
                  m_log.Warn(StringFormat(
                     "потолок мартина (%d) достигнут -> сброс шага в 0 (ограничение убытка цикла)",
                     m_cfg.max_mart_steps));
               m_mart_step = 0;
              }
            else
              {
               if(m_log)
                  m_log.Warn(StringFormat(
                     "потолок мартина (%d) достигнут -> остаёмся на макс. шаге",
                     m_cfg.max_mart_steps));
              }
           }
         if(m_log)
            m_log.Info(StringFormat("сделка закрыта (%.2f) -> мартин шаг=%d",
                                    realized, m_mart_step));
        }
     }

   //--- Трейлинг-стоп открытой позиции. -----------------------------
   void              ApplyTrailing(ulong ticket)
     {
      if(!PositionSelectByTicket(ticket)) return;
      long   type   = PositionGetInteger(POSITION_TYPE);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur_sl = PositionGetDouble(POSITION_SL);
      double cur_tp = PositionGetDouble(POSITION_TP);
      double point  = m_ops.Point();
      if(point <= 0.0) return;

      double start = (double)m_cfg.trail_start_points;
      double step  = (double)m_cfg.trail_step_points;

      if(type == POSITION_TYPE_BUY)
        {
         double bid = m_ops.Bid();
         double profit_pts = (bid - open) / point;
         if(profit_pts >= start)
           {
            double new_sl = bid - step * point;
            if(new_sl > cur_sl)
               m_ops.ModifyPositionSLTP(ticket, new_sl, cur_tp);
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double ask = m_ops.Ask();
         double profit_pts = (open - ask) / point;
         if(profit_pts >= start)
           {
            double new_sl = ask + step * point;
            if(cur_sl == 0.0 || new_sl < cur_sl)
               m_ops.ModifyPositionSLTP(ticket, new_sl, cur_tp);
           }
        }
     }

   //--- Закрыть все свои позиции (аварийный стоп). -------------------
   void              CloseAllOwn()
     {
      for(int guard = 0; guard < 100; guard++)
        {
         ulong t = FindOwnPosition();
         if(t == 0) break;
         if(!m_ops.ClosePosition(t)) break;
        }
     }

   //--- В торговом окне? ---------------------------------------------
   bool              InSession(datetime t) const
     {
      if(!m_cfg.use_session) return true;
      MqlDateTime dt;
      TimeToStruct(t, dt);
      int h = dt.hour;
      int s = m_cfg.session_start_hour;
      int e = m_cfg.session_end_hour;
      if(s == e) return true;          // окно 24ч
      if(s < e)  return (h >= s && h < e);
      return (h >= s || h < e);        // окно через полночь
     }

   //--- Проверка аварийной просадки эквити. --------------------------
   void              CheckDrawdownStop()
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_equity_peak) m_equity_peak = equity;
      if(m_cfg.max_dd_stop_pct <= 0.0 || m_equity_peak <= 0.0) return;

      double dd = (m_equity_peak - equity) / m_equity_peak * 100.0;
      if(dd >= m_cfg.max_dd_stop_pct && !m_halted)
        {
         if(m_log)
            m_log.Warn(StringFormat(
               "АВАРИЙНЫЙ СТОП: просадка %.2f%% >= %.2f%%. Закрываю всё и останавливаюсь.",
               dd, m_cfg.max_dd_stop_pct));
         CloseAllOwn();
         m_halted = true;
        }
     }

   //--- Шаг сетки усреднения в пунктах (ATR или фикс). --------------
   double            AveragingStepPoints()
     {
      if(m_cfg.grid_step_use_atr)
        {
         double atr_pts = m_signal.GetATRPoints();
         return atr_pts * m_cfg.grid_step_atr_mult;
        }
      return (double)m_cfg.grid_step_points;
     }

   //--- Открыть ПЕРВЫЙ ордер корзины усреднения (без индивидуальных
   //    SL/TP — выходим всей корзиной). dir: +1 BUY / -1 SELL. -------
   void              OpenFirstAveraging(int dir)
     {
      double lot = LotForStep(0);
      ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      ulong order = m_ops.OpenMarket(type, lot, "AWScalper-avg");
      if(order == 0)
        {
         if(m_log) m_log.Error("OpenFirstAveraging: не удалось открыть первый ордер");
         return;
        }
      m_basket_dir       = dir;
      m_basket_open_time = TimeCurrent();
      m_last_add_price   = (dir > 0) ? m_ops.Ask() : m_ops.Bid();
      m_had_position     = true;
      m_trades_opened++;
      if(m_log)
         m_log.Info(StringFormat("корзина: первый ордер %s лот=%.2f @%.5f",
                                 (dir > 0) ? "BUY" : "SELL", lot, m_last_add_price));
     }

   //--- Долить ордер в корзину. order_index = текущее число ордеров. -
   void              AddAveragingOrder(int dir, int order_index)
     {
      double lot = LotForStep(order_index);
      ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      ulong order = m_ops.OpenMarket(type, lot, "AWScalper-avg");
      if(order == 0)
        {
         if(m_log) m_log.Error("AddAveragingOrder: не удалось долить ордер");
         return;
        }
      m_last_add_price = (dir > 0) ? m_ops.Ask() : m_ops.Bid();
      m_trades_opened++;
      if(m_log)
         m_log.Info(StringFormat("корзина: долив #%d %s лот=%.2f @%.5f (ордеров=%d)",
                                 order_index, (dir > 0) ? "BUY" : "SELL",
                                 lot, m_last_add_price, order_index + 1));
     }

   //--- Управление открытой корзиной: проверка профит-таргета и долив.
   void              ManageAveragingBasket()
     {
      SBasketStats st = m_basket.Stats();
      double point = m_ops.Point();
      if(point <= 0.0) return;

      int dir = (m_basket_dir != 0) ? m_basket_dir : m_basket.NetDirection();
      if(dir == 0) return;

      // --- 1) Профит-таргет корзины -> закрыть всё. ---
      bool do_exit = false;
      if(m_cfg.basket_tp_money > 0.0)
        {
         if(m_basket.FloatingPnL() >= m_cfg.basket_tp_money) do_exit = true;
        }
      else
        {
         double tp_dist = m_cfg.basket_tp_points * point;
         if(dir > 0)
           {
            double avg = st.buy_avg_price;
            if(avg > 0.0 && m_ops.Bid() >= avg + tp_dist) do_exit = true;
           }
         else
           {
            double avg = st.sell_avg_price;
            if(avg > 0.0 && m_ops.Ask() <= avg - tp_dist) do_exit = true;
           }
        }

      if(do_exit)
        {
         if(m_log)
            m_log.Info(StringFormat("корзина: цель достигнута (PnL=%.2f) -> закрываю всё",
                                    m_basket.FloatingPnL()));
         CloseAllOwn();
         return;
        }

      // --- 2) Долив при движении против на шаг сетки. ---
      int count = m_basket.TotalCount();
      if(count >= m_cfg.max_avg_orders) return;   // потолок корзины

      double step_pts = AveragingStepPoints();
      if(step_pts <= 0.0) return;
      double step_price = step_pts * point;

      if(dir > 0)
        {
         double bid = m_ops.Bid();
         if(m_last_add_price - bid >= step_price)
            AddAveragingOrder(dir, count);
        }
      else
        {
         double ask = m_ops.Ask();
         if(ask - m_last_add_price >= step_price)
            AddAveragingOrder(dir, count);
        }
     }

   //--- Обработка закрытия всей корзины (режим усреднения). ----------
   void              OnBasketClosed(double realized)
     {
      m_last_realized = realized;
      m_trades_closed++;
      if(realized >= 0.0) m_wins++;
      else                m_losses++;
      m_basket_dir     = 0;
      m_last_add_price = 0.0;
      if(m_log)
         m_log.Info(StringFormat("корзина закрыта, итог=%.2f", realized));
     }

   //--- Тик в режиме усреднения. ------------------------------------
   void              TickAveraging()
     {
      m_basket.Refresh();
      bool have = (m_basket.TotalCount() > 0);

      // Детект закрытия корзины.
      if(m_had_position && !have)
        {
         double realized = RealizedSince(m_basket_open_time);
         OnBasketClosed(realized);
        }
      m_had_position = have;

      // Корзина открыта — управляем (таргет/долив).
      if(have)
        {
         ManageAveragingBasket();
         return;
        }

      // Корзина пуста — ищем точку входа под первый ордер.
      datetime bar_time = iTime(m_symbol, m_tf, 0);
      if(m_cfg.one_trade_per_bar)
        {
         if(bar_time == m_last_bar_time) return;
         m_last_bar_time = bar_time;
        }
      if(!InSession(TimeCurrent())) return;

      long spread = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      if(m_cfg.max_spread_points > 0 && spread > m_cfg.max_spread_points)
         return;

      int sig = m_signal.GetSignal();
      if(sig == 0) return;

      OpenFirstAveraging(sig);
     }

public:
                     CScalperEngine(): m_log(NULL), m_ops(NULL), m_signal(NULL),
                                       m_magic(0),
                                       m_mart_step(0), m_had_position(false),
                                       m_cur_ticket(0), m_last_open_time(0),
                                       m_last_bar_time(0), m_halted(false),
                                       m_equity_peak(0.0),
                                       m_trades_opened(0), m_trades_closed(0),
                                       m_wins(0), m_losses(0), m_last_realized(0.0),
                                       m_basket_dir(0), m_last_add_price(0.0),
                                       m_basket_open_time(0) {}

   bool              Init(const string          symbol,
                          const ENUM_TIMEFRAMES  tf,
                          const ulong            magic,
                          const SScalperConfig  &cfg,
                          CLogger               *logger,
                          CTradeOps             *ops,
                          CSignalEngine         *signal)
     {
      m_symbol = symbol;
      m_tf     = tf;
      m_magic  = magic;
      m_cfg    = cfg;
      m_log    = logger;
      m_ops    = ops;
      m_signal = signal;

      m_mart_step    = 0;
      m_halted       = false;
      m_equity_peak  = AccountInfoDouble(ACCOUNT_EQUITY);
      m_last_bar_time = iTime(symbol, tf, 0);

      // Корзина усреднения.
      m_basket.Init(symbol, magic, true, logger);

      // Если на старте уже есть своя позиция — учитываем её, чтобы не
      // открыть вторую и корректно поймать её закрытие.
      if(m_cfg.use_averaging)
        {
         m_basket.Refresh();
         m_had_position = (m_basket.TotalCount() > 0);
         if(m_had_position)
           {
            m_basket_dir       = m_basket.NetDirection();
            m_basket_open_time = m_basket.Stats().last_open_time;
            m_last_add_price   = (m_basket_dir > 0) ? m_ops.Ask() : m_ops.Bid();
           }
        }
      else
        {
         ulong t = FindOwnPosition();
         m_had_position = (t != 0);
         if(m_had_position)
           {
            m_cur_ticket     = t;
            m_last_open_time = (datetime)PositionGetInteger(POSITION_TIME);
           }
        }

      if(m_log)
         m_log.Info(StringFormat(
            "ScalperEngine: режим=%s base_lot=%.2f схема=%s max_steps=%d max_lot=%.2f DD-стоп=%.1f%%",
            m_cfg.use_averaging ? "УСРЕДНЕНИЕ" : "последовательный",
            cfg.base_lot, SchemeName(cfg.mart_scheme), cfg.max_mart_steps,
            cfg.max_lot, cfg.max_dd_stop_pct));
      if(m_log != NULL && m_cfg.use_averaging)
         m_log.Info(StringFormat(
            "усреднение: шаг=%s макс_ордеров=%d таргет=%s",
            m_cfg.grid_step_use_atr
               ? StringFormat("ATR×%.2f", m_cfg.grid_step_atr_mult)
               : StringFormat("%dпт", m_cfg.grid_step_points),
            m_cfg.max_avg_orders,
            m_cfg.basket_tp_money > 0.0
               ? StringFormat("%.2f валюты", m_cfg.basket_tp_money)
               : StringFormat("%dпт от средней", m_cfg.basket_tp_points)));
      return true;
     }

   void              Tick()
     {
      // 1) Аварийный стоп по просадке.
      CheckDrawdownStop();
      if(m_halted) return;

      // 2) Режим усреднения обрабатывается отдельной веткой.
      if(m_cfg.use_averaging)
        {
         TickAveraging();
         return;
        }

      // 3) Детект закрытия позиции.
      ulong t = FindOwnPosition();
      bool have = (t != 0);
      if(have) m_cur_ticket = t;
      if(m_had_position && !have)
        {
         double realized = RealizedSince(m_last_open_time);
         OnPositionClosed(realized);
         m_cur_ticket = 0;
        }
      m_had_position = have;

      // 3) Если позиция открыта — управляем трейлингом и ждём SL/TP.
      if(have)
        {
         if(m_cfg.use_trailing) ApplyTrailing(t);
         return;
        }

      // 4) Гейт «одна попытка на бар».
      datetime bar_time = iTime(m_symbol, m_tf, 0);
      if(m_cfg.one_trade_per_bar)
        {
         if(bar_time == m_last_bar_time) return;
         m_last_bar_time = bar_time;
        }

      // 5) Фильтр сессии.
      if(!InSession(TimeCurrent())) return;

      // 6) Фильтр спреда.
      long spread = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      if(m_cfg.max_spread_points > 0 && spread > m_cfg.max_spread_points)
        {
         if(m_log) m_log.Debug(StringFormat("спред %d > лимита %d, пропуск входа",
                                            (int)spread, m_cfg.max_spread_points));
         return;
        }

      // 7) Сигнал.
      int sig = m_signal.GetSignal();
      if(sig == 0) return;

      // 8) Открываем сделку.
      OpenScalp(sig);
     }

   //--- Сброс аварийной остановки (например, с кнопки/реинициализации).
   void              ResumeFromHalt()
     {
      m_halted      = false;
      m_equity_peak = AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_log) m_log.Info("аварийная остановка снята вручную");
     }

   static string     SchemeName(ENUM_MART_SCHEME s)
     {
      switch(s)
        {
         case MART_GEOMETRIC: return "GEOMETRIC";
         case MART_LINEAR:    return "LINEAR";
         case MART_HARMONIC:  return "HARMONIC";
        }
      return "?";
     }

   //--- Геттеры для статусной плашки. --------------------------------
   int               MartStep()      const { return m_mart_step; }
   bool              Halted()        const { return m_halted; }
   double            EquityPeak()    const { return m_equity_peak; }
   int               TradesOpened()  const { return m_trades_opened; }
   int               TradesClosed()  const { return m_trades_closed; }
   int               Wins()          const { return m_wins; }
   int               Losses()        const { return m_losses; }
   double            LastRealized()  const { return m_last_realized; }
   string            SchemeString()  const { return SchemeName(m_cfg.mart_scheme); }
   double            BaseLotNow()    const { return EffectiveBaseLot(); }
   bool              IsAutoLot()     const { return m_cfg.use_auto_lot; }

   //--- В режиме усреднения «шаг» = число ордеров в корзине.
   bool              IsAveraging()   const { return m_cfg.use_averaging; }
   int               AvgOrders()     const { return m_basket.TotalCount(); }
   int               BasketDir()     const { return m_basket_dir; }
   double            BasketPnL()     const { return m_basket.FloatingPnL(); }
   double            NextLot()       const
     {
      if(m_cfg.use_averaging) return LotForStep(m_basket.TotalCount());
      return LotForStep(m_mart_step);
     }
  };

#endif // __AWROCOV_SCALPERENGINE_MQH__
