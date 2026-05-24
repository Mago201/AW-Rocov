//+------------------------------------------------------------------+
//|  Panel.mqh                                                        |
//|  Простая ручная панель кнопок BUY / SELL / ЗАКРЫТЬ для тестера    |
//|  и для ручного боевого использования. Кнопки — стандартные        |
//|  объекты графика (OBJ_BUTTON), клики приходят через               |
//|  CHARTEVENT_OBJECT_CLICK в OnChartEvent главного советника.       |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_PANEL_MQH__
#define __AWROCOV_PANEL_MQH__

#include "Logger.mqh"
#include "TradeOps.mqh"
#include "BasketManager.mqh"

class CManualPanel
  {
private:
   CTradeOps        *m_ops;
   CBasketManager   *m_basket;
   CLogger          *m_log;
   double            m_lot;
   bool              m_built;

   //--- Имена объектов графика
   string            m_n_bg;
   string            m_n_title;
   string            m_n_lot;
   string            m_n_buy;
   string            m_n_sell;
   string            m_n_close;

   //--- Низкоуровневые помощники ----------------------------------
   void              CreateLabel(const string name,
                                 const int    x,
                                 const int    y,
                                 const string text,
                                 const color  clr = clrWhite,
                                 const int    font_size = 9)
     {
      ObjectDelete(0, name);
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
      ObjectSetString (0, name, OBJPROP_TEXT,       text);
      ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   font_size);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
     }

   void              CreateButton(const string name,
                                  const int    x,
                                  const int    y,
                                  const int    w,
                                  const int    h,
                                  const string text,
                                  const color  bg,
                                  const color  fg = clrWhite)
     {
      ObjectDelete(0, name);
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,    x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,    y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE,        w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE,        h);
      ObjectSetString (0, name, OBJPROP_TEXT,         text);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      bg);
      ObjectSetInteger(0, name, OBJPROP_COLOR,        fg);
      ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,     10);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,       true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
      ObjectSetInteger(0, name, OBJPROP_BACK,         false);
      ObjectSetInteger(0, name, OBJPROP_STATE,        false);
     }

   void              CreateBackground(const string name,
                                      const int x, const int y,
                                      const int w, const int h)
     {
      ObjectDelete(0, name);
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,      CORNER_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,   x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,   y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE,       w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE,       h);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,     C'30,30,40');
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_COLOR,       clrSilver);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,      true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, name, OBJPROP_BACK,        true);
     }

public:
                     CManualPanel(): m_ops(NULL), m_basket(NULL), m_log(NULL),
                                     m_lot(0.01), m_built(false) {}

   void              Init(const double    lot,
                          CTradeOps      *ops,
                          CBasketManager *basket,
                          CLogger        *log)
     {
      m_lot    = lot;
      m_ops    = ops;
      m_basket = basket;
      m_log    = log;

      // Уникальные имена с префиксом, чтобы не конфликтовать с другими объектами
      m_n_bg    = "AWRocov_panel_bg";
      m_n_title = "AWRocov_panel_title";
      m_n_lot   = "AWRocov_panel_lot";
      m_n_buy   = "AWRocov_panel_btn_buy";
      m_n_sell  = "AWRocov_panel_btn_sell";
      m_n_close = "AWRocov_panel_btn_close";
     }

   //--- Создать все объекты на графике
   void              Show()
     {
      // Координаты считаются от нижнего левого угла; y растёт ВВЕРХ.
      const int pad     = 8;
      const int btn_w   = 70;
      const int btn_h   = 26;
      const int row_y   = 14;                   // нижний ряд кнопок
      const int total_w = 3 * btn_w + 2 * 5 + 2 * pad;
      const int total_h = row_y + btn_h + 36 + pad;

      CreateBackground(m_n_bg, 4, 6, total_w, total_h);

      CreateLabel(m_n_title, pad + 4, total_h - 14,
                  "AW-Rocov — ручное управление", clrSilver, 9);

      string lot_text = StringFormat("Лот: %.2f", m_lot);
      CreateLabel(m_n_lot, pad + 4, total_h - 32, lot_text, clrLightGray, 9);

      // Кнопки слева направо
      int x = pad + 4;
      CreateButton(m_n_buy,   x, row_y, btn_w, btn_h, "BUY",   C'40,140,70');
      x += btn_w + 5;
      CreateButton(m_n_sell,  x, row_y, btn_w, btn_h, "SELL",  C'170,40,40');
      x += btn_w + 5;
      CreateButton(m_n_close, x, row_y, btn_w, btn_h, "CLOSE", C'80,80,90');

      m_built = true;
      ChartRedraw(0);
     }

   //--- Удалить все объекты
   void              Destroy()
     {
      ObjectDelete(0, m_n_bg);
      ObjectDelete(0, m_n_title);
      ObjectDelete(0, m_n_lot);
      ObjectDelete(0, m_n_buy);
      ObjectDelete(0, m_n_sell);
      ObjectDelete(0, m_n_close);
      m_built = false;
      ChartRedraw(0);
     }

   //--- Обработать клик по объекту. Возвращает true, если это была наша кнопка.
   bool              OnClick(const string clicked_name)
     {
      if(!m_built) return false;
      if(m_ops == NULL || m_basket == NULL) return false;

      if(clicked_name == m_n_buy)
        {
         ulong t = m_ops.OpenMarket(ORDER_TYPE_BUY, m_lot, "AWRocov:manual_buy");
         if(m_log != NULL)
            m_log.Info(StringFormat("ручной BUY: лот=%.2f ticket=%I64u", m_lot, t));
         return true;
        }
      if(clicked_name == m_n_sell)
        {
         ulong t = m_ops.OpenMarket(ORDER_TYPE_SELL, m_lot, "AWRocov:manual_sell");
         if(m_log != NULL)
            m_log.Info(StringFormat("ручной SELL: лот=%.2f ticket=%I64u", m_lot, t));
         return true;
        }
      if(clicked_name == m_n_close)
        {
         m_basket.Refresh();
         int n = m_basket.TicketsCount();
         int closed = 0;
         for(int i = 0; i < n; i++)
           {
            ulong tk = m_basket.TicketAt(i);
            if(m_ops.ClosePosition(tk)) closed++;
           }
         if(m_log != NULL)
            m_log.Info(StringFormat("ручное CLOSE: закрыто %d/%d", closed, n));
         return true;
        }
      return false;
     }

   bool              IsBuilt() const { return m_built; }
  };

#endif // __AWROCOV_PANEL_MQH__
