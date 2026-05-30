//+------------------------------------------------------------------+
//|  TradeOps.mqh                                                     |
//|  Тонкая обёртка над CTrade с нормализацией цены и объёма          |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_TRADEOPS_MQH__
#define __AWROCOV_TRADEOPS_MQH__

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>
#include "Logger.mqh"

class CTradeOps
  {
private:
   CTrade            m_trade;
   CSymbolInfo       m_sym;
   CLogger          *m_log;
   string            m_symbol;
   ulong             m_magic;

public:
                     CTradeOps(): m_log(NULL) {}

   bool              Init(const string symbol,
                          const ulong  magic,
                          const ulong  deviation_points,
                          CLogger     *logger)
     {
      m_symbol = symbol;
      m_magic  = magic;
      m_log    = logger;

      if(!m_sym.Name(symbol))
        {
         if(m_log) m_log.Error("не удалось инициализировать CSymbolInfo для " + symbol);
         return false;
        }
      m_sym.RefreshRates();

      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(deviation_points);
      m_trade.SetTypeFillingBySymbol(symbol);
      m_trade.SetMarginMode();
      return true;
     }

   //--- Нормализация объёма к шагу/минимуму/максимуму символа
   double            NormalizeVolume(double volume)
     {
      m_sym.Refresh();
      double step = m_sym.LotsStep();
      double mn   = m_sym.LotsMin();
      double mx   = m_sym.LotsMax();
      if(step <= 0.0) step = 0.01;

      double v = MathFloor(volume / step + 0.0000001) * step;
      if(v < mn) v = mn;
      if(v > mx) v = mx;

      // округление до количества знаков шага лота
      int digits = (int)MathMax(0, -MathLog10(step));
      v = NormalizeDouble(v, digits);
      return v;
     }

   double            NormalizePrice(double price)
     {
      return NormalizeDouble(price, (int)m_sym.Digits());
     }

   double            Point() { m_sym.Refresh(); return m_sym.Point(); }
   double            Bid()   { m_sym.RefreshRates(); return m_sym.Bid(); }
   double            Ask()   { m_sym.RefreshRates(); return m_sym.Ask(); }

   //--- Открыть рыночный ордер; возвращает тикет или 0 при ошибке
   ulong             OpenMarket(const ENUM_ORDER_TYPE type,
                                const double          volume,
                                const string          comment)
     {
      double v = NormalizeVolume(volume);
      if(v <= 0.0)
        {
         if(m_log) m_log.Warn("OpenMarket: нормализованный объём = 0");
         return 0;
        }

      bool ok = false;
      if(type == ORDER_TYPE_BUY)
         ok = m_trade.Buy(v, m_symbol, 0.0, 0.0, 0.0, comment);
      else if(type == ORDER_TYPE_SELL)
         ok = m_trade.Sell(v, m_symbol, 0.0, 0.0, 0.0, comment);
      else
        {
         if(m_log) m_log.Error("OpenMarket: неподдерживаемый тип ордера");
         return 0;
        }

      if(!ok)
        {
         if(m_log)
            m_log.Error(StringFormat("OpenMarket не удался retcode=%u err=%d",
                                     m_trade.ResultRetcode(),
                                     GetLastError()));
         return 0;
        }
      return m_trade.ResultOrder();
     }

   //--- Полное закрытие позиции по тикету
   bool              ClosePosition(const ulong ticket)
     {
      if(!PositionSelectByTicket(ticket))
         return false;
      bool ok = m_trade.PositionClose(ticket);
      if(!ok && m_log != NULL)
         m_log.Error(StringFormat("закрытие не удалось ticket=%I64u retcode=%u",
                                  ticket, m_trade.ResultRetcode()));
      return ok;
     }

   //--- Частичное закрытие; pct в диапазоне [1..100]
   bool              PartialClose(const ulong ticket, const double pct)
     {
      if(!PositionSelectByTicket(ticket))
         return false;
      double full   = PositionGetDouble(POSITION_VOLUME);
      double target = NormalizeVolume(full * pct / 100.0);
      if(target <= 0.0 || target >= full)
         return ClosePosition(ticket);

      bool ok = m_trade.PositionClosePartial(ticket, target);
      if(!ok && m_log != NULL)
         m_log.Error(StringFormat("частичное закрытие не удалось ticket=%I64u retcode=%u",
                                  ticket, m_trade.ResultRetcode()));
      return ok;
     }

   //--- Открыть рыночный ордер с заданными SL/TP (для скальпера).
   //    sl_price / tp_price == 0.0 означает «без уровня».
   //    Возвращает тикет ордера или 0 при ошибке.
   ulong             OpenMarketSLTP(const ENUM_ORDER_TYPE type,
                                    const double          volume,
                                    const double          sl_price,
                                    const double          tp_price,
                                    const string          comment)
     {
      double v = NormalizeVolume(volume);
      if(v <= 0.0)
        {
         if(m_log) m_log.Warn("OpenMarketSLTP: нормализованный объём = 0");
         return 0;
        }
      double sl = (sl_price > 0.0) ? NormalizePrice(sl_price) : 0.0;
      double tp = (tp_price > 0.0) ? NormalizePrice(tp_price) : 0.0;

      bool ok = false;
      if(type == ORDER_TYPE_BUY)
         ok = m_trade.Buy(v, m_symbol, 0.0, sl, tp, comment);
      else if(type == ORDER_TYPE_SELL)
         ok = m_trade.Sell(v, m_symbol, 0.0, sl, tp, comment);
      else
        {
         if(m_log) m_log.Error("OpenMarketSLTP: неподдерживаемый тип ордера");
         return 0;
        }

      if(!ok)
        {
         if(m_log)
            m_log.Error(StringFormat("OpenMarketSLTP не удался retcode=%u err=%d",
                                     m_trade.ResultRetcode(),
                                     GetLastError()));
         return 0;
        }
      return m_trade.ResultOrder();
     }

   //--- Изменить SL/TP открытой позиции (используется трейлингом).
   //    Значение 0.0 снимает соответствующий уровень.
   bool              ModifyPositionSLTP(const ulong  ticket,
                                        const double sl_price,
                                        const double tp_price)
     {
      if(!PositionSelectByTicket(ticket))
         return false;
      double sl = (sl_price > 0.0) ? NormalizePrice(sl_price) : 0.0;
      double tp = (tp_price > 0.0) ? NormalizePrice(tp_price) : 0.0;
      bool ok = m_trade.PositionModify(ticket, sl, tp);
      if(!ok && m_log != NULL)
         m_log.Error(StringFormat("ModifyPositionSLTP не удался ticket=%I64u retcode=%u",
                                  ticket, m_trade.ResultRetcode()));
      return ok;
     }
  };

#endif // __AWROCOV_TRADEOPS_MQH__
