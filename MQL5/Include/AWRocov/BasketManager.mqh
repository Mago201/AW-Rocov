//+------------------------------------------------------------------+
//|  BasketManager.mqh                                                |
//|  Aggregates open positions filtered by symbol + magic into a      |
//|  basket snapshot: volume per side, weighted avg price, PnL, etc.  |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_BASKETMANAGER_MQH__
#define __AWROCOV_BASKETMANAGER_MQH__

#include "Logger.mqh"

struct SBasketStats
  {
   int               buy_count;
   int               sell_count;
   double            buy_volume;
   double            sell_volume;
   double            buy_avg_price;     // volume-weighted
   double            sell_avg_price;    // volume-weighted
   double            floating_pnl;      // money, includes swap+commission
   double            worst_buy_price;   // highest BUY entry (worst when price falls)
   double            worst_sell_price;  // lowest  SELL entry (worst when price rises)
   datetime          last_open_time;

   void Reset()
     {
      buy_count = sell_count = 0;
      buy_volume = sell_volume = 0.0;
      buy_avg_price = sell_avg_price = 0.0;
      floating_pnl = 0.0;
      worst_buy_price = 0.0;
      worst_sell_price = 0.0;
      last_open_time = 0;
     }
  };

class CBasketManager
  {
private:
   string            m_symbol;
   ulong             m_magic;
   bool              m_only_own;
   CLogger          *m_log;

   ulong             m_tickets[];
   SBasketStats      m_stats;

public:
                     CBasketManager(): m_log(NULL) {}

   void              Init(const string symbol,
                          const ulong  magic,
                          const bool   only_own,
                          CLogger     *logger)
     {
      m_symbol   = symbol;
      m_magic    = magic;
      m_only_own = only_own;
      m_log      = logger;
      ArrayResize(m_tickets, 0);
      m_stats.Reset();
     }

   //--- Refresh snapshot from terminal state
   void              Refresh()
     {
      ArrayResize(m_tickets, 0);
      m_stats.Reset();

      double buy_pv = 0.0;   // sum(price * volume) BUY
      double sell_pv = 0.0;  // sum(price * volume) SELL

      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;

         string sym = PositionGetString(POSITION_SYMBOL);
         if(sym != m_symbol) continue;

         ulong mg = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(m_only_own && mg != m_magic) continue;

         long type = PositionGetInteger(POSITION_TYPE);
         double vol   = PositionGetDouble(POSITION_VOLUME);
         double price = PositionGetDouble(POSITION_PRICE_OPEN);
         double pnl   = PositionGetDouble(POSITION_PROFIT)
                       + PositionGetDouble(POSITION_SWAP);
         datetime t   = (datetime)PositionGetInteger(POSITION_TIME);

         int n = ArraySize(m_tickets);
         ArrayResize(m_tickets, n + 1);
         m_tickets[n] = ticket;

         m_stats.floating_pnl += pnl;
         if(t > m_stats.last_open_time) m_stats.last_open_time = t;

         if(type == POSITION_TYPE_BUY)
           {
            m_stats.buy_count++;
            m_stats.buy_volume += vol;
            buy_pv += price * vol;
            if(price > m_stats.worst_buy_price) m_stats.worst_buy_price = price;
           }
         else if(type == POSITION_TYPE_SELL)
           {
            m_stats.sell_count++;
            m_stats.sell_volume += vol;
            sell_pv += price * vol;
            if(m_stats.worst_sell_price == 0.0 || price < m_stats.worst_sell_price)
               m_stats.worst_sell_price = price;
           }
        }

      if(m_stats.buy_volume  > 0.0) m_stats.buy_avg_price  = buy_pv  / m_stats.buy_volume;
      if(m_stats.sell_volume > 0.0) m_stats.sell_avg_price = sell_pv / m_stats.sell_volume;
     }

   //--- Accessors
   SBasketStats     Stats()         const { return m_stats; }
   int               TotalCount()   const { return m_stats.buy_count + m_stats.sell_count; }
   double            NetVolume()    const { return m_stats.buy_volume - m_stats.sell_volume; }
   double            FloatingPnL()  const { return m_stats.floating_pnl; }
   bool              IsEmpty()      const { return TotalCount() == 0; }
   int               TicketsCount() const { return ArraySize(m_tickets); }
   ulong             TicketAt(int i) const { return (i >= 0 && i < ArraySize(m_tickets)) ? m_tickets[i] : 0; }

   //--- Net direction: +1 long-heavy, -1 short-heavy, 0 balanced/empty
   int               NetDirection() const
     {
      if(m_stats.buy_volume > m_stats.sell_volume) return  1;
      if(m_stats.sell_volume > m_stats.buy_volume) return -1;
      return 0;
     }
  };

#endif // __AWROCOV_BASKETMANAGER_MQH__
