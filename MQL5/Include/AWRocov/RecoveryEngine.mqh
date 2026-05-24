//+------------------------------------------------------------------+
//|  RecoveryEngine.mqh                                               |
//|  Finite state machine driving the recovery process:               |
//|                                                                   |
//|     IDLE --(loss > threshold)--> LOCKING --> AVERAGING            |
//|        ^                                       |   ^              |
//|        |                                       v   |              |
//|        +---- CLOSING_ALL <-- (basket PnL >= TP)    |              |
//|                                                    v              |
//|                                            PARTIAL_CLOSING        |
//|                                                                   |
//|  All decisions are taken from the current basket snapshot, no     |
//|  hidden state on the broker side.                                 |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_RECOVERYENGINE_MQH__
#define __AWROCOV_RECOVERYENGINE_MQH__

#include "Logger.mqh"
#include "BasketManager.mqh"
#include "TradeOps.mqh"

enum ENUM_RECOVERY_STATE
  {
   REC_IDLE             = 0,
   REC_LOCKING          = 1,
   REC_AVERAGING        = 2,
   REC_PARTIAL_CLOSING  = 3,
   REC_CLOSING_ALL      = 4
  };

struct SRecoveryConfig
  {
   double  loss_threshold_pct;          // trigger: floating loss as % of balance
   double  loss_threshold_money;        // trigger: floating loss in account currency (0 = off)
   bool    use_hedge_lock;
   double  lock_volume_multiplier;
   int     averaging_step_points;
   double  averaging_lot_multiplier;
   int     max_averaging_orders;
   double  partial_close_pct;           // 1..100
   int     partial_close_profit_points; // per-position profit (points) to trigger
   double  basket_tp_money;             // close-all profit threshold
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
   int                   m_recovery_dir;      // +1 long, -1 short (set at trigger)
   double                m_last_avg_price;    // price of the last averaging entry
   double                m_last_avg_volume;   // volume used for the last averaging entry
   int                   m_avg_count;         // averaging orders added so far
   bool                  m_lock_done;
   datetime              m_state_since;

   //--- Helpers ----------------------------------------------------
   string                StateName(ENUM_RECOVERY_STATE s) const
     {
      switch(s)
        {
         case REC_IDLE:            return "IDLE";
         case REC_LOCKING:         return "LOCKING";
         case REC_AVERAGING:       return "AVERAGING";
         case REC_PARTIAL_CLOSING: return "PARTIAL_CLOSING";
         case REC_CLOSING_ALL:     return "CLOSING_ALL";
        }
      return "?";
     }

   void                  Transition(ENUM_RECOVERY_STATE next)
     {
      if(next == m_state) return;
      if(m_log)
         m_log.Info(StringFormat("state: %s -> %s",
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
      double loss = -m_basket.FloatingPnL(); // positive number when basket is in red
      if(loss <= 0.0) return false;

      bool hit_pct   = (m_cfg.loss_threshold_pct > 0.0) &&
                       (AccountBalance() > 0.0) &&
                       (loss >= AccountBalance() * m_cfg.loss_threshold_pct / 100.0);
      bool hit_money = (m_cfg.loss_threshold_money > 0.0) &&
                       (loss >= m_cfg.loss_threshold_money);
      return hit_pct || hit_money;
     }

   //--- Position profit measured in symbol points ------------------
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

   //--- State handlers --------------------------------------------
   void                  OnIdle()
     {
      if(m_basket.IsEmpty())
         return;
      if(!TriggerHit())
         return;

      m_recovery_dir = m_basket.NetDirection();
      if(m_recovery_dir == 0)
        {
         if(m_log) m_log.Warn("Trigger hit but basket is balanced; skipping");
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
         m_log.Info(StringFormat("trigger: dir=%d loss=%.2f base_lot=%.2f",
                                 m_recovery_dir,
                                 -m_basket.FloatingPnL(),
                                 m_last_avg_volume));
      Transition(REC_LOCKING);
     }

   void                  OnLocking()
     {
      if(!m_cfg.use_hedge_lock || !m_hedging_account)
        {
         if(m_log && !m_hedging_account && m_cfg.use_hedge_lock)
            m_log.Warn("Hedge lock requested but account is netting; skipping lock");
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
         if(m_log) m_log.Error("Lock open failed; staying in LOCKING");
         return;
        }
      m_lock_done = true;
      if(m_log)
         m_log.Info(StringFormat("lock opened: side=%s vol=%.2f",
                                 side == ORDER_TYPE_BUY ? "BUY" : "SELL",
                                 lock_vol));
      Transition(REC_AVERAGING);
     }

   void                  OnAveraging()
     {
      // 1) Basket-level take profit closes everything
      if(m_basket.FloatingPnL() >= m_cfg.basket_tp_money)
        {
         if(m_log)
            m_log.Info(StringFormat("basket TP reached: pnl=%.2f >= %.2f",
                                    m_basket.FloatingPnL(),
                                    m_cfg.basket_tp_money));
         Transition(REC_CLOSING_ALL);
         return;
        }

      // 2) Any position eligible for partial close?
      if(HasPartialCloseCandidate())
        {
         Transition(REC_PARTIAL_CLOSING);
         return;
        }

      // 3) Averaging step
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
                            ? (m_last_avg_price - price) / pt   // long: averaging when price drops
                            : (price - m_last_avg_price) / pt;  // short: averaging when price rises

      if(moved_points < (double)m_cfg.averaging_step_points)
         return;

      double next_vol = m_last_avg_volume * m_cfg.averaging_lot_multiplier;
      ENUM_ORDER_TYPE side = (m_recovery_dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

      ulong ticket = m_ops.OpenMarket(side, next_vol, "AWRocov:avg");
      if(ticket == 0)
        {
         if(m_log) m_log.Error("Averaging open failed");
         return;
        }
      m_avg_count++;
      m_last_avg_price  = price;
      m_last_avg_volume = next_vol;
      if(m_log)
         m_log.Info(StringFormat("avg #%d opened: side=%s vol=%.2f price=%.5f",
                                 m_avg_count,
                                 side == ORDER_TYPE_BUY ? "BUY" : "SELL",
                                 next_vol,
                                 price));
     }

   void                  OnPartialClosing()
     {
      // Always re-check basket TP first to avoid wasted partial close
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
            m_log.Info(StringFormat("partial close ticket=%I64u pct=%.1f ok=%s",
                                    t, m_cfg.partial_close_pct,
                                    ok ? "yes" : "no"));
         break; // one position per tick is enough
        }

      Transition(REC_AVERAGING);
     }

   void                  OnClosingAll()
     {
      // Snapshot the tickets list, then close each. Basket will be
      // refreshed on the next tick.
      int n = m_basket.TicketsCount();
      int closed = 0;
      for(int i = 0; i < n; i++)
        {
         ulong t = m_basket.TicketAt(i);
         if(m_ops.ClosePosition(t)) closed++;
        }
      if(m_log)
         m_log.Info(StringFormat("closing all: %d/%d closed", closed, n));

      // Reset recovery context regardless of partial failures; remaining
      // positions will be picked up by IDLE next tick if still in red.
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
         m_log.Info(StringFormat("engine init: hedging=%s",
                                 m_hedging_account ? "yes" : "no"));
      return true;
     }

   void              Tick()
     {
      m_basket.Refresh();
      switch(m_state)
        {
         case REC_IDLE:            OnIdle();            break;
         case REC_LOCKING:         OnLocking();         break;
         case REC_AVERAGING:       OnAveraging();       break;
         case REC_PARTIAL_CLOSING: OnPartialClosing();  break;
         case REC_CLOSING_ALL:     OnClosingAll();      break;
        }
     }

   //--- For Comment() / external status -------------------------
   ENUM_RECOVERY_STATE State()      const { return m_state; }
   string             StateString() const { return StateName(m_state); }
   int                AveragingCount() const { return m_avg_count; }
   int                RecoveryDir()    const { return m_recovery_dir; }
   bool               LockOpened()     const { return m_lock_done; }
  };

#endif // __AWROCOV_RECOVERYENGINE_MQH__
