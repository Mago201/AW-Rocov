//+------------------------------------------------------------------+
//|  RecoveryEngine.mqh                                               |
//|  Конечный автомат, управляющий процессом восстановления:          |
//|                                                                   |
//|     ОЖИДАНИЕ --(убыток > порог)--> ЛОКИРОВАНИЕ --> УСРЕДНЕНИЕ     |
//|         ^                                              |  ^       |
//|         |                                              v  |       |
//|         +-- ЗАКРЫТИЕ_ВСЕХ <-- (PnL корзины >= TP)         |       |
//|                                                           v       |
//|                                                ЧАСТИЧНОЕ_ЗАКРЫТИЕ |
//|                                                                   |
//|  Все решения принимаются на основе свежего снапшота корзины,      |
//|  скрытого состояния на стороне брокера движок не предполагает.    |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_RECOVERYENGINE_MQH__
#define __AWROCOV_RECOVERYENGINE_MQH__

#include "Logger.mqh"
#include "BasketManager.mqh"
#include "TradeOps.mqh"

enum ENUM_RECOVERY_STATE
  {
   REC_IDLE             = 0,   // ожидание
   REC_LOCKING          = 1,   // локирование
   REC_AVERAGING        = 2,   // усреднение
   REC_PARTIAL_CLOSING  = 3,   // частичное закрытие
   REC_CLOSING_ALL      = 4    // закрытие всех
  };

struct SRecoveryConfig
  {
   double  loss_threshold_pct;          // триггер: плавающий убыток в % от баланса
   double  loss_threshold_money;        // триггер: плавающий убыток в валюте счёта (0 = выкл)
   bool    use_hedge_lock;              // открывать хеджирующий замок
   double  lock_volume_multiplier;      // множитель объёма замка
   int     averaging_step_points;       // шаг сетки усреднения (пункты)
   double  averaging_lot_multiplier;    // множитель лота усреднения
   int     max_averaging_orders;        // потолок числа усреднений
   double  partial_close_pct;           // % частичного закрытия [1..100]
   int     partial_close_profit_points; // прибыль позиции в пунктах для триггера частичного закрытия
   double  basket_tp_money;             // порог прибыли корзины для полного закрытия
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

   ENUM_RECOVERY_STATE   m_state;
   int                   m_recovery_dir;      // +1 лонг, -1 шорт (фиксируется на триггере)
   double                m_last_avg_price;    // цена последнего усреднения
   double                m_last_avg_volume;   // объём последнего усреднения
   int                   m_avg_count;         // счётчик усреднений
   bool                  m_lock_done;
   datetime              m_state_since;

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
      m_last_avg_volume = (m_recovery_dir > 0)
                          ? m_basket.Stats().buy_volume
                          : m_basket.Stats().sell_volume;
      if(m_log)
         m_log.Info(StringFormat("триггер: направление=%d убыток=%.2f базовый_лот=%.2f",
                                 m_recovery_dir,
                                 -m_basket.FloatingPnL(),
                                 m_last_avg_volume));
      Transition(REC_LOCKING);
     }

   void                  OnLocking()
     {
      if(!m_cfg.use_hedge_lock || !m_hedging_account)
        {
         if(m_log != NULL && !m_hedging_account && m_cfg.use_hedge_lock)
            m_log.Warn("запрошен хеджирующий замок, но счёт неттинговый; пропуск замка");
         m_lock_done = true;
         Transition(REC_AVERAGING);
         return;
        }

      double net_vol = MathAbs(m_basket.NetVolume());
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

      // 2) Есть ли позиция, готовая к частичному закрытию?
      if(HasPartialCloseCandidate())
        {
         Transition(REC_PARTIAL_CLOSING);
         return;
        }

      // 3) Шаг усреднения
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
      if(m_avg_count >= m_cfg.max_averaging_orders)
         return;

      double pt = m_ops.Point();
      if(pt <= 0.0) return;

      double price = (m_recovery_dir > 0) ? m_ops.Ask() : m_ops.Bid();
      double moved_points = (m_recovery_dir > 0)
                            ? (m_last_avg_price - price) / pt   // лонг: усредняемся при падении
                            : (price - m_last_avg_price) / pt;  // шорт: усредняемся при росте

      if(moved_points < (double)m_cfg.averaging_step_points)
         return;

      double next_vol = m_last_avg_volume * m_cfg.averaging_lot_multiplier;
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
         m_log.Info(StringFormat("усреднение #%d открыто: сторона=%s объём=%.2f цена=%.5f",
                                 m_avg_count,
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

      Transition(REC_AVERAGING);
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
      m_recovery_dir    = 0;
      m_last_avg_price  = 0.0;
      m_last_avg_volume = 0.0;
      m_avg_count       = 0;
      m_lock_done       = false;
      Transition(REC_IDLE);
     }

public:
                     CRecoveryEngine(): m_log(NULL), m_basket(NULL), m_ops(NULL),
                                        m_state(REC_IDLE), m_recovery_dir(0),
                                        m_last_avg_price(0.0), m_last_avg_volume(0.0),
                                        m_avg_count(0), m_lock_done(false),
                                        m_hedging_account(false), m_state_since(0) {}

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
      if(m_log)
         m_log.Info(StringFormat("инициализация движка: хеджирование=%s",
                                 m_hedging_account ? "да" : "нет"));
      return true;
     }

   void              Tick()
     {
      m_basket.Refresh();

      // Защитный сброс: если корзина опустела (например, через ручную
      // кнопку CLOSE или внешним вмешательством) во время цикла —
      // вернуться в ОЖИДАНИЕ, не пытаясь усреднять пустоту.
      if(m_basket.IsEmpty() && m_state != REC_IDLE)
        {
         if(m_log != NULL)
            m_log.Info("корзина опустела вне цикла закрытия — сброс в ОЖИДАНИЕ");
         m_recovery_dir    = 0;
         m_last_avg_price  = 0.0;
         m_last_avg_volume = 0.0;
         m_avg_count       = 0;
         m_lock_done       = false;
         Transition(REC_IDLE);
         return;
        }

      switch(m_state)
        {
         case REC_IDLE:            OnIdle();            break;
         case REC_LOCKING:         OnLocking();         break;
         case REC_AVERAGING:       OnAveraging();       break;
         case REC_PARTIAL_CLOSING: OnPartialClosing();  break;
         case REC_CLOSING_ALL:     OnClosingAll();      break;
        }
     }

   //--- Для Comment() / внешнего статуса --------------------------
   ENUM_RECOVERY_STATE State()      const { return m_state; }
   string             StateString() const { return StateName(m_state); }
   int                AveragingCount() const { return m_avg_count; }
   int                RecoveryDir()    const { return m_recovery_dir; }
   bool               LockOpened()     const { return m_lock_done; }
  };

#endif // __AWROCOV_RECOVERYENGINE_MQH__
