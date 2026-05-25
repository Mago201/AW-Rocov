//+------------------------------------------------------------------+
//|  Panel.mqh                                                        |
//|  Минимальная графическая панель: кнопки BUY / SELL / CLOSE ALL    |
//|  для ручного открытия и закрытия корзины.                         |
//|                                                                   |
//|  Панель НЕ вмешивается в работу движка восстановления: открытые   |
//|  ею позиции получают тот же magic и подбираются BasketManager-ом  |
//|  на следующем тике как обычные элементы корзины.                  |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_PANEL_MQH__
#define __AWROCOV_PANEL_MQH__

#include "Logger.mqh"
#include "BasketManager.mqh"
#include "TradeOps.mqh"

//--- Геометрия панели (правый верхний угол).
//    Все XDISTANCE для CORNER_RIGHT_UPPER указывают, насколько ЛЕВЕЕ
//    правого края чарта расположен левый край объекта. Поэтому, чтобы
//    объект шириной W поместился целиком, XDISTANCE должен быть >= W.
#define AWROCOV_PANEL_BTN_W        90
#define AWROCOV_PANEL_BTN_H        28
#define AWROCOV_PANEL_GAP_Y         6
#define AWROCOV_PANEL_MARGIN_RIGHT 10
#define AWROCOV_PANEL_TOP_OFFSET   28   // под линейкой инструмента / кнопками таймфреймов

