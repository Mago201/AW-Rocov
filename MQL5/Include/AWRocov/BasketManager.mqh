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

   //--- Стоимость 1 пункта движения цены для 1 лота (валюта счёта).
   //    Используется для конвертации «расстояние в цене» <-> «деньги».
   double            MoneyPerPointPerLot() const
     {
      double tick_value = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      double point      = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(tick_size <= 0.0 || point <= 0.0) return 0.0;
      return tick_value * (point / tick_size);
     }

   //--- Точка безубытка корзины с учётом текущего плавающего PnL и свопов.
   //    Возвращает 0.0, если V_net == 0 (полный замок) — BE не определён.
   //    Формула: P_BE = P_cur + (-floating_pnl) / (ppl * V_net),
   //    где ppl = MoneyPerPointPerLot, V_net = объём BUY − объём SELL.
   double            BreakEvenPrice() const
     {
      double net = NetVolume();
      if(MathAbs(net) < 1e-10) return 0.0;
      double ppl   = MoneyPerPointPerLot();
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(ppl <= 0.0 || point <= 0.0) return 0.0;
      double current = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double dist_money = -m_stats.floating_pnl;     // деньги, нужные до BE
      double dist_price = dist_money / (ppl * net);  // знак учитывается через V_net
      return current + dist_price;
     }

   //--- Знаковое расстояние до BE в пунктах (положительное — нужно благоприятное движение).
   //    0.0, если BE не определён (полный замок).
   double            DistanceToBreakEvenPoints() const
     {
      double net = NetVolume();
      if(MathAbs(net) < 1e-10) return 0.0;
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0.0) return 0.0;
      double be = BreakEvenPrice();
      if(be <= 0.0) return 0.0;
      double current = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double signed_pts = (be - current) / point;
      // знак: +1 если нужно UP, -1 если DOWN; нас интересует «расстояние»
      // в направлении, благоприятном для нетто-направления:
      //   long  (net>0): нужно price UP   => signed_pts > 0
      //   short (net<0): нужно price DOWN => signed_pts < 0
      // Возвращаем абсолютное значение — расстояние, которое надо пройти.
      return MathAbs(signed_pts);
     }

   //--- Тикет позиции с самым отрицательным плавающим PnL.
   //    Используется в режиме BE-охоты, чтобы перераспределить корзину
   //    закрытием самого «больного» элемента: BE сместится в сторону рынка.
   //    0, если корзина пуста.
   ulong             WorstPositionTicket() const
     {
      ulong  worst     = 0;
      double worst_pnl = 0.0;
      bool   first     = true;
      int n = ArraySize(m_tickets);
      for(int i = 0; i < n; i++)
        {
         ulong t = m_tickets[i];
         if(!PositionSelectByTicket(t)) continue;
         double pnl = PositionGetDouble(POSITION_PROFIT)
                    + PositionGetDouble(POSITION_SWAP);
         if(first || pnl < worst_pnl)
           {
            worst     = t;
            worst_pnl = pnl;
            first     = false;
           }
        }
      return worst;
     }
  };

#endif // __AWROCOV_BASKETMANAGER_MQH__
