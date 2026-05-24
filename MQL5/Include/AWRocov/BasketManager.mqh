//+------------------------------------------------------------------+
//|  BasketManager.mqh                                                |
//|  Агрегирует открытые позиции, отфильтрованные по символу и magic, |
//|  в снапшот корзины: объёмы по сторонам, средневзвешенная цена,    |
//|  плавающий PnL и т.п.                                             |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_BASKETMANAGER_MQH__
#define __AWROCOV_BASKETMANAGER_MQH__

#include "Logger.mqh"

struct SBasketStats
  {
   int               buy_count;          // число BUY-позиций
   int               sell_count;         // число SELL-позиций
   double            buy_volume;         // суммарный объём BUY
   double            sell_volume;        // суммарный объём SELL
   double            buy_avg_price;      // средневзвешенная цена BUY
   double            sell_avg_price;     // средневзвешенная цена SELL
   double            floating_pnl;       // плавающий PnL (включая своп)
   double            worst_buy_price;    // самая высокая BUY-цена входа (худшая при падении)
   double            worst_sell_price;   // самая низкая SELL-цена входа  (худшая при росте)
   datetime          last_open_time;     // время последнего открытия в корзине

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

   //--- Обновить снапшот по текущему состоянию терминала
   void              Refresh()
     {
      ArrayResize(m_tickets, 0);
      m_stats.Reset();

      double buy_pv = 0.0;   // сумма (цена * объём) по BUY
      double sell_pv = 0.0;  // сумма (цена * объём) по SELL

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

   //--- Аксессоры
   SBasketStats     Stats()         const { return m_stats; }
   int               TotalCount()   const { return m_stats.buy_count + m_stats.sell_count; }
   double            NetVolume()    const { return m_stats.buy_volume - m_stats.sell_volume; }
   double            FloatingPnL()  const { return m_stats.floating_pnl; }
   bool              IsEmpty()      const { return TotalCount() == 0; }
   int               TicketsCount() const { return ArraySize(m_tickets); }
   ulong             TicketAt(int i) const { return (i >= 0 && i < ArraySize(m_tickets)) ? m_tickets[i] : 0; }

   //--- Чистое направление: +1 перевес лонгов, -1 перевес шортов, 0 баланс/пусто
   int               NetDirection() const
     {
      if(m_stats.buy_volume > m_stats.sell_volume) return  1;
      if(m_stats.sell_volume > m_stats.buy_volume) return -1;
      return 0;
     }
  };

#endif // __AWROCOV_BASKETMANAGER_MQH__