class CPanel
  {
private:
   string            m_prefix;
   string            m_btn_buy;
   string            m_btn_sell;
   string            m_btn_close;
   string            m_lbl_lot;
   long              m_chart_id;
   int               m_subwindow;
   bool              m_visible;

   CLogger          *m_log;
   CBasketManager   *m_basket;
   CTradeOps        *m_ops;
   double            m_lot;

   bool              CreateButton(const string name, const string text,
                                  int x, int y,
                                  color bg, color fg)
     {
      if(ObjectFind(m_chart_id, name) >= 0)
         ObjectDelete(m_chart_id, name);
      if(!ObjectCreate(m_chart_id, name, OBJ_BUTTON, m_subwindow, 0, 0))
         return false;
      ObjectSetInteger(m_chart_id, name, OBJPROP_CORNER,       CORNER_RIGHT_UPPER);
      ObjectSetInteger(m_chart_id, name, OBJPROP_XDISTANCE,    x);
      ObjectSetInteger(m_chart_id, name, OBJPROP_YDISTANCE,    y);
      ObjectSetInteger(m_chart_id, name, OBJPROP_XSIZE,        AWROCOV_PANEL_BTN_W);
      ObjectSetInteger(m_chart_id, name, OBJPROP_YSIZE,        AWROCOV_PANEL_BTN_H);
      ObjectSetInteger(m_chart_id, name, OBJPROP_BGCOLOR,      bg);
      ObjectSetInteger(m_chart_id, name, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(m_chart_id, name, OBJPROP_COLOR,        fg);
      ObjectSetInteger(m_chart_id, name, OBJPROP_FONTSIZE,     10);
      ObjectSetInteger(m_chart_id, name, OBJPROP_BACK,         false);
      ObjectSetInteger(m_chart_id, name, OBJPROP_SELECTABLE,   false);
      ObjectSetInteger(m_chart_id, name, OBJPROP_HIDDEN,       true);
      ObjectSetInteger(m_chart_id, name, OBJPROP_STATE,        false);
      ObjectSetString (m_chart_id, name, OBJPROP_TEXT,         text);
      ObjectSetString (m_chart_id, name, OBJPROP_FONT,         "Arial Bold");
      return true;
     }

   bool              CreateLotLabel(int x, int y)
     {
      string name = m_lbl_lot;
      if(ObjectFind(m_chart_id, name) >= 0)
         ObjectDelete(m_chart_id, name);
      if(!ObjectCreate(m_chart_id, name, OBJ_LABEL, m_subwindow, 0, 0))
         return false;
      ObjectSetInteger(m_chart_id, name, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
      ObjectSetInteger(m_chart_id, name, OBJPROP_ANCHOR,    ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(m_chart_id, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(m_chart_id, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(m_chart_id, name, OBJPROP_COLOR,     clrSilver);
      ObjectSetInteger(m_chart_id, name, OBJPROP_FONTSIZE,  9);
      ObjectSetInteger(m_chart_id, name, OBJPROP_BACK,      false);
      ObjectSetInteger(m_chart_id, name, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(m_chart_id, name, OBJPROP_HIDDEN,    true);
      ObjectSetString (m_chart_id, name, OBJPROP_TEXT,
                       StringFormat("ручной лот: %.2f", m_lot));
      ObjectSetString (m_chart_id, name, OBJPROP_FONT,      "Arial");
      return true;
     }

public:
                     CPanel(): m_log(NULL), m_basket(NULL), m_ops(NULL),
                               m_chart_id(0), m_subwindow(0),
                               m_visible(false), m_lot(0.01) {}

   void              Init(const string    prefix,
                          const double    lot,
                          CLogger        *log,
                          CBasketManager *basket,
                          CTradeOps      *ops)
     {
      m_prefix    = prefix;
      m_lot       = lot;
      m_log       = log;
      m_basket    = basket;
      m_ops       = ops;
      m_chart_id  = ChartID();
      m_subwindow = 0;
      m_btn_buy   = m_prefix + "_btn_buy";
      m_btn_sell  = m_prefix + "_btn_sell";
      m_btn_close = m_prefix + "_btn_close";
      m_lbl_lot   = m_prefix + "_lbl_lot";
     }

   void              Show()
     {
      if(m_visible) return;

      const int x = AWROCOV_PANEL_BTN_W + AWROCOV_PANEL_MARGIN_RIGHT;     // левый край кнопок
      int y = AWROCOV_PANEL_TOP_OFFSET;

      CreateLotLabel(AWROCOV_PANEL_MARGIN_RIGHT, y - 16);

      CreateButton(m_btn_buy,   "BUY",       x, y,                       clrSeaGreen,  clrWhite);
      y += AWROCOV_PANEL_BTN_H + AWROCOV_PANEL_GAP_Y;
      CreateButton(m_btn_sell,  "SELL",      x, y,                       clrFireBrick, clrWhite);
      y += AWROCOV_PANEL_BTN_H + AWROCOV_PANEL_GAP_Y;
      CreateButton(m_btn_close, "CLOSE ALL", x, y,                       clrDimGray,   clrWhite);

      ChartRedraw(m_chart_id);
      m_visible = true;
     }

   void              Hide()
     {
      ObjectDelete(m_chart_id, m_btn_buy);
      ObjectDelete(m_chart_id, m_btn_sell);
      ObjectDelete(m_chart_id, m_btn_close);
      ObjectDelete(m_chart_id, m_lbl_lot);
      ChartRedraw(m_chart_id);
      m_visible = false;
     }

   void              SetLot(const double lot)
     {
      m_lot = lot;
      if(m_visible)
        {
         ObjectSetString(m_chart_id, m_lbl_lot, OBJPROP_TEXT,
                         StringFormat("ручной лот: %.2f", m_lot));
         ChartRedraw(m_chart_id);
        }
     }

   //--- Делегат для OnChartEvent. Возвращает true, если событие
   //    относилось к панели (даже если действие не удалось).
   bool              OnEvent(const int       id,
                             const long     &lparam,
                             const double   &dparam,
                             const string   &sparam)
     {
      if(id != CHARTEVENT_OBJECT_CLICK) return false;

      if(sparam == m_btn_buy)
        {
         ObjectSetInteger(m_chart_id, m_btn_buy, OBJPROP_STATE, false);
         ulong t = m_ops.OpenMarket(ORDER_TYPE_BUY, m_lot, "AWRocov:manual_buy");
         if(m_log)
            m_log.Info(StringFormat("ручной BUY %.2f лот -> ticket=%I64u",
                                    m_lot, t));
         ChartRedraw(m_chart_id);
         return true;
        }

      if(sparam == m_btn_sell)
        {
         ObjectSetInteger(m_chart_id, m_btn_sell, OBJPROP_STATE, false);
         ulong t = m_ops.OpenMarket(ORDER_TYPE_SELL, m_lot, "AWRocov:manual_sell");
         if(m_log)
            m_log.Info(StringFormat("ручной SELL %.2f лот -> ticket=%I64u",
                                    m_lot, t));
         ChartRedraw(m_chart_id);
         return true;
        }

      if(sparam == m_btn_close)
        {
         ObjectSetInteger(m_chart_id, m_btn_close, OBJPROP_STATE, false);
         m_basket.Refresh();
         int n      = m_basket.TicketsCount();
         int closed = 0;
         for(int i = 0; i < n; i++)
           {
            ulong t = m_basket.TicketAt(i);
            if(m_ops.ClosePosition(t)) closed++;
           }
         if(m_log)
            m_log.Info(StringFormat("ручное закрытие всех: %d/%d закрыто",
                                    closed, n));
         ChartRedraw(m_chart_id);
         return true;
        }

      return false;
     }
  };

#endif // __AWROCOV_PANEL_MQH__
