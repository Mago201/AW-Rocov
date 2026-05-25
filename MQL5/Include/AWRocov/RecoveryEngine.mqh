//+------------------------------------------------------------------+
//|  RecoveryEngine.mqh                                               |
//|  Конечный автомат, управляющий процессом восстановления:          |
//|                                                                   |
//|     ОЖИДАНИЕ --(убыток > порог)--> ЛОКИРОВАНИЕ --> УСРЕДНЕНИЕ     |
//|         ^                                              |  ^       |
//|         |                                              v  |       |
//|         |                                ЧАСТИЧНОЕ_ЗАКРЫТИЕ       |
//|         |                                              |          |
//|         |        (потолок усреднений достигнут)        |          |
//|         |        + InpUseBEHunt = true                 v          |
//|         |                                          ПОИСК_BE       |
//|         |                                              |          |
//|         +-- ЗАКРЫТИЕ_ВСЕХ <-- (PnL корзины >= TP) <----+          |
//|                                                                   |
//|  Все решения принимаются на основе свежего снапшота корзины,      |
//|  скрытого состояния на стороне брокера движок не предполагает.    |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_RECOVERYENGINE_MQH__
#define __AWROCOV_RECOVERYENGINE_MQH__

#include "Logger.mqh"
#include "BasketManager.mqh"
#include "TradeOps.mqh"

//--- Состояния автомата
enum ENUM_RECOVERY_STATE
  {
   REC_IDLE             = 0,   // ожидание
   REC_LOCKING          = 1,   // локирование
   REC_AVERAGING        = 2,   // усреднение
   REC_PARTIAL_CLOSING  = 3,   // частичное закрытие
   REC_CLOSING_ALL      = 4,   // закрытие всех
   REC_BE_HUNT          = 5    // поиск BE (BE-охота)
  };

//--- Схема роста объёма усреднения
//
//  GEOMETRIC: L_n = L_{n-1} * mult         — классический мартингейл
//             (сумма растёт как mult^N, экспоненциально).
//  HARMONIC : L_n = L_base / (n + 1)       — гармоническая последовательность
//             (сумма растёт как L_base * ln(N) — логарифмически;
//              самая «безопасная» схема, единственная с конечной
//              ожидаемой экспозицией при N -> ∞).
//  LINEAR   : L_n = L_base * (1 + n * k)   — линейный рост
//             (сумма ~ N^2/2 * k * L_base, под-квадратичная).
enum ENUM_AVG_LOT_SCHEME
  {
   AVG_LOT_GEOMETRIC = 0,   // L_n = L_{n-1} * множитель
   AVG_LOT_HARMONIC  = 1,   // L_n = L_base / (n + 1)
   AVG_LOT_LINEAR    = 2    // L_n = L_base * (1 + n * приращение)
  };

struct SRecoveryConfig
  {
   //--- Триггер и замок
   double  loss_threshold_pct;          // плавающий убыток в % от баланса
   double  loss_threshold_money;        // плавающий убыток в валюте (0 = выкл)
   bool    use_hedge_lock;              // открывать хеджирующий замок
   double  lock_volume_multiplier;      // множитель объёма замка

   //--- Усреднение
   ENUM_AVG_LOT_SCHEME avg_lot_scheme;  // схема роста объёма
   int     averaging_step_points;       // шаг сетки усреднения (пункты)
   double  averaging_lot_multiplier;    // множитель лота (только GEOMETRIC)
   double  averaging_lot_increment;     // приращение лота (только LINEAR)
   int     max_averaging_orders;        // потолок числа усреднений

   //--- Частичное закрытие (по благоприятному движению)
   double  partial_close_pct;           // % частичного закрытия [1..100]
   int     partial_close_profit_points; // прибыль позиции в пунктах для триггера

   //--- Выход из корзины
   double  basket_tp_money;             // прибыль корзины для полного закрытия

   //--- BE-охота
   bool    use_be_hunt;                 // включить переход в ПОИСК_BE по достижении потолка
   int     be_hunt_stuck_seconds;       // секунд без прогресса до forced partial close
   double  be_hunt_partial_pct;         // % закрытия худшей позиции в режиме BE
   int     be_hunt_min_progress_points; // улучшение в пунктах, считающееся «прогрессом»
  };

