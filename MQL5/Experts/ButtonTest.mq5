//+------------------------------------------------------------------+
//|  ButtonTest.mq5                                                   |
//|  Минимальный диагностический EA — ОДНА кнопка, ОДИН OrderSend.   |
//|  Цель: проверить, что в Strategy Tester (Visual Mode) клик       |
//|  по объекту графика реально приводит к открытию рыночной         |
//|  позиции. Никаких include, никаких классов.                      |
//+------------------------------------------------------------------+
#property copyright "AW-Rocov diag"
#property version   "1.00"
#property strict
#property description "Минимальный тест: одна кнопка BUY, голый OrderSend, всё в Print + Comment."

input double InpLot   = 0.01;     // лот тестовой сделки
input ulong  InpMagic = 99999;    // magic для ордера

const string g_btn = "ButtonTest_BUY";

int    g_clicks   = 0;
string g_last_msg = "(нажми кнопку)";
bool   g_pending  = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   ObjectDelete(0, g_btn);
   ObjectCreate (0, g_btn, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, g_btn, OBJPROP_CORNER,    CORNER_LEFT_LOWER);
   ObjectSetInteger(0, g_btn, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, g_btn, OBJPROP_YDISTANCE, 100);
   ObjectSetInteger(0, g_btn, OBJPROP_XSIZE,     120);
   ObjectSetInteger(0, g_btn, OBJPROP_YSIZE,     40);
   ObjectSetString (0, g_btn, OBJPROP_TEXT,      "TEST BUY");
   ObjectSetInteger(0, g_btn, OBJPROP_BGCOLOR,   C'40,140,70');
   ObjectSetInteger(0, g_btn, OBJPROP_COLOR,     clrWhite);
   ObjectSetInteger(0, g_btn, OBJPROP_FONTSIZE,  12);
   ObjectSetInteger(0, g_btn, OBJPROP_BACK,      false);
   ObjectSetInteger(0, g_btn, OBJPROP_HIDDEN,    true);
   ObjectSetInteger(0, g_btn, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, g_btn, OBJPROP_STATE,     false);

   PrintFormat("[ButtonTest] OnInit symbol=%s | term_trade=%d mql_trade=%d acc_trade=%d "
               "visual=%d tester=%d optim=%d",
               _Symbol,
               (int)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED),
               (int)MQLInfoInteger(MQL_TRADE_ALLOWED),
               (int)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED),
               (int)MQLInfoInteger(MQL_VISUAL_MODE),
               (int)MQLInfoInteger(MQL_TESTER),
               (int)MQLInfoInteger(MQL_OPTIMIZATION));
   ChartRedraw(0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectDelete(0, g_btn);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int       id,
                  const long     &lparam,
                  const double   &dparam,
                  const string   &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK) return;

   // Видим в журнале неотфильтрованно
   PrintFormat("[ButtonTest] *** CLICK *** sparam=%s", sparam);

   if(sparam == g_btn)
     {
      g_clicks++;
      g_pending = true;
      ObjectSetInteger(0, g_btn, OBJPROP_STATE, false);
      ChartRedraw(0);
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(g_pending)
     {
      g_pending = false;

      MqlTick t;
      if(!SymbolInfoTick(_Symbol, t) || t.ask <= 0.0)
        {
         g_last_msg = "SymbolInfoTick FAIL";
         PrintFormat("[ButtonTest] %s", g_last_msg);
        }
      else
        {
         MqlTradeRequest req; ZeroMemory(req);
         MqlTradeResult  res; ZeroMemory(res);
         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = _Symbol;
         req.volume       = InpLot;
         req.type         = ORDER_TYPE_BUY;
         req.price        = t.ask;
         req.deviation    = 30;
         req.magic        = InpMagic;
         req.comment      = "ButtonTest";
         req.type_filling = ORDER_FILLING_IOC;     // если откажет — попробуем FOK
         req.type_time    = ORDER_TIME_GTC;

         ResetLastError();
         bool sent = OrderSend(req, res);

         if(!sent || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED))
           {
            // вторая попытка с FOK
            req.type_filling = ORDER_FILLING_FOK;
            ZeroMemory(res);
            sent = OrderSend(req, res);
           }
         if(!sent || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED))
           {
            // третья попытка с RETURN
            req.type_filling = ORDER_FILLING_RETURN;
            ZeroMemory(res);
            sent = OrderSend(req, res);
           }

         g_last_msg = StringFormat("sent=%d retcode=%u (%s) order=%I64u deal=%I64u",
                                    sent, res.retcode, res.comment, res.order, res.deal);
         PrintFormat("[ButtonTest] %s | err=%d", g_last_msg, GetLastError());
        }
     }

   Comment(StringFormat("ButtonTest | clicks: %d | last: %s",
                        g_clicks, g_last_msg));
  }
//+------------------------------------------------------------------+
