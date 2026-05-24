//+------------------------------------------------------------------+
//|  TradeOps.mqh                                                     |
//|  Низкоуровневая обёртка торговых операций. Использует голый       |
//|  OrderSend (без CTrade), чтобы исключить «тихие» отказы из-за     |
//|  несовпадающего filling-режима. Перебирает поддерживаемые         |
//|  символом filling-режимы по очереди до первого успеха.            |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_TRADEOPS_MQH__
#define __AWROCOV_TRADEOPS_MQH__

#include "Logger.mqh"

class CTradeOps
  {
private:
   CLogger          *m_log;
   string            m_symbol;
   ulong             m_magic;
   ulong             m_deviation;

   //--- Подобрать список filling-режимов в порядке предпочтения
   int               BuildFillingList(ENUM_ORDER_TYPE_FILLING &out[]) const
     {
      ArrayResize(out, 3);
      int n = 0;
      long ff = SymbolInfoInteger(m_symbol, SYMBOL_FILLING_MODE);
      if((ff & SYMBOL_FILLING_FOK) != 0) out[n++] = ORDER_FILLING_FOK;
      if((ff & SYMBOL_FILLING_IOC) != 0) out[n++] = ORDER_FILLING_IOC;
      out[n++] = ORDER_FILLING_RETURN;        // всегда есть как запасной
      ArrayResize(out, n);
      return n;
     }

   string            FillingName(const ENUM_ORDER_TYPE_FILLING f) const
     {
      switch(f)
        {
         case ORDER_FILLING_FOK:    return "FOK";
         case ORDER_FILLING_IOC:    return "IOC";
         case ORDER_FILLING_RETURN: return "RETURN";
        }
      return "?";
     }

public:
                     CTradeOps(): m_log(NULL), m_deviation(20) {}

   bool              Init(const string symbol,
                          const ulong  magic,
                          const ulong  deviation_points,
                          CLogger     *logger)
     {
      m_symbol    = symbol;
      m_magic     = magic;
      m_deviation = deviation_points;
      m_log       = logger;

      // Принудительно подгружаем символ в Market Watch — без этого
      // SymbolInfoTick может вернуть нули, и OrderSend упадёт.
      if(!SymbolSelect(symbol, true))
        {
         if(m_log) m_log.Error("Init: не удалось выбрать символ " + symbol);
         return false;
        }
      return true;
     }

   //--- Нормализация объёма к шагу/мин/макс символа
   double            NormalizeVolume(const double volume) const
     {
      double step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double mn   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double mx   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      if(step <= 0.0) step = 0.01;

      double v = MathFloor(volume / step + 0.0000001) * step;
      if(v < mn) v = mn;
      if(v > mx) v = mx;

      int digits = (int)MathMax(0, -MathLog10(step));
      return NormalizeDouble(v, digits);
     }

   double            Point() const  { return SymbolInfoDouble(m_symbol, SYMBOL_POINT); }
   double            Bid()
     {
      MqlTick t; if(SymbolInfoTick(m_symbol, t)) return t.bid;
      return SymbolInfoDouble(m_symbol, SYMBOL_BID);
     }
   double            Ask()
     {
      MqlTick t; if(SymbolInfoTick(m_symbol, t)) return t.ask;
      return SymbolInfoDouble(m_symbol, SYMBOL_ASK);
     }

   //+----------------------------------------------------------------+
   //| Открыть рыночный ордер. Возвращает order ticket или 0.         |
   //+----------------------------------------------------------------+
   ulong             OpenMarket(const ENUM_ORDER_TYPE type,
                                const double          volume,
                                const string          comment)
     {
      // === Pre-flight ===
      if(!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        {
         if(m_log) m_log.Error("OpenMarket: торговля запрещена в терминале (выкл. AutoTrading)");
         return 0;
        }
      if(!(bool)MQLInfoInteger(MQL_TRADE_ALLOWED))
        {
         if(m_log) m_log.Error("OpenMarket: торговля запрещена для этого EA (галка 'Allow Algo Trading' в свойствах EA)");
         return 0;
        }
      if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
        {
         if(m_log) m_log.Error("OpenMarket: торговля запрещена для счёта");
         return 0;
        }

      if(!SymbolSelect(m_symbol, true))
        {
         if(m_log) m_log.Error("OpenMarket: не удалось выбрать символ " + m_symbol);
         return 0;
        }

      double v = NormalizeVolume(volume);
      if(v <= 0.0)
        {
         if(m_log) m_log.Error(StringFormat("OpenMarket: нормализованный объём = 0 (запрошено %.2f)", volume));
         return 0;
        }

      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
        {
         if(m_log) m_log.Error(StringFormat("OpenMarket: SymbolInfoTick дал bid=%.5f ask=%.5f", tick.bid, tick.ask));
         return 0;
        }

      double price = (type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;

      // === Сборка запроса ===
      MqlTradeRequest req; ZeroMemory(req);
      MqlTradeResult  res; ZeroMemory(res);

      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = m_symbol;
      req.volume       = v;
      req.type         = type;
      req.price        = NormalizeDouble(price, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));
      req.deviation    = m_deviation;
      req.magic        = m_magic;
      req.comment      = comment;
      req.type_time    = ORDER_TIME_GTC;

      // === Попытки с разными filling-режимами ===
      ENUM_ORDER_TYPE_FILLING fills[];
      int fc = BuildFillingList(fills);

      for(int i = 0; i < fc; i++)
        {
         req.type_filling = fills[i];
         ZeroMemory(res);

         ResetLastError();
         bool sent = OrderSend(req, res);

         if(m_log)
            m_log.Info(StringFormat(
               "OrderSend [%s] sent=%s retcode=%u (%s) deal=%I64u order=%I64u err=%d",
               FillingName(fills[i]),
               sent ? "true" : "false",
               res.retcode, res.comment,
               res.deal, res.order,
               GetLastError()));

         if(sent &&
            (res.retcode == TRADE_RETCODE_DONE ||
             res.retcode == TRADE_RETCODE_PLACED ||
             res.retcode == TRADE_RETCODE_DONE_PARTIAL))
           {
            if(m_log)
               m_log.Info(StringFormat(
                  "OpenMarket OK: order=%I64u deal=%I64u price=%.5f vol=%.2f filling=%s",
                  res.order, res.deal, res.price, res.volume,
                  FillingName(fills[i])));
            return res.order;
           }

         // Меняет ли смысл пробовать другой filling? Только если ругался
         // именно на filling. На любую другую ошибку выходим сразу.
         if(res.retcode != TRADE_RETCODE_INVALID_FILL &&
            res.retcode != 0)
            break;
        }

      if(m_log)
         m_log.Error(StringFormat(
            "OpenMarket FAILED: type=%s lot=%.2f price=%.5f symbol=%s "
            "retcode=%u (%s) bid=%.5f ask=%.5f free_margin=%.2f",
            type == ORDER_TYPE_BUY ? "BUY" : "SELL",
            v, price, m_symbol,
            res.retcode, res.comment,
            tick.bid, tick.ask,
            AccountInfoDouble(ACCOUNT_MARGIN_FREE)));
      return 0;
     }

   //+----------------------------------------------------------------+
   //| Полное закрытие позиции по тикету. true при успехе.            |
   //+----------------------------------------------------------------+
   bool              ClosePosition(const ulong ticket)
     {
      if(!PositionSelectByTicket(ticket))
        {
         if(m_log) m_log.Warn(StringFormat("Close: нет позиции ticket=%I64u", ticket));
         return false;
        }
      string sym  = PositionGetString(POSITION_SYMBOL);
      long   ptype= PositionGetInteger(POSITION_TYPE);
      double vol  = PositionGetDouble(POSITION_VOLUME);

      MqlTick tick;
      if(!SymbolInfoTick(sym, tick)) return false;

      MqlTradeRequest req; ZeroMemory(req);
      MqlTradeResult  res; ZeroMemory(res);
      req.action    = TRADE_ACTION_DEAL;
      req.position  = ticket;
      req.symbol    = sym;
      req.volume    = vol;
      req.type      = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price     = (ptype == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
      req.deviation = m_deviation;
      req.magic     = m_magic;
      req.comment   = "AWRocov:close";
      req.type_time = ORDER_TIME_GTC;

      ENUM_ORDER_TYPE_FILLING fills[];
      int fc = BuildFillingList(fills);
      for(int i = 0; i < fc; i++)
        {
         req.type_filling = fills[i];
         ZeroMemory(res);
         if(OrderSend(req, res) &&
            (res.retcode == TRADE_RETCODE_DONE ||
             res.retcode == TRADE_RETCODE_PLACED))
            return true;
         if(res.retcode != TRADE_RETCODE_INVALID_FILL && res.retcode != 0) break;
        }

      if(m_log)
         m_log.Error(StringFormat("Close FAILED ticket=%I64u retcode=%u (%s)",
                                  ticket, res.retcode, res.comment));
      return false;
     }

   //+----------------------------------------------------------------+
   //| Частичное закрытие. pct в диапазоне (0..100].                  |
   //+----------------------------------------------------------------+
   bool              PartialClose(const ulong ticket, const double pct)
     {
      if(!PositionSelectByTicket(ticket)) return false;
      double full   = PositionGetDouble(POSITION_VOLUME);
      double target = NormalizeVolume(full * pct / 100.0);
      if(target <= 0.0 || target >= full)
         return ClosePosition(ticket);

      string sym   = PositionGetString(POSITION_SYMBOL);
      long   ptype = PositionGetInteger(POSITION_TYPE);

      MqlTick tick;
      if(!SymbolInfoTick(sym, tick)) return false;

      MqlTradeRequest req; ZeroMemory(req);
      MqlTradeResult  res; ZeroMemory(res);
      req.action    = TRADE_ACTION_DEAL;
      req.position  = ticket;
      req.symbol    = sym;
      req.volume    = target;
      req.type      = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price     = (ptype == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
      req.deviation = m_deviation;
      req.magic     = m_magic;
      req.comment   = "AWRocov:partial";
      req.type_time = ORDER_TIME_GTC;

      ENUM_ORDER_TYPE_FILLING fills[];
      int fc = BuildFillingList(fills);
      for(int i = 0; i < fc; i++)
        {
         req.type_filling = fills[i];
         ZeroMemory(res);
         if(OrderSend(req, res) &&
            (res.retcode == TRADE_RETCODE_DONE ||
             res.retcode == TRADE_RETCODE_PLACED))
            return true;
         if(res.retcode != TRADE_RETCODE_INVALID_FILL && res.retcode != 0) break;
        }

      if(m_log)
         m_log.Error(StringFormat("PartialClose FAILED ticket=%I64u retcode=%u (%s)",
                                  ticket, res.retcode, res.comment));
      return false;
     }
  };

#endif // __AWROCOV_TRADEOPS_MQH__