class CRecoveryEngine
  {
private:
   CLogger              *m_log;
   CBasketManager       *m_basket;
   CTradeOps            *m_ops;
   SRecoveryConfig       m_cfg;
   string                m_symbol;
   bool                  m_hedging_account;

   //--- Состояние автомата
   ENUM_RECOVERY_STATE   m_state;
   datetime              m_state_since;

   //--- Контекст текущего цикла восстановления
   int                   m_recovery_dir;      // +1 лонг, -1 шорт
   double                m_last_avg_price;    // цена последнего усреднения
   double                m_last_avg_volume;   // объём последнего усреднения (для GEOMETRIC)
   double                m_base_volume;       // базовый объём (для HARMONIC/LINEAR)
   int                   m_avg_count;         // счётчик усреднений
   bool                  m_lock_done;

   //--- Контекст BE-охоты
   datetime              m_be_hunt_started_at;     // когда вошли в ПОИСК_BE
   datetime              m_be_hunt_progress_at;    // последнее время прогресса
   double                m_be_hunt_best_dist_pts;  // лучшее (минимальное) расстояние до BE, пункты
   int                   m_be_hunt_partial_count;  // сколько forced partial close сделали

   //--- Управление снаружи (используется тестовой панелью).
   //    Кнопки только взводят флаги; реальные переходы происходят
   //    в начале Tick() — это держит автомат однопоточным
   //    относительно собственной логики и облегчает отладку
   //    в Strategy Tester.
   bool                  m_paused;            // движок «заморожен», состояние не меняется
   bool                  m_req_close_all;     // принудительно закрыть всю корзину
   bool                  m_req_reset;         // сбросить контекст, вернуться в ОЖИДАНИЕ (без закрытия)
   bool                  m_req_force_trigger; // активироваться, минуя порог убытка
   bool                  m_req_force_be_hunt; // принудительно перейти в ПОИСК_BE

   //--- Вспомогательное -------------------------------------------
   string                StateName(ENUM_RECOVERY_STATE s) const
     {
      switch(s)
        {
         case REC_IDLE:            return "ОЖИДАНИЕ";
         case REC_LOCKING:         return "ЛОКИРОВАНИЕ";
         case REC_AVERAGING:       return "УСРЕДНЕНИЕ";
         case REC_PARTIAL_CLOSING: return "ЧАСТ_ЗАКРЫТИЕ";
         case REC_CLOSING_ALL:     return "ЗАКРЫТИЕ_ВСЕХ";
         case REC_BE_HUNT:         return "ПОИСК_BE";
        }
      return "?";
     }

   string                SchemeName(ENUM_AVG_LOT_SCHEME s) const
     {
      switch(s)
        {
         case AVG_LOT_GEOMETRIC: return "GEOMETRIC";
         case AVG_LOT_HARMONIC:  return "HARMONIC";
         case AVG_LOT_LINEAR:    return "LINEAR";
        }
      return "?";
     }

   void                  Transition(ENUM_RECOVERY_STATE next)
     {
      if(next == m_state) return;
      if(m_log)
         m_log.Info(StringFormat("состояние: %s -> %s",
                                 StateName(m_state), StateName(next)));
      m_state = next;
      m_state_since = TimeCurrent();
     }

   void                  ResetRecoveryContext()
     {
      m_recovery_dir          = 0;
      m_last_avg_price        = 0.0;
      m_last_avg_volume       = 0.0;
      m_base_volume           = 0.0;
      m_avg_count             = 0;
      m_lock_done             = false;
      m_be_hunt_started_at    = 0;
      m_be_hunt_progress_at   = 0;
      m_be_hunt_best_dist_pts = 0.0;
      m_be_hunt_partial_count = 0;
     }

   double                AccountBalance() const
     {
      return AccountInfoDouble(ACCOUNT_BALANCE);
     }

   bool                  TriggerHit() const
     {
      double loss = -m_basket.FloatingPnL(); // положительное число при убытке
      if(loss <= 0.0) return false;

      bool hit_pct   = (m_cfg.loss_threshold_pct > 0.0) &&
                       (AccountBalance() > 0.0) &&
                       (loss >= AccountBalance() * m_cfg.loss_threshold_pct / 100.0);
      bool hit_money = (m_cfg.loss_threshold_money > 0.0) &&
                       (loss >= m_cfg.loss_threshold_money);
      return hit_pct || hit_money;
     }

   //--- Прибыль позиции в пунктах символа --------------------------
   double                ProfitPoints(const ulong ticket) const
     {
      if(!PositionSelectByTicket(ticket)) return 0.0;
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double pt    = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(pt <= 0.0) return 0.0;
      long type    = PositionGetInteger(POSITION_TYPE);
      double bid   = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(type == POSITION_TYPE_BUY)  return (bid - open) / pt;
      if(type == POSITION_TYPE_SELL) return (open - ask) / pt;
      return 0.0;
     }

   //--- Расчёт следующего объёма усреднения по выбранной схеме -----
   //    next_index — будущий 1-based номер усреднения (0,1,2,...)
   double                NextAveragingVolume(int next_index) const
     {
      switch(m_cfg.avg_lot_scheme)
        {
         case AVG_LOT_GEOMETRIC:
            // L_n = L_{n-1} * mult
            return m_last_avg_volume * m_cfg.averaging_lot_multiplier;

         case AVG_LOT_HARMONIC:
            // L_n = L_base / (n + 1), где n = next_index, начиная с 0
            // (первое усреднение получит L_base / 1 = L_base, и далее /2, /3, …)
            if(next_index < 0) next_index = 0;
            return m_base_volume / (double)(next_index + 1);

         case AVG_LOT_LINEAR:
            // L_n = L_base * (1 + n * k)
            if(next_index < 0) next_index = 0;
            return m_base_volume * (1.0 + (double)next_index * m_cfg.averaging_lot_increment);
        }
      // Fallback: повторяем базовый
      return m_base_volume;
     }

   //--- Обработчики состояний -------------------------------------
   void                  OnIdle()
     {
      if(m_basket.IsEmpty())
         return;
      if(!TriggerHit())
         return;

      m_recovery_dir = m_basket.NetDirection();
      if(m_recovery_dir == 0)
        {
         if(m_log) m_log.Warn("триггер сработал, но корзина сбалансирована; пропуск");
         return;
        }

      m_avg_count       = 0;
      m_lock_done       = false;
      m_last_avg_price  = (m_recovery_dir > 0)
                          ? m_basket.Stats().buy_avg_price
                          : m_basket.Stats().sell_avg_price;
      double base_vol   = (m_recovery_dir > 0)
                          ? m_basket.Stats().buy_volume
                          : m_basket.Stats().sell_volume;
      m_last_avg_volume = base_vol;
      m_base_volume     = base_vol;

      m_be_hunt_started_at    = 0;
      m_be_hunt_progress_at   = 0;
      m_be_hunt_best_dist_pts = 0.0;
      m_be_hunt_partial_count = 0;

      if(m_log)
         m_log.Info(StringFormat("триггер: направление=%d убыток=%.2f базовый_лот=%.2f схема=%s",
                                 m_recovery_dir,
                                 -m_basket.FloatingPnL(),
                                 m_base_volume,
                                 SchemeName(m_cfg.avg_lot_scheme)));
      Transition(REC_LOCKING);
     }

   void                  OnLocking()
     {
      if(!m_cfg.use_hedge_lock || !m_hedging_account)
        {
         if(m_log && !m_hedging_account && m_cfg.use_hedge_lock)
            m_log.Warn("запрошен хеджирующий замок, но счёт неттинговый; пропуск замка");
         m_lock_done = true;
         Transition(REC_AVERAGING);
         return;
        }

      double net_vol  = MathAbs(m_basket.NetVolume());
      double lock_vol = net_vol * m_cfg.lock_volume_multiplier;
      ENUM_ORDER_TYPE side = (m_recovery_dir > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      ulong ticket = m_ops.OpenMarket(side, lock_vol, "AWRocov:lock");
      if(ticket == 0)
        {
         if(m_log) m_log.Error("не удалось открыть замок; остаёмся в ЛОКИРОВАНИИ");
         return;
        }
      m_lock_done = true;
      if(m_log)
         m_log.Info(StringFormat("замок открыт: сторона=%s объём=%.2f",
                                 side == ORDER_TYPE_BUY ? "BUY" : "SELL",
                                 lock_vol));
      Transition(REC_AVERAGING);
     }

   void                  OnAveraging()
     {
      // 1) Достижение TP корзины — закрываем всё
      if(m_basket.FloatingPnL() >= m_cfg.basket_tp_money)
        {
         if(m_log)
            m_log.Info(StringFormat("достигнут TP корзины: pnl=%.2f >= %.2f",
                                    m_basket.FloatingPnL(),
                                    m_cfg.basket_tp_money));
         Transition(REC_CLOSING_ALL);
         return;
        }

      // 2) Есть ли позиция, готовая к частичному закрытию по прибыли?
      if(HasPartialCloseCandidate())
        {
         Transition(REC_PARTIAL_CLOSING);
         return;
        }

      // 3) Если потолок усреднений достигнут — переходим в ПОИСК_BE
      //    (если включено в конфиге). Это включает и «BE-only» режим:
      //    при max_averaging_orders == 0 мы попадаем сюда сразу.
      if(m_avg_count >= m_cfg.max_averaging_orders)
        {
         if(m_cfg.use_be_hunt)
           {
            if(m_log)
               m_log.Info(StringFormat("потолок усреднений достигнут (%d), переключаемся на ПОИСК_BE",
                                       m_avg_count));
            Transition(REC_BE_HUNT);
           }
         return;
        }

      // 4) Шаг усреднения
      TryAddAveraging();
     }

   bool                  HasPartialCloseCandidate() const
     {
      int n = m_basket.TicketsCount();
      for(int i = 0; i < n; i++)
        {
         ulong t = m_basket.TicketAt(i);
         if(ProfitPoints(t) >= (double)m_cfg.partial_close_profit_points)
            return true;
        }
      return false;
     }

   void                  TryAddAveraging()
     {
      double pt = m_ops.Point();
      if(pt <= 0.0) return;

      double price = (m_recovery_dir > 0) ? m_ops.Ask() : m_ops.Bid();
      double moved_points = (m_recovery_dir > 0)
                            ? (m_last_avg_price - price) / pt   // лонг: усредняемся при падении
                            : (price - m_last_avg_price) / pt;  // шорт: усредняемся при росте

      if(moved_points < (double)m_cfg.averaging_step_points)
         return;

      double next_vol = NextAveragingVolume(m_avg_count);
      if(next_vol <= 0.0)
        {
         if(m_log) m_log.Warn("следующий объём усреднения <= 0, пропуск");
         return;
        }

      ENUM_ORDER_TYPE side = (m_recovery_dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      ulong ticket = m_ops.OpenMarket(side, next_vol, "AWRocov:avg");
      if(ticket == 0)
        {
         if(m_log) m_log.Error("не удалось открыть усредняющий ордер");
         return;
        }
      m_avg_count++;
      m_last_avg_price  = price;
      m_last_avg_volume = next_vol;
      if(m_log)
         m_log.Info(StringFormat("усреднение #%d (%s) открыто: сторона=%s объём=%.2f цена=%.5f",
                                 m_avg_count,
                                 SchemeName(m_cfg.avg_lot_scheme),
                                 side == ORDER_TYPE_BUY ? "BUY" : "SELL",
                                 next_vol,
                                 price));
     }

   void                  OnPartialClosing()
     {
      // Сначала повторно проверим TP корзины — чтобы не делать лишний partial close
      if(m_basket.FloatingPnL() >= m_cfg.basket_tp_money)
        {
         Transition(REC_CLOSING_ALL);
         return;
        }

      int n = m_basket.TicketsCount();
      for(int i = 0; i < n; i++)
        {
         ulong t = m_basket.TicketAt(i);
         if(ProfitPoints(t) < (double)m_cfg.partial_close_profit_points)
            continue;

         bool ok = m_ops.PartialClose(t, m_cfg.partial_close_pct);
         if(m_log)
            m_log.Info(StringFormat("частичное закрытие ticket=%I64u %%=%.1f ok=%s",
                                    t, m_cfg.partial_close_pct,
                                    ok ? "да" : "нет"));
         break; // одна позиция за тик — достаточно
        }

      // Возвращаемся в УСРЕДНЕНИЕ. Если потолок достигнут и use_be_hunt=true,
      // следующий тик OnAveraging бросит нас обратно в ПОИСК_BE.
      Transition(REC_AVERAGING);
     }

   //--- Принудительное частичное закрытие позиции с худшим PnL.
   //    Это «двигатель» BE-охоты: убираем из корзины самый невыгодный
   //    элемент, тем самым смещая P_BE к рынку.
   //    Возвращает true, если ордер ушёл брокеру.
   bool                  ForceClosePoorest()
     {
      ulong t = m_basket.WorstPositionTicket();
      if(t == 0) return false;

      if(!PositionSelectByTicket(t))
         return false;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double pct = m_cfg.be_hunt_partial_pct;
      bool ok;
      if(pct >= 100.0)
         ok = m_ops.ClosePosition(t);
      else
         ok = m_ops.PartialClose(t, pct);

      if(m_log)
         m_log.Info(StringFormat(
            "BE-охота: forced close ticket=%I64u vol=%.2f %%=%.1f ok=%s",
            t, vol, pct, ok ? "да" : "нет"));
      if(ok)
         m_be_hunt_partial_count++;
      return ok;
     }

   void                  OnBEHunt()
     {
      // 1) Полный TP корзины — выход.
      if(m_basket.FloatingPnL() >= m_cfg.basket_tp_money)
        {
         if(m_log)
            m_log.Info(StringFormat("BE-охота: достигнут TP корзины pnl=%.2f", m_basket.FloatingPnL()));
         Transition(REC_CLOSING_ALL);
         return;
        }

      // 2) Если есть позиция в плюсе по пунктам — пользуемся обычным
      //    каналом частичного закрытия (он сместит ср. цену в нужную сторону).
      if(HasPartialCloseCandidate())
        {
         Transition(REC_PARTIAL_CLOSING);
         return;
        }

      // 3) Считаем расстояние до BE.
      double net = m_basket.NetVolume();
      double dist_pts = m_basket.DistanceToBreakEvenPoints();

      // Ленивая инициализация контекста BE-охоты
      datetime now = TimeCurrent();
      if(m_be_hunt_started_at == 0)
        {
         m_be_hunt_started_at    = now;
         m_be_hunt_progress_at   = now;
         m_be_hunt_best_dist_pts = dist_pts;
        }

      // 4) Полный замок (V_net == 0) — BE не определён, корзина «застыла».
      //    Единственный способ её сдвинуть — закрыть худшую позицию.
      if(MathAbs(net) < 1e-10)
        {
         if(m_log) m_log.Info("BE-охота: V_net=0, корзина в полном замке -> forced close");
         ForceClosePoorest();
         m_be_hunt_progress_at   = now;
         m_be_hunt_best_dist_pts = 0.0;
         return;
        }

      // 5) Обновляем трекер прогресса.
      double min_progress = (double)m_cfg.be_hunt_min_progress_points;
      if(dist_pts + min_progress < m_be_hunt_best_dist_pts ||
         m_be_hunt_best_dist_pts <= 0.0)
        {
         m_be_hunt_best_dist_pts = dist_pts;
         m_be_hunt_progress_at   = now;
        }

      // 6) Проверка «застоя»: слишком долго без прогресса -> forced close.
      int idle_sec = (int)(now - m_be_hunt_progress_at);
      if(m_cfg.be_hunt_stuck_seconds > 0 &&
         idle_sec >= m_cfg.be_hunt_stuck_seconds)
        {
         if(m_log)
            m_log.Info(StringFormat(
               "BE-охота: застой %d сек, dist=%.0f pts -> forced close",
               idle_sec, dist_pts));
         if(ForceClosePoorest())
           {
            // Сбрасываем трекер прогресса под новую конфигурацию корзины.
            m_be_hunt_progress_at   = now;
            m_be_hunt_best_dist_pts = 0.0;
           }
         return;
        }

      // 7) Иначе — просто ждём, что цена сама дойдёт до BE.
     }

   void                  OnClosingAll()
     {
      // Снимаем снимок списка тикетов и закрываем каждый. Корзина
      // обновится на следующем тике.
      int n = m_basket.TicketsCount();
      int closed = 0;
      for(int i = 0; i < n; i++)
        {
         ulong t = m_basket.TicketAt(i);
         if(m_ops.ClosePosition(t)) closed++;
        }
      if(m_log)
         m_log.Info(StringFormat("закрытие всех: %d/%d закрыто", closed, n));

      // Сбрасываем контекст восстановления независимо от частичных
      // ошибок; оставшиеся позиции подберёт ОЖИДАНИЕ на следующем тике.
      ResetRecoveryContext();
      Transition(REC_IDLE);
     }

public:
                     CRecoveryEngine(): m_log(NULL), m_basket(NULL), m_ops(NULL),
                                        m_state(REC_IDLE), m_state_since(0),
                                        m_recovery_dir(0),
                                        m_last_avg_price(0.0), m_last_avg_volume(0.0),
                                        m_base_volume(0.0),
                                        m_avg_count(0), m_lock_done(false),
                                        m_hedging_account(false),
                                        m_be_hunt_started_at(0),
                                        m_be_hunt_progress_at(0),
                                        m_be_hunt_best_dist_pts(0.0),
                                        m_be_hunt_partial_count(0),
                                        m_paused(false),
                                        m_req_close_all(false),
                                        m_req_reset(false),
                                        m_req_force_trigger(false),
                                        m_req_force_be_hunt(false) {}

   bool              Init(const string symbol,
                          const SRecoveryConfig &cfg,
                          CLogger        *logger,
                          CBasketManager *basket,
                          CTradeOps      *ops)
     {
      m_symbol = symbol;
      m_cfg    = cfg;
      m_log    = logger;
      m_basket = basket;
      m_ops    = ops;

      ENUM_ACCOUNT_MARGIN_MODE mm =
         (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
      m_hedging_account = (mm == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

      m_state       = REC_IDLE;
      m_state_since = TimeCurrent();
      ResetRecoveryContext();

      if(m_log)
         m_log.Info(StringFormat(
            "инициализация движка: хеджирование=%s схема_лота=%s BE-охота=%s",
            m_hedging_account ? "да" : "нет",
            SchemeName(m_cfg.avg_lot_scheme),
            m_cfg.use_be_hunt ? "вкл" : "выкл"));
      return true;
     }

   void              Tick()
     {
      // 1) Снапшот корзины обновляем всегда — даже на паузе и при
      //    обработке запросов. Comment() и расчёт BE должны быть
      //    актуальны независимо от состояния автомата.
      m_basket.Refresh();

      // 2) Запросы извне обрабатываются ДО штатного обработчика.
      //    Один клик кнопки = один атомарный переход. Следующий
      //    тик уже отработает в новом состоянии (например,
      //    REC_CLOSING_ALL подхватит OnClosingAll на следующем заходе).
      if(m_req_close_all)
        {
         m_req_close_all = false;
         if(m_log) m_log.Info("запрос: ЗАКРЫТЬ ВСЁ");
         Transition(REC_CLOSING_ALL);
         return;
        }
      if(m_req_reset)
        {
         m_req_reset = false;
         if(m_log) m_log.Info("запрос: СБРОС цикла (без закрытия позиций)");
         ResetRecoveryContext();
         Transition(REC_IDLE);
         return;
        }
      if(m_req_force_trigger)
        {
         m_req_force_trigger = false;
         ForceActivate();
         return;
        }
      if(m_req_force_be_hunt)
        {
         m_req_force_be_hunt = false;
         ForceBEHunt();
         return;
        }

      // 3) На паузе движок ничего не делает (но Refresh уже произошёл,
      //    так что Comment() и BE остаются актуальными).
      if(m_paused)
         return;

      // 4) Штатный обработчик состояния.
      switch(m_state)
        {
         case REC_IDLE:            OnIdle();            break;
         case REC_LOCKING:         OnLocking();         break;
         case REC_AVERAGING:       OnAveraging();       break;
         case REC_PARTIAL_CLOSING: OnPartialClosing();  break;
         case REC_CLOSING_ALL:     OnClosingAll();      break;
         case REC_BE_HUNT:         OnBEHunt();          break;
        }
     }

   //--- Внешнее управление (используется тестовой панелью) -------
   //    Все методы только взводят флаги; реальная работа
   //    происходит в Tick(). Это сделано, чтобы избежать
   //    «полу-переходов» из обработчика OnChartEvent.

   void              Pause()                 { m_paused = true; }
   void              Resume()                { m_paused = false; }
   void              TogglePause()           { m_paused = !m_paused; }
   bool              IsPaused() const        { return m_paused; }

   void              RequestCloseAll()       { m_req_close_all     = true; }
   void              RequestReset()          { m_req_reset         = true; }
   void              RequestForceTrigger()   { m_req_force_trigger = true; }
   void              RequestForceBEHunt()    { m_req_force_be_hunt = true; }

   //--- Для Comment() / внешнего статуса --------------------------
   ENUM_RECOVERY_STATE State()           const { return m_state; }
   string              StateString()     const { return StateName(m_state); }
   string              SchemeString()    const { return SchemeName(m_cfg.avg_lot_scheme); }
   int                 AveragingCount()  const { return m_avg_count; }
   int                 RecoveryDir()     const { return m_recovery_dir; }
   bool                LockOpened()      const { return m_lock_done; }
   bool                BEHuntActive()    const { return m_state == REC_BE_HUNT; }
   int                 BEHuntPartials()  const { return m_be_hunt_partial_count; }
   datetime            BEHuntStartedAt() const { return m_be_hunt_started_at; }
   datetime            BEHuntProgressAt() const { return m_be_hunt_progress_at; }
   double              BEHuntBestDist() const { return m_be_hunt_best_dist_pts; }

private:
   //--- Принудительная активация цикла, минуя порог убытка.
   //    Используется кнопкой ⚡ ТРИГГЕР в тестовой панели.
   //    Если корзина не пуста и не сбалансирована, входим в
   //    REC_LOCKING с обычным контекстом восстановления.
   void              ForceActivate()
     {
      if(m_basket.IsEmpty())
        {
         if(m_log) m_log.Warn("ФОРС ТРИГГЕР: корзина пуста; пропуск");
         return;
        }
      int dir = m_basket.NetDirection();
      if(dir == 0)
        {
         if(m_log) m_log.Warn("ФОРС ТРИГГЕР: корзина сбалансирована; пропуск");
         return;
        }

      m_recovery_dir    = dir;
      m_avg_count       = 0;
      m_lock_done       = false;
      m_last_avg_price  = (dir > 0)
                          ? m_basket.Stats().buy_avg_price
                          : m_basket.Stats().sell_avg_price;
      double base_vol   = (dir > 0)
                          ? m_basket.Stats().buy_volume
                          : m_basket.Stats().sell_volume;
      m_last_avg_volume = base_vol;
      m_base_volume     = base_vol;

      m_be_hunt_started_at    = 0;
      m_be_hunt_progress_at   = 0;
      m_be_hunt_best_dist_pts = 0.0;
      m_be_hunt_partial_count = 0;

      if(m_log)
         m_log.Info(StringFormat(
            "ФОРС ТРИГГЕР: направление=%d базовый_лот=%.2f схема=%s",
            dir, base_vol, SchemeName(m_cfg.avg_lot_scheme)));
      Transition(REC_LOCKING);
     }

   //--- Принудительный переход в ПОИСК_BE.
   //    Если цикл ещё не запущен (m_recovery_dir == 0), мы
   //    поднимаем минимальный контекст самостоятельно (без
   //    LOCKING — открытие новых ордеров здесь нежелательно).
   //    Если корзина в идеальном замке (V_net=0), всё равно
   //    переходим в BE_HUNT — там предусмотрен forced close.
   void              ForceBEHunt()
     {
      if(m_basket.IsEmpty())
        {
         if(m_log) m_log.Warn("ФОРС BE-HUNT: корзина пуста; пропуск");
         return;
        }

      if(m_recovery_dir == 0)
        {
         int dir = m_basket.NetDirection();
         if(dir == 0)
           {
            // V_net = 0: BE не определён, но OnBEHunt сразу
            // сделает forced close. Условно ставим dir = +1,
            // чтобы поля контекста были непустыми.
            dir = 1;
            if(m_log)
               m_log.Warn("ФОРС BE-HUNT: V_net=0, контекст условный, "
                          "будет forced close худшей позиции");
           }
         m_recovery_dir    = dir;
         m_avg_count       = 0;
         m_lock_done       = true;
         m_last_avg_price  = (dir > 0)
                             ? m_basket.Stats().buy_avg_price
                             : m_basket.Stats().sell_avg_price;
         double base_vol   = (dir > 0)
                             ? m_basket.Stats().buy_volume
                             : m_basket.Stats().sell_volume;
         m_last_avg_volume = base_vol;
         m_base_volume     = base_vol;
        }

      // Сбрасываем трекер прогресса под новый «вход» в режим.
      m_be_hunt_started_at    = 0;
      m_be_hunt_progress_at   = 0;
      m_be_hunt_best_dist_pts = 0.0;

      if(m_log) m_log.Info("ФОРС BE-HUNT");
      Transition(REC_BE_HUNT);
     }
  };

#endif // __AWROCOV_RECOVERYENGINE_MQH__
